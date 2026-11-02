import Foundation

struct LibraryEntry: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var location: String
    var kind: EntryKind
    var notes = ""
    var tags: [String] = []
    var collectionID: UUID?
    var favorite = false
    var added = Date()
    var bookmark: Data?
    var url: URL? { kind == .url ? URL(string: location) : URL(fileURLWithPath: location) }
    var subtitle: String {
        if kind == .url { return url?.host ?? location }
        return (location as NSString).deletingLastPathComponent
    }
}

enum EntryKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case file, folder, url
    var id: String { rawValue }
    var title: String { rawValue == "url" ? "URL" : rawValue.capitalized }
    var icon: String {
        switch self { case .file: "doc"; case .folder: "folder"; case .url: "link" }
    }
}
struct LibraryCollection: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var parentID: UUID?
    var icon: String?
    var palette: Palette?
    var symbol: String { icon ?? "folder.fill" }
}
struct LibraryTag: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var icon: String?
    var palette: Palette?
    var symbol: String { icon ?? "tag.fill" }
}

enum TagMatch: String, Codable, CaseIterable, Identifiable {
    case any, all
    var id: String { rawValue }
    var title: String { self == .any ? "Match any tag" : "Match all tags" }
}

enum LibraryView: String, Codable, CaseIterable, Identifiable {
    case thumbnails, smallCards, mediumCards, largeCards, compactList, comfortableList, table
    var id: String { rawValue }
    var title: String {
        switch self {
        case .thumbnails: "Thumbnails"
        case .smallCards: "Small cards"
        case .mediumCards: "Medium cards"
        case .largeCards: "Large cards"
        case .compactList: "Compact list"
        case .comfortableList: "Comfortable list"
        case .table: "Table"
        }
    }
    var icon: String {
        switch self {
        case .thumbnails: "square.grid.3x3"
        case .smallCards, .mediumCards, .largeCards: "square.grid.2x2"
        case .compactList, .comfortableList: "list.bullet"
        case .table: "tablecells"
        }
    }
    var cardWidth: CGFloat {
        switch self { case .smallCards: 170; case .largeCards: 300; default: 230 }
    }
}
enum EntryField: String, CaseIterable, Codable, Identifiable {
    case kind, location, tags, notes, added
    var id: String { rawValue }
    var title: String { self == .added ? "Date added" : rawValue.capitalized }
}
enum Palette: String, CaseIterable, Codable, Identifiable {
    case ocean, violet, forest, amber, graphite
    var id: String { rawValue }
}
struct ViewConfiguration: Codable, Equatable {
    var fields: Set<EntryField> = [.kind, .location, .tags]
    var palette: Palette = .ocean
    var fontName = "System"
    var fontSize: Double = 13
    var thumbnailSize: Double?
    var resolvedThumbnailSize: CGFloat {
        let value = thumbnailSize ?? 80
        return value.isFinite ? min(160, max(48, value)) : 80
    }
}
enum EntrySort: String, CaseIterable, Codable, Identifiable {
    case name, newest, kind
    var id: String { rawValue }
    var title: String {
        switch self { case .name: "Name"; case .newest: "Newest first"; case .kind: "Kind" }
    }
}
struct LibraryData: Codable {
    var entries: [LibraryEntry] = []
    var collections: [LibraryCollection] = []
    var tags: [LibraryTag] = []
    var savedFilters: [SavedFilter] = []
    var view: LibraryView = .mediumCards
    var configurations: [String: ViewConfiguration] = [:]
    var sort: EntrySort = .name
    var appearance = "system"

    init() { }
    private enum CodingKeys: String, CodingKey {
        case entries, collections, tags, savedFilters, view, configurations, sort, appearance
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entries = try values.decode([LibraryEntry].self, forKey: .entries)
        collections = try values.decode([LibraryCollection].self, forKey: .collections)
        tags = try values.decodeIfPresent([LibraryTag].self, forKey: .tags) ?? []
        savedFilters = try values.decodeIfPresent([SavedFilter].self, forKey: .savedFilters) ?? []
        view = try values.decode(LibraryView.self, forKey: .view)
        configurations = try values.decode([String: ViewConfiguration].self, forKey: .configurations)
        sort = try values.decode(EntrySort.self, forKey: .sort)
        appearance = try values.decode(String.self, forKey: .appearance)
    }

}

enum LibraryLogic {
    static func scopedEntries(_ entries: [LibraryEntry], collections: [LibraryCollection], scope: String,
                              hierarchical: Bool, query: String, sort: EntrySort,
                              tags: Set<String> = [], tagMatch: TagMatch = .any) -> [LibraryEntry] {
        let collectionID = UUID(uuidString: scope)
        let collectionIDs = collectionID.map { descendants(of: $0, in: collections) } ?? []
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !tags.isEmpty
        let scoped = entries.filter { entry in
            if let collectionID {
                if hierarchical && !searching { return entry.collectionID == collectionID }
                return entry.collectionID.map { collectionIDs.contains($0) } == true
            }
            if scope == "favorites" { return entry.favorite }
            if let kind = EntryKind(rawValue: scope) { return entry.kind == kind }
            return !hierarchical || searching || entry.collectionID == nil
        }
        let tagged = scoped.filter { entry in
            guard !tags.isEmpty else { return true }
            let matches = tags.map { tag in entry.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
            return tagMatch == .all ? matches.allSatisfy { $0 } : matches.contains(true)
        }
        return filtered(tagged, query: query, sort: sort)
    }

    static func descendants(of id: UUID, in collections: [LibraryCollection]) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var pending = [id]
        while let parent = pending.popLast() {
            for child in collections where child.parentID == parent && result.insert(child.id).inserted {
                pending.append(child.id)
            }
        }
        return result
    }
    static func collectionPath(_ collection: LibraryCollection, in collections: [LibraryCollection]) -> String {
        var names = [collection.name]
        var parent = collection.parentID
        var visited: Set<UUID> = [collection.id]
        while let id = parent, visited.insert(id).inserted,
              let item = collections.first(where: { $0.id == id }) {
            names.insert(item.name, at: 0)
            parent = item.parentID
        }
        return names.joined(separator: " / ")
    }

    static func webURL(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let candidate = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: candidate),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, !host.contains(" ") else { return nil }
        return url
    }
    static func matches(_ entry: LibraryEntry, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || searchableText(entry)
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
    static func searchableText(_ entry: LibraryEntry) -> [String] {
        [entry.name, entry.location, entry.notes, entry.tags.joined(separator: " ")]
    }
    static func filtered(_ entries: [LibraryEntry], query: String, sort: EntrySort) -> [LibraryEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter {
            matches($0, query: query)
        }.sorted {
            switch sort {
            case .newest: return $0.added > $1.added
            case .kind:
                if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                fallthrough
            case .name: return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }
}
