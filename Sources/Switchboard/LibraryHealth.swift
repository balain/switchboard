import Foundation
import Combine
import Darwin

enum HealthStatus: String, CaseIterable, Sendable {
    case healthy, missing, unavailableVolume, permissionDenied, notDownloaded, authenticationRequired, rateLimited, temporaryFailure, unknown
    var title: String {
        switch self {
        case .healthy: "Reachable"
        case .missing: "Missing"
        case .unavailableVolume: "Volume unavailable"
        case .permissionDenied: "Permission denied"
        case .notDownloaded: "Not downloaded"
        case .authenticationRequired: "Authentication required"
        case .rateLimited: "Rate limited"
        case .temporaryFailure: "Temporary failure"
        case .unknown: "Not verified"
        }
    }
}
struct HealthCheck: Sendable {
    let status: HealthStatus
    let detail: String
}
struct HealthFinding: Identifiable, Sendable {
    var id: UUID { entry.id }
    let entry: LibraryEntry
    let check: HealthCheck
    let duplicates: [UUID]
    let checked: Date
}

enum LocalHealthProbe {
    static func url(for entry: LibraryEntry) -> URL {
        if let bookmark = entry.bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale), resolved.isFileURL { return resolved }
        }
        return URL(fileURLWithPath: entry.location)
    }
    static func check(_ entry: LibraryEntry) -> HealthCheck {
        let url = url(for: entry)
        let components = url.standardizedFileURL.pathComponents
        let mounts = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey], options: []) ?? []
        if components.count > 2, components[1] == "Volumes", !mounts.contains(where: { $0.standardizedFileURL.pathComponents == Array(components.prefix(3)) }) {
            return HealthCheck(status: .unavailableVolume, detail: "The containing volume is not mounted.")
        }
        if let volume = mounts.sorted(by: { $0.path.count > $1.path.count }).first(where: { url.pathComponents.starts(with: $0.pathComponents) }),
           (try? volume.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == false {
            return HealthCheck(status: .unknown, detail: "Remote filesystem checks are skipped to avoid connecting to a server.")
        }
        do {
            var info = stat()
            if lstat(url.path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) != 0 {
                return HealthCheck(status: .notDownloaded, detail: "Cloud placeholder; no download requested.")
            }
            let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            if values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus, status != .current && status != .downloaded {
                return HealthCheck(status: .notDownloaded, detail: "Cloud placeholder; no download was requested.")
            }
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return HealthCheck(status: .healthy, detail: url.path == entry.location ? "Local reference is reachable." : "Bookmark resolves to \(url.path). The stored reference was not changed.")
        } catch {
            let value = error as NSError
            if value.code == NSFileReadNoPermissionError || value.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(value.code) {
                return HealthCheck(status: .permissionDenied, detail: "Access was denied; this does not establish that the file is missing.")
            }
            if value.code == NSFileNoSuchFileError || value.code == NSFileReadNoSuchFileError || value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT) {
                return HealthCheck(status: .missing, detail: "The local reference could not be found.")
            }
            return HealthCheck(status: .unknown, detail: error.localizedDescription)
        }
    }
    static func key(_ entry: LibraryEntry) -> String {
        if entry.kind != .url { return "local:" + url(for: entry).standardizedFileURL.path }
        guard var parts = URLComponents(string: entry.location) else { return entry.location }
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
        if parts.scheme == "https" && parts.port == 443 || parts.scheme == "http" && parts.port == 80 { parts.port = nil }
        return parts.string ?? entry.location
    }
}

struct LibraryHealthScanner: Sendable {
    var local: @Sendable (LibraryEntry) async -> HealthCheck = { entry in await Task.detached(priority: .utility) { LocalHealthProbe.check(entry) }.value }
    var web: @Sendable (URL) async throws -> HealthCheck = { try await WebHealthProbe.check($0) }
    var concurrency = 4
    func scan(_ entries: [LibraryEntry], includeWeb: Bool, progress: @escaping @Sendable (HealthFinding) async -> Void) async {
        let groups = Dictionary(grouping: entries, by: LocalHealthProbe.key)
        let duplicates = Dictionary(entries.map { entry in
            (entry.id, (groups[LocalHealthProbe.key(entry)] ?? []).map(\.id).filter { $0 != entry.id })
        }, uniquingKeysWith: { first, _ in first })
        await withTaskGroup(of: HealthFinding?.self) { group in
            var next = 0
            func submit(_ entry: LibraryEntry) {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    let check: HealthCheck
                    do {
                        if entry.kind == .url {
                            if includeWeb, let url = entry.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { check = try await web(url) }
                            else { check = HealthCheck(status: .unknown, detail: "Web link was not checked. Use Check Web Links to make explicit requests.") }
                        } else { check = await local(entry) }
                    } catch is CancellationError { return nil }
                    catch { check = HealthCheck(status: .temporaryFailure, detail: error.localizedDescription) }
                    guard !Task.isCancelled else { return nil }
                    return HealthFinding(entry: entry, check: check, duplicates: duplicates[entry.id] ?? [], checked: Date())
                }
            }
            for _ in 0..<min(max(1, concurrency), entries.count) { submit(entries[next]); next += 1 }
            for await finding in group {
                if Task.isCancelled { group.cancelAll(); break }
                if let finding { await progress(finding) }
                if next < entries.count { submit(entries[next]); next += 1 }
            }
        }
    }
}

@MainActor final class HealthScanModel: ObservableObject {
    @Published var findings: [HealthFinding] = []
    @Published var running = false
    @Published var completed = 0
    @Published var total = 0
    @Published var message = ""
    private var latest: [UUID: LibraryEntry] = [:]
    private var generation = UUID()
    private var task: Task<Void, Never>?
    func scan(_ entries: [LibraryEntry], includeWeb: Bool, scanner: LibraryHealthScanner = LibraryHealthScanner()) {
        cancel(); let id = UUID(); generation = id; findings = []; completed = 0; total = entries.count; running = true
        latest = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        task = Task {
            await scanner.scan(entries, includeWeb: includeWeb) { [weak self] finding in
                await MainActor.run {
                    guard let self, self.generation == id else { return }
                    self.completed += 1
                    guard self.latest[finding.id] == finding.entry else { return }
                    let duplicates = finding.duplicates.filter { id in self.latest[id].map { LocalHealthProbe.key($0) == LocalHealthProbe.key(finding.entry) } == true }
                    self.findings.append(HealthFinding(entry: finding.entry, check: finding.check, duplicates: duplicates, checked: finding.checked))
                }
            }
            if generation == id { running = false; message = "Checked \(completed) of \(total) references." }
        }
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; running = false }
    func discardStale(in entries: [LibraryEntry]) {
        latest = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        findings = findings.compactMap { finding in
            guard latest[finding.id] == finding.entry else { return nil }
            return HealthFinding(entry: finding.entry, check: finding.check,
                                 duplicates: finding.duplicates.filter { latest[$0].map { LocalHealthProbe.key($0) == LocalHealthProbe.key(finding.entry) } == true }, checked: finding.checked)
        }
    }
}
