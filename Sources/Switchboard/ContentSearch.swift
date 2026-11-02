import Foundation
import Combine
import PDFKit
import CryptoKit
import Darwin

enum ContentSearchMode: String, CaseIterable, Identifiable {
    case metadata, contents, both
    var id: String { rawValue }
    var searchPrompt: String { switch self { case .metadata: "Search names, tags, notes, and locations"; case .contents: "Search document contents"; case .both: "Search metadata and document contents" } }
    var title: String { switch self { case .metadata: "Metadata"; case .contents: "Document contents"; case .both: "Metadata and contents" } }
}
enum ContentMatchState: String, Sendable { case matched, noMatch, unavailable, skipped }
struct ContentMatch: Sendable {
    let id: UUID
    let state: ContentMatchState
    let snippet: String
    let reason: String
}
struct ContentSearchRequest: Equatable {
    let entries: [LibraryEntry]
    let libraryIDs: Set<UUID>
    let query: String
    let mode: ContentSearchMode
    var cacheVersion = 0
}
struct ContentReadError: LocalizedError { let errorDescription: String? }

struct ContentExtractor: Sendable {
    var maximumTextBytes = 1_048_576
    var maximumPDFBytes = 8 * 1_048_576
    var maximumPages = 200
    var maximumCharacters = 500_000
    static func checkLocal(_ url: URL) throws {
        let mounts = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey], options: []) ?? []
        if let volume = mounts.sorted(by: { $0.path.count > $1.path.count }).first(where: { url.pathComponents.starts(with: $0.pathComponents) }),
           (try? volume.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == false {
            throw ContentReadError(errorDescription: "Remote filesystems are not searched.")
        }
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) != 0 { throw ContentReadError(errorDescription: "Cloud placeholder; no download requested.") }
    }
    func text(at url: URL) throws -> String {
        try Self.checkLocal(url)
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ContentReadError(errorDescription: "Not a regular file.") }
        if values.isUbiquitousItem == true, let state = values.ubiquitousItemDownloadingStatus, state != .current && state != .downloaded {
            throw ContentReadError(errorDescription: "Cloud file is not downloaded.")
        }
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) != 0 { throw ContentReadError(errorDescription: "Cloud placeholder; no download requested.") }
        let pdf = url.pathExtension.lowercased() == "pdf"
        let extensions: Set<String> = ["txt", "md", "markdown", "log", "json", "yaml", "yml", "toml", "csv", "tsv", "swift", "rs", "js", "ts", "html", "css", "xml"]
        guard pdf || extensions.contains(url.pathExtension.lowercased()) else { throw ContentReadError(errorDescription: "Unsupported document type.") }
        let limit = pdf ? maximumPDFBytes : maximumTextBytes
        guard (values.fileSize ?? 0) <= limit else { throw ContentReadError(errorDescription: "File exceeds the \(limit / 1_024) KB search limit.") }
        let oldPolicy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        guard oldPolicy >= 0, setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
            throw ContentReadError(errorDescription: "Non-downloading file access is unavailable.")
        }
        defer { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, oldPolicy) }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw ContentReadError(errorDescription: "File grew beyond the search limit.") }
        if pdf {
            guard let document = PDFDocument(data: bytes), !document.isLocked else { throw ContentReadError(errorDescription: "PDF is invalid or locked.") }
            guard document.pageCount <= maximumPages else { throw ContentReadError(errorDescription: "PDF exceeds \(maximumPages) pages.") }
            var text = ""
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                text += document.page(at: index)?.string ?? ""
                text += "\n"
                guard text.count <= maximumCharacters else { throw ContentReadError(errorDescription: "PDF text exceeds the extraction limit.") }
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ContentReadError(errorDescription: "PDF has no searchable text; OCR is not enabled.") }
            return text
        }
        let text: String?
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) { text = String(data: bytes, encoding: .utf16) }
        else if !bytes.contains(0) { text = String(data: bytes, encoding: .utf8) }
        else { text = nil }
        guard let text, text.count <= maximumCharacters else { throw ContentReadError(errorDescription: "Unsupported encoding, binary data, or excessive text length.") }
        return text
    }
}

