import Foundation

/// Build once per sidebar update. Never traverse the folder tree inside an entry count.
struct LibrarySidebarSnapshot {
    let vivaldiRoot: UUID?
    let vivaldiCollectionIDs: Set<UUID>
    let collections: [LibraryCollection]
    private(set) var favorites = 0
    private(set) var kinds: [EntryKind: Int] = [:]
    private(set) var collectionCounts: [UUID: Int] = [:]
    private(set) var tags: [String: Int] = [:]

    init(data: LibraryData) {
        let root = (data.vivaldi?.root).flatMap { root in data.collections.contains { $0.id == root } ? root : nil }
        let syncedIDs = root.map { LibraryLogic.descendants(of: $0, in: data.collections) } ?? []
        vivaldiRoot = root
        vivaldiCollectionIDs = syncedIDs
        collections = data.collections.filter { !syncedIDs.contains($0.id) || $0.id == root }
        var syncedCount = 0
        for entry in data.entries {
            if entry.favorite { favorites += 1 }
            kinds[entry.kind, default: 0] += 1
            if let id = entry.collectionID {
                collectionCounts[id, default: 0] += 1
                if vivaldiCollectionIDs.contains(id) { syncedCount += 1 }
            }
            for tag in Set(entry.tags) { tags[tag, default: 0] += 1 }
        }
        if let root = vivaldiRoot { collectionCounts[root] = syncedCount }
    }
}
