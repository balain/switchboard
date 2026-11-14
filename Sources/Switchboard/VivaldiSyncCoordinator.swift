import SwiftUI
import AppKit
import Combine

struct VivaldiConfiguration: Codable {
    var connection = UUID()
    var token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    var port: UInt16 = 0
    var enabled = false
    var client: String?
    var pending: VivaldiPending?
    var reconnectRequired = false
}

@MainActor final class VivaldiSyncCoordinator: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var message = "Not paired."
    @Published private(set) var pairingCode = ""
    @Published private(set) var conflicts: [VivaldiConflict] = []
    @Published private(set) var deletions = 0
    @Published private(set) var lastSync: Date?
    private var choices: [String: Bool] = [:]
    private var deletionDigest: String?
    private var approvedDeletion: String?
    private var configuration = VivaldiConfiguration()
    private let configurationURL: URL
    private let store: LibraryStore
    private var bridge: VivaldiBridge?
    private var restoration: AnyCancellable?
    init(store: LibraryStore, configurationURL: URL? = nil, automaticallyStart: Bool = true) {
        self.store = store
        self.configurationURL = configurationURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Switchboard/VivaldiSync/connection.json")
        do {
            if FileManager.default.fileExists(atPath: self.configurationURL.path) {
                configuration = try JSONDecoder().decode(VivaldiConfiguration.self, from: Data(contentsOf: self.configurationURL))
            }
        } catch { message = "Could not read sync settings. Pair again to recover." }
        restoration = NotificationCenter.default.publisher(for: .libraryReplaced, object: store).sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pause(); self.configuration.reconnectRequired = true; self.configuration.pending = nil
                try? self.saveConfiguration()
                self.message = "Library restored. Pair again to review a fresh browser snapshot before syncing."
            }
        }
        if automaticallyStart && configuration.enabled && !configuration.reconnectRequired { start() }
    }
    deinit { bridge?.stop() }
    private func saveConfiguration() throws {
        try FileManager.default.createDirectory(at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configurationURL.deletingLastPathComponent().path)
        try JSONEncoder().encode(configuration).write(to: configurationURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
    }
    func start() {
        guard !configuration.reconnectRequired else { message = "Pair again after restoring a library."; return }
        bridge?.stop(); configuration.enabled = true
        do {
            try saveConfiguration()
            let connection = configuration.connection
            let server = try VivaldiBridge(port: configuration.port, token: configuration.token) { [weak self] bytes in
                do {
                    let request = try JSONDecoder().decode(VivaldiRequest.self, from: bytes)
                    let response = try await MainActor.run {
                        guard let self, self.enabled, self.configuration.connection == connection else { throw TransferError(message: "Sync is paused.") }
                        return try self.handle(request)
                    }
                    return try JSONEncoder().encode(response)
                } catch {
                    await MainActor.run { self?.message = error.localizedDescription }
                    throw error
                }
            }
            server.ready = { [weak self, weak server] result in
                Task { @MainActor in
                    guard let self, let server, self.bridge === server else { return }
                    switch result {
                    case .success(let port):
                        self.configuration.port = port
                        do { try self.saveConfiguration(); self.enabled = true; self.pairingCode = "http://127.0.0.1:\(port)#\(self.configuration.token)"; self.message = "Waiting for Vivaldi. Both apps must be running." }
                        catch { self.pause(); self.message = error.localizedDescription }
                    case .failure(let error): self.pause(); self.message = "Could not start bookmark sync: \(error.localizedDescription)"
                    }
                }
            }
            bridge = server; server.start()
        } catch { configuration.enabled = false; enabled = false; message = error.localizedDescription }
    }
    func pause() { bridge?.stop(); bridge = nil; enabled = false; pairingCode = ""; configuration.enabled = false; do { try saveConfiguration(); message = "Paused. Resume to continue with the same pairing." } catch { message = error.localizedDescription } }
    func pairAgain() {
        pause(); configuration = VivaldiConfiguration(); conflicts = []; choices = [:]; deletions = 0; approvedDeletion = nil
        do { try saveConfiguration(); start() } catch { message = error.localizedDescription }
    }
    func disconnect() {
        pause(); configuration = VivaldiConfiguration(); conflicts = []; choices = [:]; deletions = 0
        do { try saveConfiguration(); message = "Disconnected. Existing bookmarks and library entries were kept." } catch { message = error.localizedDescription }
    }
    func resolve(_ conflict: VivaldiConflict, keepLocal: Bool) { choices[conflict.id] = keepLocal; conflicts.removeAll { $0.id == conflict.id }; message = "Choice saved. Vivaldi will retry on its next sync." }
    func approveDeletions() { approvedDeletion = deletionDigest; deletions = 0; message = "Deletion review approved for this exact snapshot. Waiting for Vivaldi." }
    func handle(_ request: VivaldiRequest) throws -> VivaldiResponse {
        guard request.client.count >= 16, request.client.count <= 128, !request.scope.isEmpty, request.scope.count <= 256 else { throw TransferError(message: "Invalid browser identity or scope.") }
        guard configuration.client == nil || configuration.client == request.client else { throw TransferError(message: "This pairing belongs to another Vivaldi profile. Pair again for a different profile.") }
        guard !configuration.reconnectRequired else { throw TransferError(message: "Pair again after restoring the library.") }
        try VivaldiGraph.validate(request.nodes, source: "Vivaldi")
        if request.nodes.contains(where: { $0.id.hasPrefix("s:") }) { throw TransferError(message: "Browser identifiers cannot use local identifiers.") }
        var binding: VivaldiBinding
        if let current = store.data.vivaldi, current.connection == configuration.connection {
            guard current.scope == request.scope else { throw TransferError(message: "The bookmark selection changed. Pair again to establish a new scope without interpreting excluded bookmarks as deletions.") }
            binding = current
        } else {
            guard request.action == "plan", configuration.pending == nil else { throw TransferError(message: "No matching library binding. Pair again.") }
            var data = store.data; let root = LibraryCollection(name: "Vivaldi Bookmarks")
            data.collections.append(root)
            binding = VivaldiBinding(connection: configuration.connection, scope: request.scope, root: root.id)
            data.vivaldi = binding
            guard store.commitVivaldi(data, checkpoint: true) else { throw TransferError(message: store.error ?? "Could not create the synced collection.") }
        }
        let newClient = configuration.client != request.client
        configuration.client = request.client
        if request.action == "ack", request.transaction == binding.lastTransaction, request.transaction != nil {
            if configuration.pending?.id == request.transaction { configuration.pending = nil }
            try saveConfiguration(); return VivaldiResponse(status: "complete", message: "Already acknowledged.")
        }
        if request.action == "abort" {
            if request.transaction != nil, request.transaction == binding.lastAborted {
                if configuration.pending?.id == request.transaction { configuration.pending = nil }
                try saveConfiguration(); return VivaldiResponse(status: "complete", message: "Already reconciled.")
            }
            guard let pending = configuration.pending, request.transaction == pending.id else { throw TransferError(message: "No matching interrupted transaction.") }
            let created = request.created ?? [:]
            guard Set(created.keys).isSubset(of: Set(pending.desired.filter { $0.id.hasPrefix("s:") }.map(\.id))), Set(created.values).count == created.count,
                  created.values.allSatisfy({ !$0.hasPrefix("s:") && !$0.isEmpty }), !Set(created.values).contains(where: { binding.mapping[$0] != nil }) else { throw TransferError(message: "Invalid interrupted creation mapping.") }
            let aliases = VivaldiGraph.recreationAliases(pending.desired, binding: binding).filter { created[$0.value] != nil }
            for key in aliases.keys { binding.mapping[key] = nil }
            binding.baseline = VivaldiGraph.remap(VivaldiGraph.remap(binding.baseline, created: aliases), created: created)
            for (key, remote) in created { guard let id = UUID(uuidString: String(key.dropFirst(2))) else { throw TransferError(message: "Invalid local ID.") }; binding.mapping[remote] = id }
            let staged = Dictionary(uniqueKeysWithValues: VivaldiGraph.remap(VivaldiGraph.remap(pending.local, created: aliases), created: created).map { ($0.id, $0) })
            var base = Dictionary(uniqueKeysWithValues: binding.baseline.map { ($0.id, $0) })
            for id in created.values {
                var next: String? = id; var seen: Set<String> = []
                while let key = next, base[key] == nil, seen.insert(key).inserted, let node = staged[key] { base[key] = node; next = node.parent }
            }
            binding.baseline = VivaldiGraph.sorted(Array(base.values)); try VivaldiGraph.validate(binding.baseline)
            binding.lastAborted = pending.id
            var data = store.data; data.vivaldi = binding
            guard store.commitVivaldi(data, checkpoint: false) else { throw TransferError(message: store.error ?? "Could not retain interrupted bookmark identities.") }
            configuration.pending = nil; try saveConfiguration(); return VivaldiResponse(status: "complete", message: "Interrupted changes retained. A fresh three-way comparison will follow.")
        }
        if let pending = configuration.pending {
            guard pending.scope == request.scope else { throw TransferError(message: "An earlier sync needs reconciliation.") }
            if request.action == "plan" { try saveConfiguration(); return VivaldiResponse(status: "apply", message: "Resume the pending transaction.", transaction: pending.id, desired: pending.desired, before: pending.browser) }
            guard request.action == "ack", request.transaction == pending.id else { throw TransferError(message: "A stale sync acknowledgement was rejected.") }
            let created = request.created ?? [:]
            try VivaldiGraph.validateCreated(created, desired: pending.desired)
            guard VivaldiGraph.sorted(request.nodes) == VivaldiGraph.remap(pending.desired, created: created) else { throw TransferError(message: "Vivaldi changed during sync. Reconcile the interrupted sync in the extension.") }
            let candidate = try VivaldiGraph.apply(pending.desired, expected: pending.local, created: created, to: store.data, binding: binding, transaction: pending.id)
            let changed = candidate.entries != store.data.entries || candidate.collections != store.data.collections
            guard store.commitVivaldi(candidate, checkpoint: changed) else { throw TransferError(message: store.error ?? "Could not save synchronized bookmarks.") }
            configuration.pending = nil; try saveConfiguration()
            lastSync = Date(); conflicts = []; choices = [:]; deletions = 0
            message = "Synced \(request.nodes.count) bookmarks and folders."
            return VivaldiResponse(status: "complete", message: message)
        }
        guard request.action == "plan" else { throw TransferError(message: "No pending transaction matches this acknowledgement.") }
        let local = try VivaldiGraph.local(store.data, binding: binding)
        // Still validate both live snapshots, but skip merge, hashing and disk writes when unchanged.
        if local == binding.baseline && local == VivaldiGraph.sorted(request.nodes) {
            if newClient { try saveConfiguration() }
            conflicts = []; choices = [:]; deletions = 0; deletionDigest = nil; approvedDeletion = nil
            lastSync = Date(); message = "Up to date. \(local.count) bookmarks and folders."
            return VivaldiResponse(status: "complete", message: message)
        }
        var outgoing = local
        let baseline = Dictionary(uniqueKeysWithValues: binding.baseline.map { ($0.id, $0) })
        for index in outgoing.indices where outgoing[index].parent == nil && (outgoing[index].id.hasPrefix("s:") || baseline[outgoing[index].id]?.parent != nil) {
            guard let destination = request.destination, request.nodes.contains(where: { $0.id == destination && $0.url == nil }), outgoing[index].id != destination else {
                throw TransferError(message: "Choose a destination folder in the Vivaldi extension before adding or moving items at the sync root.")
            }
            outgoing[index].parent = destination
        }
        var result = try VivaldiGraph.merge(base: binding.baseline, local: outgoing, browser: request.nodes, choices: choices)
        conflicts = result.conflicts
        if !conflicts.isEmpty { message = "Review \(conflicts.count) conflicting changes."; try saveConfiguration(); return VivaldiResponse(status: "review", message: message) }
        let browserIDs = Set(request.nodes.map(\.id))
        var recreations: [String: String] = [:]
        for node in result.desired where !node.id.hasPrefix("s:") && !browserIDs.contains(node.id) {
            guard let id = binding.mapping[node.id] else { throw TransferError(message: "A removed bookmark needs a new pairing before it can be recreated.") }
            recreations[node.id] = "s:\(id.uuidString)"
        }
        result.desired = VivaldiGraph.remap(result.desired, created: recreations)
        try VivaldiGraph.validate(result.desired)
        let desiredIDs = Set(result.desired.map(\.id)).union(recreations.keys)
        let removed = Set(local.map(\.id)).union(request.nodes.map(\.id)).subtracting(desiredIDs).count
        deletionDigest = VivaldiGraph.digest([local, VivaldiGraph.sorted(request.nodes), result.desired])
        if removed > 0 && (removed >= 10 || removed * 2 >= max(1, binding.baseline.count)), approvedDeletion != deletionDigest {
            deletions = removed; message = "Review deletion of \(removed) synced bookmarks or folders."; try saveConfiguration(); return VivaldiResponse(status: "review", message: message)
        }
        configuration.pending = VivaldiPending(id: UUID(), scope: request.scope, local: local, browser: VivaldiGraph.sorted(request.nodes), desired: result.desired)
        try saveConfiguration(); approvedDeletion = nil
        return VivaldiResponse(status: "apply", message: "Apply synchronized changes.", transaction: configuration.pending?.id, desired: result.desired, before: VivaldiGraph.sorted(request.nodes))
    }
}
