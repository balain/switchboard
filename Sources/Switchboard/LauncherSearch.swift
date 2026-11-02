import Foundation

struct LauncherSearch {
    private struct Document {
        let entry: LibraryEntry
        let name: String
        let metadata: [String]
    }
    private let documents: [Document]
    init(entries: [LibraryEntry]) {
        documents = entries.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }.map { entry in
            Document(entry: entry, name: Self.fold(entry.name), metadata: LibraryLogic.searchableText(entry).dropFirst().map(Self.fold))
        }
    }
    func results(query: String, limit: Int = 50) -> [LibraryEntry] {
        guard limit > 0 else { return [] }
        let query = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        if query.isEmpty { return Array(documents.prefix(limit).map(\.entry)) }
        var buckets = Array(repeating: [LibraryEntry](), count: 4)
        for document in documents {
            let rank: Int
            if document.name == query { rank = 0 }
            else if document.name.hasPrefix(query) { rank = 1 }
            else if document.name.contains(query) { rank = 2 }
            else if document.metadata.contains(where: { $0.contains(query) }) { rank = 3 }
            else { continue }
            if buckets[rank].count < limit { buckets[rank].append(document.entry) }
        }
        return Array(buckets.flatMap { $0 }.prefix(limit))
    }
    private static func fold(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
}
