import Foundation
import CryptoKit

struct TransferError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum LibraryIntegrity {
    static func validate(_ data: LibraryData) throws {
        func unique<T: Hashable>(_ values: [T]) -> Bool { Set(values).count == values.count }
        guard unique(data.entries.map(\.id)), unique(data.collections.map(\.id)), unique(data.tags.map(\.id)),
              unique(data.savedFilters.map(\.id)) else { throw TransferError(message: "Duplicate identifiers in library data.") }
        let collections = Set(data.collections.map(\.id))
        guard data.entries.allSatisfy({ $0.collectionID == nil || collections.contains($0.collectionID!) }),
              data.collections.allSatisfy({ $0.parentID == nil || collections.contains($0.parentID!) }) else {
            throw TransferError(message: "A collection reference is unavailable.")
        }
        for collection in data.collections {
            var seen: Set<UUID> = [collection.id]; var parent = collection.parentID
            while let id = parent {
                guard seen.insert(id).inserted else { throw TransferError(message: "Collection hierarchy contains a cycle.") }
                parent = data.collections.first { $0.id == id }?.parentID
            }
        }
        guard data.entries.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.location.isEmpty && $0.added.timeIntervalSince1970.isFinite && abs($0.added.timeIntervalSince1970) < 253402300800 }),
              data.tags.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.name.contains(",") }),
              unique(data.tags.map { $0.name.lowercased() }) else { throw TransferError(message: "Invalid names or duplicate tag names.") }
    }
    static func fingerprint(_ data: LibraryData) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(data)).map { String(format: "%02x", $0) }.joined()
    }
}

struct PortableLibrary: Codable {
    var schemaVersion = 1
    var entries: [LibraryEntry]
    var collections: [LibraryCollection]
    var tags: [LibraryTag]
    var savedFilters: [SavedFilter]
    init(_ data: LibraryData) {
        entries = data.entries.map { var entry = $0; entry.bookmark = nil; return entry }
        collections = data.collections; tags = data.tags; savedFilters = data.savedFilters
    }
    func library() throws -> LibraryData {
        guard schemaVersion == 1 else { throw TransferError(message: "Unsupported portable library version \(schemaVersion).") }
        guard entries.count <= 10_000, collections.count <= 5_000, tags.count <= 5_000, savedFilters.count <= 5_000 else {
            throw TransferError(message: "Import exceeds the supported item limit.")
        }
        var data = LibraryData(); data.entries = entries.map { var entry = $0; entry.bookmark = nil; return entry }
        data.collections = collections; data.tags = tags; data.savedFilters = savedFilters
        for index in data.entries.indices {
            if data.entries[index].kind == .url {
                guard let url = LibraryLogic.webURL(data.entries[index].location) else { throw TransferError(message: "Imported URL must use HTTP or HTTPS.") }
                data.entries[index].location = url.absoluteString
            } else if !data.entries[index].location.hasPrefix("/") || data.entries[index].location.contains("\0") {
                throw TransferError(message: "Imported file and folder references must use absolute local paths.")
            }
            var names: [String] = []
            for raw in data.entries[index].tags {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !name.contains(",") else { continue }
                if !data.tags.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { data.tags.append(LibraryTag(name: name)) }
                if let canonical = data.tags.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.name, !names.contains(canonical) { names.append(canonical) }
            }
            data.entries[index].tags = names
        }
        try LibraryIntegrity.validate(data)
        return data
    }
}

enum TransferFormat: String, CaseIterable, Identifiable {
    case json, html, csv
    var id: String { rawValue }
    var title: String { switch self { case .json: "Portable JSON"; case .html: "Bookmark HTML (URLs only)"; case .csv: "CSV" } }
}

