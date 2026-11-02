import Foundation

enum BulkAction {
    case addTag(UUID), removeTag(UUID), collection(UUID?), favorite(Bool), remove
    var title: String {
        switch self {
        case .addTag: "Add Tags"
        case .removeTag: "Remove Tags"
        case .collection: "Move to Collection"
        case .favorite(let value): value ? "Mark Favorite" : "Remove Favorite"
        case .remove: "Remove Entries"
        }
    }
}

struct EntryPatch {
    let before: LibraryEntry
    let after: LibraryEntry

    func apply(to entry: inout LibraryEntry, inverse: Bool) -> Bool {
        let expected = inverse ? after : before
        let desired = inverse ? before : after
        var candidate = entry
        func field<T: Equatable>(_ key: WritableKeyPath<LibraryEntry, T>) -> Bool {
            guard before[keyPath: key] != after[keyPath: key] else { return true }
            guard candidate[keyPath: key] == expected[keyPath: key] else { return false }
            candidate[keyPath: key] = desired[keyPath: key]
            return true
        }
        guard field(\.name), field(\.location), field(\.kind), field(\.notes), field(\.tags),
              field(\.collectionID), field(\.favorite), field(\.added), field(\.bookmark) else { return false }
        entry = candidate
        return true
    }
}

enum LibraryMutation {
    case update(EntryPatch)
    case remove(LibraryEntry, Int)

    func apply(to data: inout LibraryData, inverse: Bool) -> Bool {
        switch self {
        case .update(let patch):
            guard let index = data.entries.firstIndex(where: { $0.id == patch.before.id }) else { return false }
            var entry = data.entries[index]
            guard patch.apply(to: &entry, inverse: inverse) else { return false }
            if entry.collectionID != data.entries[index].collectionID, let id = entry.collectionID,
               !data.collections.contains(where: { $0.id == id }) { return false }
            if entry.tags != data.entries[index].tags,
               !entry.tags.allSatisfy({ name in data.tags.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }) { return false }
            data.entries[index] = entry
        case .remove(let entry, let index):
            if inverse {
                guard !data.entries.contains(where: { $0.id == entry.id }),
                      entry.collectionID == nil || data.collections.contains(where: { $0.id == entry.collectionID }),
                      entry.tags.allSatisfy({ name in data.tags.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }) else { return false }
                data.entries.insert(entry, at: min(index, data.entries.count))
            } else {
                guard let index = data.entries.firstIndex(where: { $0.id == entry.id }), data.entries[index] == entry else { return false }
                data.entries.remove(at: index)
            }
        }
        return true
    }
}
