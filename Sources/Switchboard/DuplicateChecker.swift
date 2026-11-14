import Foundation

struct DuplicateGroup: Identifiable, Sendable {
    let id: String
    /// Recommended survivor first, followed by the other copies.
    let entries: [LibraryEntry]
}

enum DuplicateChecker {
    static func key(_ entry: LibraryEntry) -> String {
        guard entry.kind == .url else {
            return entry.kind.rawValue + ":" + URL(fileURLWithPath: entry.location).standardizedFileURL.path
        }
        guard var parts = URLComponents(string: entry.location) else { return "url:" + entry.location }
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
        if parts.scheme == "https" && parts.port == 443 || parts.scheme == "http" && parts.port == 80 { parts.port = nil }
        if ["http", "https"].contains(parts.scheme ?? ""), parts.path.isEmpty { parts.path = "/" }
        return "url:" + (parts.string ?? entry.location)
    }

    static func groups(in entries: [LibraryEntry], syncedIDs: Set<UUID> = []) -> [DuplicateGroup] {
        func metadata(_ entry: LibraryEntry) -> Int {
            (entry.favorite ? 1 : 0) + (entry.notes.isEmpty ? 0 : 1) + Set(entry.tags).count
        }
        return Dictionary(grouping: entries, by: key).compactMap { key, copies in
            guard copies.count > 1 else { return nil }
            let sorted = copies.sorted { a, b in
                if syncedIDs.contains(a.id) != syncedIDs.contains(b.id) { return syncedIDs.contains(a.id) }
                if metadata(a) != metadata(b) { return metadata(a) > metadata(b) }
                if a.added != b.added { return a.added < b.added }
                return a.id.uuidString < b.id.uuidString
            }
            return DuplicateGroup(id: key, entries: sorted)
        }.sorted { $0.id < $1.id }
    }

    static func extraCopies(in groups: [DuplicateGroup]) -> Set<UUID> {
        Set(groups.flatMap { $0.entries.dropFirst().map(\.id) })
    }

    /// Fail the whole operation if the reviewed groups changed or no survivor would remain.
    static func validatedRemoval(_ selection: Set<UUID>, reviewed: [DuplicateGroup], current: [LibraryEntry]) throws -> Set<UUID> {
        let live = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let liveGroups = Dictionary(grouping: current, by: key)
        var valid: Set<UUID> = []
        for group in reviewed {
            let ids = Set(group.entries.map(\.id))
            let selected = selection.intersection(ids)
            guard !selected.isEmpty else { continue }
            guard selected.count < ids.count else { throw TransferError(message: "Keep at least one copy in each duplicate group.") }
            guard group.entries.allSatisfy({ live[$0.id] == $0 && key($0) == group.id }),
                  Set((liveGroups[group.id] ?? []).map(\.id)) == ids else {
                throw TransferError(message: "These duplicates changed since review. Scan again before removing them.")
            }
            valid.formUnion(selected)
        }
        guard valid == selection else { throw TransferError(message: "The selection includes entries outside the reviewed duplicates. Scan again.") }
        return valid
    }
}

extension LibraryStore {
    @discardableResult func removeDuplicates(_ selection: Set<UUID>, reviewed: [DuplicateGroup]) -> Int {
        do { return remove(try DuplicateChecker.validatedRemoval(selection, reviewed: reviewed, current: data.entries)) }
        catch { self.error = error.localizedDescription; return 0 }
    }
}