enum LibraryTransfer {
    static let maximumImportBytes = 10 * 1_024 * 1_024
    static func read(_ url: URL, maximumBytes: Int = maximumImportBytes) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard bytes.count <= maximumBytes else { throw TransferError(message: "File exceeds the supported size limit.") }
        return bytes
    }
    static func parse(_ bytes: Data, html: Bool) throws -> LibraryData {
        guard bytes.count <= maximumImportBytes else { throw TransferError(message: "Import is limited to 10 MB.") }
        if html { return try BookmarkHTML.parse(bytes) }
        let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        if object?["schemaVersion"] != nil { return try JSONDecoder().decode(PortableLibrary.self, from: bytes).library() }
        return try PortableLibrary(JSONDecoder().decode(LibraryData.self, from: bytes)).library()
    }
    static func export(_ data: LibraryData, format: TransferFormat) throws -> Data {
        try LibraryIntegrity.validate(data)
        switch format {
        case .json:
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(PortableLibrary(data))
        case .html: return Data(BookmarkHTML.export(data).utf8)
        case .csv:
            func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            var rows = [["Name", "Kind", "Location", "Notes", "Tags", "Collection", "Favorite", "Added"]]
            for entry in data.entries {
                let path = data.collections.first { $0.id == entry.collectionID }.map { LibraryLogic.collectionPath($0, in: data.collections) } ?? ""
                rows.append([entry.name, entry.kind.rawValue, entry.location, entry.notes, entry.tags.joined(separator: ", "), path,
                             entry.favorite ? "true" : "false", ISO8601DateFormatter().string(from: entry.added)])
            }
            return Data((rows.map { $0.map(quote).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n").utf8)
        }
    }
    static func address(_ entry: LibraryEntry) -> String {
        if entry.kind != .url { return "local:" + URL(fileURLWithPath: entry.location).standardizedFileURL.path }
        guard var parts = URLComponents(string: entry.location) else { return entry.location }
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
        if parts.scheme == "https" && parts.port == 443 || parts.scheme == "http" && parts.port == 80 { parts.port = nil }
        return parts.string ?? entry.location
    }
}

enum DuplicatePolicy: String, CaseIterable, Identifiable {
    case skip, keepBoth
    var id: String { rawValue }
    var title: String { self == .skip ? "Keep existing references" : "Import duplicate references too" }
}

struct ImportPreview {
    let baseline: String
    let candidate: LibraryData
    let added: Int
    let skipped: Int
    let conflicts: [String]
    static func prepare(_ incoming: LibraryData, into existing: LibraryData, policy: DuplicatePolicy) throws -> ImportPreview {
        try LibraryIntegrity.validate(incoming)
        var candidate = existing; var tagMap: [UUID: UUID] = [:]; var collectionMap: [UUID: UUID] = [:]
        var conflicts: [String] = []
        for tag in incoming.tags {
            if let current = candidate.tags.first(where: { $0.name.caseInsensitiveCompare(tag.name) == .orderedSame }) {
                tagMap[tag.id] = current.id
                if tag.icon != current.icon || tag.palette != current.palette { conflicts.append("Existing appearance retained for tag ‘\(current.name)’.") }
            } else {
                var copy = tag
                if candidate.tags.contains(where: { $0.id == copy.id }) { copy.id = UUID(); conflicts.append("Remapped a colliding tag identifier.") }
                tagMap[tag.id] = copy.id; candidate.tags.append(copy)
            }
        }
        for item in incoming.collections { collectionMap[item.id] = candidate.collections.contains { $0.id == item.id } ? UUID() : item.id }
        for item in incoming.collections {
            var copy = item; copy.id = collectionMap[item.id]!
            copy.parentID = item.parentID.flatMap { collectionMap[$0] }; candidate.collections.append(copy)
        }
        var seen = Set(existing.entries.map(LibraryTransfer.address)); var added = 0; var skipped = 0
        for item in incoming.entries {
            let key = LibraryTransfer.address(item)
            if policy == .skip, seen.contains(key) { skipped += 1; conflicts.append("Kept existing reference: \(item.name)."); continue }
            var copy = item; copy.bookmark = nil
            if candidate.entries.contains(where: { $0.id == item.id }) { copy.id = UUID(); conflicts.append("Remapped identifier for ‘\(item.name)’.") }
            copy.collectionID = item.collectionID.flatMap { collectionMap[$0] }
            copy.tags = item.tags.map { name in
                let old = incoming.tags.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                return candidate.tags.first { $0.id == old.flatMap { tagMap[$0.id] } }?.name ?? name
            }
            candidate.entries.append(copy); seen.insert(key); added += 1
        }
        for saved in incoming.savedFilters {
            for id in saved.criteria.tagIDs.union(saved.criteria.additionalTags.flatMap { $0.ids }) where tagMap[id] == nil { tagMap[id] = UUID() }
            if let id = saved.criteria.collectionID, collectionMap[id] == nil { collectionMap[id] = UUID() }
        }
        for saved in incoming.savedFilters {
            var copy = saved
            if candidate.savedFilters.contains(where: { $0.id == copy.id }) { copy.id = UUID() }
            let base = copy.name; var suffix = 2
            while candidate.savedFilters.contains(where: { $0.name.caseInsensitiveCompare(copy.name) == .orderedSame }) {
                copy.name = base + " imported \(suffix)"; suffix += 1
            }
            if let id = copy.criteria.collectionID { copy.criteria.collectionID = collectionMap[id] ?? id }
            copy.criteria.tagIDs = Set(copy.criteria.tagIDs.map { tagMap[$0] ?? $0 })
            for i in copy.criteria.additionalTags.indices { copy.criteria.additionalTags[i].ids = Set(copy.criteria.additionalTags[i].ids.map { tagMap[$0] ?? $0 }) }
            candidate.savedFilters.append(copy)
        }
        try LibraryIntegrity.validate(candidate)
        return ImportPreview(baseline: try LibraryIntegrity.fingerprint(existing), candidate: candidate, added: added, skipped: skipped, conflicts: conflicts)
    }
}