actor ContentSearchService {
    private struct CacheEntry: Codable { let signature: String; let text: String }
    let directory: URL
    let maximumCacheBytes: Int
    let extractor: ContentExtractor
    private var generation = UUID()
    private var retainedIDs: Set<UUID>?
    init(directory: URL? = nil, maximumCacheBytes: Int = 20 * 1_048_576, extractor: ContentExtractor = ContentExtractor()) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Switchboard/ContentSearch")
        self.maximumCacheBytes = maximumCacheBytes; self.extractor = extractor
    }
    func clear() throws {
        generation = UUID()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    func retain(_ ids: Set<UUID>) throws {
        retainedIDs = ids
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !ids.contains(id) { try FileManager.default.removeItem(at: file) }
        }
    }
    func match(_ entry: LibraryEntry, query: String) async -> ContentMatch {
        guard entry.kind == .file else { return ContentMatch(id: entry.id, state: .skipped, snippet: "", reason: "Only local files support content search.") }
        do {
            try Task.checkCancellation()
            let epoch = generation
            guard let url = FilePreviewLoader.fileURL(for: entry) else { throw ContentReadError(errorDescription: "File reference is unavailable.") }
            try ContentExtractor.checkLocal(url)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
            let raw = "\(url.path)|\(values.fileSize ?? -1)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(String(describing: values.fileResourceIdentifier))"
            let signature = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
            let cache = directory.appendingPathComponent(entry.id.uuidString + ".json")
            let text: String
            if let size = try? cache.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1_048_576,
               let bytes = try? Data(contentsOf: cache), let saved = try? JSONDecoder().decode(CacheEntry.self, from: bytes), saved.signature == signature {
                text = saved.text
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cache.path)
            } else {
                let extractor = extractor
                let extraction = Task.detached(priority: .utility) { try extractor.text(at: url) }
                text = try await withTaskCancellationHandler { try await extraction.value } onCancel: { extraction.cancel() }
                try Task.checkCancellation()
                guard generation == epoch, retainedIDs?.contains(entry.id) != false else { throw CancellationError() }
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let bytes = try JSONEncoder().encode(CacheEntry(signature: signature, text: text))
                    if bytes.count <= maximumCacheBytes { try bytes.write(to: cache, options: .atomic); try evict() }
                } catch { try? FileManager.default.removeItem(at: cache) }
            }
            try Task.checkCancellation()
            guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
                return ContentMatch(id: entry.id, state: .noMatch, snippet: "", reason: "")
            }
            let lower = text.index(range.lowerBound, offsetBy: -70, limitedBy: text.startIndex) ?? text.startIndex
            let upper = text.index(range.upperBound, offsetBy: 100, limitedBy: text.endIndex) ?? text.endIndex
            return ContentMatch(id: entry.id, state: .matched, snippet: String(text[lower..<upper]).replacingOccurrences(of: "\n", with: " "), reason: "")
        } catch is CancellationError { return ContentMatch(id: entry.id, state: .skipped, snippet: "", reason: "Search cancelled.") }
        catch let error as ContentReadError { return ContentMatch(id: entry.id, state: .skipped, snippet: "", reason: error.localizedDescription) }
        catch { return ContentMatch(id: entry.id, state: .unavailable, snippet: "", reason: error.localizedDescription) }
    }
    private func evict() throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> (URL, Int, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }.sorted { $0.2 < $1.2 }
        var bytes = files.reduce(0) { $0 + $1.1 }
        for file in files where bytes > maximumCacheBytes { try FileManager.default.removeItem(at: file.0); bytes -= file.1 }
    }
}

@MainActor final class ContentSearchModel: ObservableObject {
    @Published private(set) var request: ContentSearchRequest?
    @Published private(set) var matches: [UUID: ContentMatch] = [:]
    @Published private(set) var running = false
    @Published var message = ""
    let service: ContentSearchService
    private var generation = UUID()
    init(service: ContentSearchService = ContentSearchService()) { self.service = service }
    func run(_ value: ContentSearchRequest) async {
        let id = UUID(); generation = id; request = value; matches = [:]
        try? await service.retain(value.libraryIDs)
        guard value.mode != .metadata, !value.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { running = false; return }
        running = true
        defer { if generation == id { running = false } }
        do {
            try await Task.sleep(for: .milliseconds(180)); try Task.checkCancellation()
            guard generation == id else { return }
            try await service.retain(value.libraryIDs)
            let service = service
            await withTaskGroup(of: ContentMatch.self) { group in
                var next = 0
                for _ in 0..<min(4, value.entries.count) {
                    let entry = value.entries[next]; next += 1
                    group.addTask { await service.match(entry, query: value.query) }
                }
                for await result in group {
                    if Task.isCancelled || generation != id { group.cancelAll(); break }
                    if generation == id { matches[result.id] = result }
                    if next < value.entries.count {
                        let entry = value.entries[next]; next += 1
                        group.addTask { await service.match(entry, query: value.query) }
                    }
                }
            }
        } catch is CancellationError { }
        catch { message = error.localizedDescription }
    }
    func clearCache() async {
        generation = UUID(); request = nil; matches = [:]; running = false
        do { try await service.clear(); message = "Content search cache cleared." }
        catch { message = error.localizedDescription }
    }
}
