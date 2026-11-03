import Foundation
import CryptoKit

struct VivaldiNode: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var parent: String?
    var url: String?
    var locked = false
}
struct VivaldiBinding: Codable {
    var connection: UUID
    var scope: String
    var root: UUID
    var mapping: [String: UUID] = [:]
    var baseline: [VivaldiNode] = []
    var lastTransaction: UUID?
    var lastAborted: UUID?
}
struct VivaldiConflict: Identifiable {
    let key: String
    let base: VivaldiNode?
    let local: VivaldiNode?
    let browser: VivaldiNode?
    var id: String { VivaldiGraph.digest([base, local, browser]) }
    var title: String { local?.title ?? browser?.title ?? base?.title ?? "Deleted bookmark" }
}
struct VivaldiMerge {
    var desired: [VivaldiNode]
    var conflicts: [VivaldiConflict]
}
enum VivaldiGraph {
    static let limit = 10_000
    static func digest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: (try? encoder.encode(value)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    static func sorted(_ nodes: [VivaldiNode]) -> [VivaldiNode] { nodes.sorted { $0.id < $1.id } }
    static func validate(_ nodes: [VivaldiNode]) throws {
        guard nodes.count <= limit, Set(nodes.map(\.id)).count == nodes.count else { throw TransferError(message: "Invalid or oversized bookmark snapshot.") }
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        for node in nodes {
            guard !node.id.isEmpty, node.id.count <= 128, !node.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  node.title.utf8.count <= 16_384, (node.url?.utf8.count ?? 0) <= 16_384 else { throw TransferError(message: "Invalid bookmark fields.") }
            if let url = node.url {
                guard let parsed = LibraryLogic.webURL(url), parsed.absoluteString == url else { throw TransferError(message: "Only HTTP and HTTPS bookmarks can sync.") }
            }
            var parent = node.parent; var seen: Set<String> = [node.id]
            while let id = parent {
                guard seen.count < 128, seen.insert(id).inserted, let folder = byID[id], folder.url == nil else {
                    throw TransferError(message: "Bookmark folders contain an unavailable parent or a cycle.")
                }
                parent = folder.parent
            }
        }
    }
    static func merge(base: [VivaldiNode], local: [VivaldiNode], browser: [VivaldiNode], choices: [String: Bool]) throws -> VivaldiMerge {
        try validate(base); try validate(local); try validate(browser)
        let b = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        let l = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let r = Dictionary(uniqueKeysWithValues: browser.map { ($0.id, $0) })
        var desired: [String: VivaldiNode] = [:]; var conflicts: [VivaldiConflict] = []
        for id in Set(b.keys).union(l.keys).union(r.keys).sorted() {
            let before = b[id], mine = l[id], theirs = r[id]
            if let theirs, theirs.locked { desired[id] = theirs; continue }
            let selected: VivaldiNode?
            if mine == theirs { selected = mine }
            else if mine == before { selected = theirs }
            else if theirs == before { selected = mine }
            else {
                let conflict = VivaldiConflict(key: id, base: before, local: mine, browser: theirs)
                if let keepLocal = choices[conflict.id] { selected = keepLocal ? mine : theirs }
                else { conflicts.append(conflict); selected = mine }
            }
            if let selected { desired[id] = selected }
        }
        // Keeping an edited descendant also keeps the folders required to contain it.
        for node in Array(desired.values) {
            var parent = node.parent; var seen: Set<String> = []
            while let id = parent, desired[id] == nil {
                guard seen.insert(id).inserted, let folder = l[id] ?? r[id] ?? b[id], folder.url == nil else {
                    throw TransferError(message: "Resolve the folder structure before syncing.")
                }
                desired[id] = folder; parent = folder.parent
            }
        }
        let result = sorted(Array(desired.values)); try validate(result)
        return VivaldiMerge(desired: result, conflicts: conflicts)
    }
    static func local(_ data: LibraryData, binding: VivaldiBinding) throws -> [VivaldiNode] {
        guard data.collections.contains(where: { $0.id == binding.root }) else { throw TransferError(message: "The synced collection was removed. Disconnect and pair again; browser bookmarks were not changed.") }
        let scope = LibraryLogic.descendants(of: binding.root, in: data.collections)
        let reverse = Dictionary(binding.mapping.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        func key(_ id: UUID) -> String { reverse[id] ?? "s:\(id.uuidString)" }
        func parent(_ id: UUID?) -> String? { id.flatMap { $0 == binding.root ? nil : key($0) } }
        let locked = Set(binding.baseline.filter(\.locked).map(\.id))
        var result = data.collections.filter { $0.id != binding.root && scope.contains($0.id) }.map {
            VivaldiNode(id: key($0.id), title: $0.name, parent: parent($0.parentID), locked: locked.contains(key($0.id)))
        }
        result += data.entries.filter { $0.kind == .url && $0.collectionID.map(scope.contains) == true }.map {
            VivaldiNode(id: key($0.id), title: $0.name, parent: parent($0.collectionID), url: $0.location)
        }
        try validate(result); return sorted(result)
    }
    static func remap(_ nodes: [VivaldiNode], created: [String: String]) -> [VivaldiNode] {
        sorted(nodes.map { node in var copy = node; copy.id = created[node.id] ?? node.id; copy.parent = node.parent.map { created[$0] ?? $0 }; return copy })
    }
    static func recreationAliases(_ desired: [VivaldiNode], binding: VivaldiBinding) -> [String: String] {
        let localIDs = Set(desired.filter { $0.id.hasPrefix("s:") }.map(\.id))
        return binding.mapping.reduce(into: [:]) { result, pair in
            let key = "s:\(pair.value.uuidString)"
            if localIDs.contains(key) { result[pair.key] = key }
        }
    }
    static func validateCreated(_ created: [String: String], desired: [VivaldiNode]) throws {
        let newIDs = Set(desired.filter { $0.id.hasPrefix("s:") }.map(\.id))
        guard Set(created.keys) == newIDs, Set(created.values).count == created.count,
              created.values.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("s:") && $0.count <= 128 }),
              !Set(created.values).contains(where: { id in desired.contains { $0.id == id } }) else { throw TransferError(message: "Invalid bookmark creation acknowledgement.") }
    }
    static func apply(_ desired: [VivaldiNode], expected: [VivaldiNode], created: [String: String], to data: LibraryData, binding: VivaldiBinding, transaction: UUID) throws -> LibraryData {
        try validateCreated(created, desired: desired)
        var candidate = data; var state = binding
        let aliases = recreationAliases(desired, binding: binding)
        for key in aliases.keys { state.mapping[key] = nil }
        for (key, remote) in created {
            guard let id = UUID(uuidString: String(key.dropFirst(2))) else { throw TransferError(message: "Invalid local bookmark identifier.") }
            state.mapping[remote] = id
        }
        let current = remap(try local(data, binding: binding), created: aliases)
        let normalizedExpected = remap(expected, created: aliases)
        let original = Dictionary(uniqueKeysWithValues: normalizedExpected.map { ($0.id, $0) })
        let now = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let target = Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0) })
        for node in desired where state.mapping[created[node.id] ?? node.id] == nil {
            state.mapping[created[node.id] ?? node.id] = node.id.hasPrefix("s:") ? UUID(uuidString: String(node.id.dropFirst(2))) ?? UUID() : UUID()
        }
        func localID(_ key: String) -> UUID? { state.mapping[created[key] ?? key] ?? (key.hasPrefix("s:") ? UUID(uuidString: String(key.dropFirst(2))) : nil) }
        for key in Set(original.keys).union(target.keys) where now[key] == original[key] {
            guard let id = localID(key) else { continue }
            if let node = target[key] {
                let parent = node.parent.flatMap(localID) ?? state.root
                if let url = node.url {
                    if let index = candidate.entries.firstIndex(where: { $0.id == id }) {
                        candidate.entries[index].name = node.title; candidate.entries[index].location = url; candidate.entries[index].collectionID = parent
                    } else { var entry = LibraryEntry(name: node.title, location: url, kind: .url, collectionID: parent); entry.id = id; candidate.entries.append(entry) }
                } else if let index = candidate.collections.firstIndex(where: { $0.id == id }) {
                    candidate.collections[index].name = node.title; candidate.collections[index].parentID = parent
                } else { var folder = LibraryCollection(name: node.title, parentID: parent); folder.id = id; candidate.collections.append(folder) }
            } else if now[key] != nil {
                candidate.entries.removeAll { $0.id == id }
                candidate.collections.removeAll { $0.id == id }
                // Local-only files and folders retain their references if a browser folder disappears.
                for index in candidate.entries.indices where candidate.entries[index].collectionID == id { candidate.entries[index].collectionID = state.root }
                for index in candidate.collections.indices where candidate.collections[index].parentID == id { candidate.collections[index].parentID = state.root }
            }
        }
        let remote = remap(desired, created: created)
        state.baseline = remote // Carry browser-controlled folder flags into the local projection.
        let final = Dictionary(uniqueKeysWithValues: try local(candidate, binding: state).map { ($0.id, $0) })
        let previous = Dictionary(uniqueKeysWithValues: remap(remap(binding.baseline, created: aliases), created: created).map { ($0.id, $0) })
        let staged = Dictionary(uniqueKeysWithValues: remap(normalizedExpected, created: created).map { ($0.id, $0) })
        let browser = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        var nextBaseline: [String: VivaldiNode] = [:]
        for id in Set(previous.keys).union(final.keys).union(browser.keys) {
            if let value = final[id] == browser[id] ? browser[id] : (previous[id] ?? staged[id]) { nextBaseline[id] = value }
        }
        // Unresolved descendants still need their old ancestor records for the next three-way comparison.
        for node in Array(nextBaseline.values) {
            var parent = node.parent; var seen: Set<String> = []
            while let id = parent, nextBaseline[id] == nil {
                guard seen.insert(id).inserted, let folder = previous[id] ?? staged[id] ?? browser[id] ?? final[id], folder.url == nil else {
                    throw TransferError(message: "A concurrent folder edit requires a fresh sync comparison.")
                }
                nextBaseline[id] = folder; parent = folder.parent
            }
        }
        state.baseline = sorted(Array(nextBaseline.values)); try validate(state.baseline)
        state.mapping = state.mapping.filter { browser[$0.key] != nil || final[$0.key] != nil || nextBaseline[$0.key] != nil }
        state.lastTransaction = transaction; candidate.vivaldi = state
        try LibraryIntegrity.validate(candidate); return candidate
    }
}

struct VivaldiRequest: Codable, Sendable {
    var action: String
    var client: String
    var scope: String
    var nodes: [VivaldiNode]
    var transaction: UUID?
    var created: [String: String]?
    var destination: String?
}
struct VivaldiPending: Codable {
    var id: UUID
    var scope: String
    var local: [VivaldiNode]
    var browser: [VivaldiNode]
    var desired: [VivaldiNode]
}
struct VivaldiResponse: Codable {
    var status: String
    var message: String
    var transaction: UUID?
    var desired: [VivaldiNode]?
    var before: [VivaldiNode]?
}
