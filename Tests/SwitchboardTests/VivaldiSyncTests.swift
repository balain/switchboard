import XCTest
@testable import Switchboard

final class VivaldiSyncTests: XCTestCase {
    private func node(_ id: String = "10", title: String = "Example", parent: String? = nil, url: String? = "https://example.com", locked: Bool = false) -> VivaldiNode {
        VivaldiNode(id: id, title: title, parent: parent, url: url, locked: locked)
    }
    func testValidWebAddressesNeedNotMatchFoundationsSerializedSpelling() throws {
        for address in ["https://example.com/a file.pdf", "https://example.com/Ω?q=hello world", "https://例え.テスト/資料", "HTTP://EXAMPLE.COM/report|draft"] {
            let value = node(url: address)
            try VivaldiGraph.validate([value], source: "Vivaldi")
            XCTAssertEqual(try VivaldiGraph.merge(base: [], local: [], browser: [value], choices: [:]).desired.first?.url, address)
        }
    }
    func testAddressErrorsIdentifyBookmarksAndFoldersWithoutLeakingCredentials() throws {
        let folder = node("1", title: "Research", url: nil)
        let malformed = node("2", title: "Broken report", parent: "1", url: "https://user:private-password@?token=private-token")
        let unsupported = node("3", title: "Internal page", parent: "1", url: "vivaldi://settings")
        XCTAssertThrowsError(try VivaldiGraph.validate([folder, malformed, unsupported], source: "Vivaldi")) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Vivaldi")); XCTAssertTrue(message.contains("Research / Broken report"))
            XCTAssertTrue(message.contains("Research / Internal page")); XCTAssertTrue(message.contains("malformed web address"))
            XCTAssertFalse(message.contains("private-password")); XCTAssertFalse(message.contains("private-token"))
        }
        XCTAssertThrowsError(try VivaldiGraph.validate([node(url: "example.com")]))
    }
    func testThreeWayMergeHandlesIndependentEditsAndDeletion() throws {
        let original = node(), folder = node("20", title: "Folder", url: nil)
        let local = node(title: "Local rename"), browser = node("30", title: "Browser addition")
        let result = try VivaldiGraph.merge(base: [original, folder], local: [local, folder], browser: [original, browser], choices: [:])
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(result.desired, [local, browser])
    }
    func testConflictsAreSnapshotSpecificAndKeepingDescendantRestoresItsParent() throws {
        let folder = node("20", title: "Folder", url: nil), before = node(parent: "20")
        let changed = node(title: "Local", parent: "20")
        let pending = try VivaldiGraph.merge(base: [folder, before], local: [folder, changed], browser: [], choices: [:])
        let conflict = try XCTUnwrap(pending.conflicts.first)
        XCTAssertEqual(pending.conflicts.count, 1)
        let keep = try VivaldiGraph.merge(base: [folder, before], local: [folder, changed], browser: [], choices: [conflict.id: true])
        XCTAssertEqual(keep.desired.count, 2); XCTAssertTrue(keep.conflicts.isEmpty)
        let stale = try VivaldiGraph.merge(base: [folder, before], local: [folder, node(title: "Another", parent: "20")], browser: [], choices: [conflict.id: false])
        XCTAssertEqual(stale.conflicts.count, 1)
    }
    func testProtectedFoldersAndInvalidSnapshots() throws {
        let fixed = node("1", title: "Bookmarks", url: nil, locked: true)
        XCTAssertEqual(try VivaldiGraph.merge(base: [fixed], local: [], browser: [fixed], choices: [:]).desired, [fixed])
        XCTAssertThrowsError(try VivaldiGraph.validate([node(url: "javascript:alert(1)")]))
        XCTAssertThrowsError(try VivaldiGraph.validate([node(parent: "missing")]))
        XCTAssertThrowsError(try VivaldiGraph.validate([node("1", parent: "2", url: nil), node("2", parent: "1", url: nil)]))
        XCTAssertThrowsError(try VivaldiGraph.validate([node(), node()]))
    }
    func testAcknowledgementPreservesLocalMetadataAndConcurrentChanges() throws {
        var data = LibraryData(); let root = LibraryCollection(name: "Vivaldi")
        data.collections = [root]
        var entry = LibraryEntry(name: "Original", location: "https://example.com", kind: .url, notes: "Local note", tags: ["Research"], collectionID: root.id, favorite: true)
        data.tags = [LibraryTag(name: "Research")]; data.entries = [entry]
        let base = node(title: "Original")
        let binding = VivaldiBinding(connection: UUID(), scope: "one", root: root.id, mapping: [base.id: entry.id], baseline: [base])
        data.vivaldi = binding
        let updated = node(title: "Browser rename")
        let result = try VivaldiGraph.apply([updated], expected: [base], created: [:], to: data, binding: binding, transaction: UUID())
        XCTAssertEqual(result.entries[0].name, "Browser rename"); XCTAssertEqual(result.entries[0].notes, entry.notes)
        XCTAssertEqual(result.entries[0].tags, entry.tags); XCTAssertTrue(result.entries[0].favorite)
        entry.name = "Concurrent local rename"; data.entries = [entry]
        let raced = try VivaldiGraph.apply([updated], expected: [base], created: [:], to: data, binding: binding, transaction: UUID())
        XCTAssertEqual(raced.entries[0].name, entry.name); XCTAssertEqual(raced.vivaldi?.baseline, [base])
        XCTAssertEqual(try VivaldiGraph.merge(base: raced.vivaldi!.baseline, local: VivaldiGraph.local(raced, binding: raced.vivaldi!), browser: [updated], choices: [:]).conflicts.count, 1)
    }
    func testConcurrentDeletionDuringCreationIsNotResurrected() throws {
        let root = LibraryCollection(name: "Vivaldi"), id = UUID()
        var data = LibraryData(); data.collections = [root]
        let staged = node("s:\(id.uuidString)")
        let binding = VivaldiBinding(connection: UUID(), scope: "one", root: root.id)
        let result = try VivaldiGraph.apply([staged], expected: [staged], created: [staged.id: "42"], to: data, binding: binding, transaction: UUID())
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.vivaldi?.mapping["42"], id)
        let browser = node("42")
        XCTAssertTrue(try VivaldiGraph.merge(base: result.vivaldi!.baseline, local: [], browser: [browser], choices: [:]).desired.isEmpty)
    }
    func testDeletingBrowserFolderKeepsLocalFileReference() throws {
        let root = LibraryCollection(name: "Vivaldi"), folder = LibraryCollection(name: "Folder")
        var child = folder; child.parentID = root.id
        let file = LibraryEntry(name: "Local file", location: "/tmp/sync-fixture.txt", kind: .file, collectionID: child.id)
        var data = LibraryData(); data.collections = [root, child]; data.entries = [file]
        let original = node("20", title: "Folder", url: nil)
        let binding = VivaldiBinding(connection: UUID(), scope: "one", root: root.id, mapping: ["20": child.id], baseline: [original])
        let result = try VivaldiGraph.apply([], expected: [original], created: [:], to: data, binding: binding, transaction: UUID())
        XCTAssertEqual(result.entries[0].id, file.id); XCTAssertEqual(result.entries[0].location, file.location)
        XCTAssertEqual(result.entries[0].collectionID, root.id); XCTAssertEqual(result.collections.count, 1)
    }
    func testConcurrentDescendantEditRetainsAValidBaselineAfterParentDeletion() throws {
        let root = LibraryCollection(name: "Vivaldi"), folder = LibraryCollection(name: "Folder")
        var child = folder; child.parentID = root.id
        var entry = LibraryEntry(name: "Edited during sync", location: "https://example.com", kind: .url, collectionID: child.id)
        var data = LibraryData(); data.collections = [root, child]; data.entries = [entry]
        let before = [node("10", title: "Before", parent: "20"), node("20", title: "Folder", url: nil)]
        let binding = VivaldiBinding(connection: UUID(), scope: "one", root: root.id, mapping: ["10": entry.id, "20": child.id], baseline: before)
        let result = try VivaldiGraph.apply([], expected: before, created: [:], to: data, binding: binding, transaction: UUID())
        XCTAssertEqual(result.entries[0].name, entry.name)
        try VivaldiGraph.validate(result.vivaldi!.baseline)
        XCTAssertTrue(result.vivaldi!.baseline.contains { $0.id == "20" })
        entry = result.entries[0]; XCTAssertEqual(entry.collectionID, root.id)
    }
    func testDeletedBrowserIdentitiesAreReleasedSoUndoCanRecreateBookmarks() throws {
        let root = LibraryCollection(name: "Vivaldi"), id = UUID()
        var data = LibraryData(); data.collections = [root]
        let before = node()
        let binding = VivaldiBinding(connection: UUID(), scope: "one", root: root.id, mapping: [before.id: id], baseline: [before])
        let result = try VivaldiGraph.apply([], expected: [], created: [:], to: data, binding: binding, transaction: UUID())
        XCTAssertTrue(result.vivaldi!.mapping.isEmpty); XCTAssertTrue(result.vivaldi!.baseline.isEmpty)
        var restored = result; var entry = LibraryEntry(name: "Restored", location: "https://example.com", kind: .url, collectionID: root.id); entry.id = id; restored.entries = [entry]
        XCTAssertTrue(try VivaldiGraph.local(restored, binding: result.vivaldi!)[0].id.hasPrefix("s:"))
    }
    @MainActor func testCoordinatorPersistsPendingSyncAndAcknowledgementIsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(storageURL: directory.appendingPathComponent("library.json"))
        let config = directory.appendingPathComponent("connection.json")
        let coordinator = VivaldiSyncCoordinator(store: store, configurationURL: config, automaticallyStart: false)
        let request = VivaldiRequest(action: "plan", client: "synthetic-client-identity", scope: "1", nodes: [node()])
        let plan = try coordinator.handle(request); XCTAssertEqual(plan.status, "apply"); XCTAssertTrue(store.data.entries.isEmpty)
        let restored = VivaldiSyncCoordinator(store: store, configurationURL: config, automaticallyStart: false)
        XCTAssertEqual(try restored.handle(request).transaction, plan.transaction)
        let ack = VivaldiRequest(action: "ack", client: request.client, scope: request.scope, nodes: request.nodes, transaction: plan.transaction, created: [:])
        XCTAssertEqual(try restored.handle(ack).status, "complete"); XCTAssertEqual(store.data.entries.count, 1)
        XCTAssertEqual(try restored.handle(ack).status, "complete"); XCTAssertEqual(store.data.entries.count, 1)
        XCTAssertEqual(try restored.handle(request).status, "complete")
        let bytes = try Data(contentsOf: config); XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("/Users/"))
        let exported = try LibraryTransfer.export(store.data, format: .json)
        XCTAssertNil((try JSONSerialization.jsonObject(with: exported) as? [String: Any])?["vivaldi"])
        var wrong = request; wrong.scope = "different"; XCTAssertThrowsError(try restored.handle(wrong))
        wrong = request; wrong.client = "a-different-client-identity"; XCTAssertThrowsError(try restored.handle(wrong))
    }
    @MainActor func testStaleAcknowledgementsAndFailedWritesDoNotPublish() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var fail = false
        let store = LibraryStore(storageURL: directory.appendingPathComponent("library.json")) { data, url in if fail { throw CocoaError(.fileWriteNoPermission) }; try data.write(to: url, options: .atomic) }
        let sync = VivaldiSyncCoordinator(store: store, configurationURL: directory.appendingPathComponent("connection.json"), automaticallyStart: false)
        let plan = try sync.handle(VivaldiRequest(action: "plan", client: "synthetic-client-identity", scope: "1", nodes: [node()]))
        var ack = VivaldiRequest(action: "ack", client: "synthetic-client-identity", scope: "1", nodes: [node(title: "Raced")], transaction: plan.transaction, created: [:])
        XCTAssertThrowsError(try sync.handle(ack)); XCTAssertTrue(store.data.entries.isEmpty)
        ack.nodes = [node()]; fail = true; XCTAssertThrowsError(try sync.handle(ack)); XCTAssertTrue(store.data.entries.isEmpty)
        fail = false; XCTAssertEqual(try sync.handle(ack).status, "complete"); XCTAssertEqual(store.data.entries.count, 1)
    }
    @MainActor func testLargeDeletionNeedsExactSnapshotApprovalAndRestoreRequiresPairing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(storageURL: directory.appendingPathComponent("library.json"))
        let config = directory.appendingPathComponent("connection.json")
        let sync = VivaldiSyncCoordinator(store: store, configurationURL: config, automaticallyStart: false)
        let client = "synthetic-client-identity"
        let first = try sync.handle(VivaldiRequest(action: "plan", client: client, scope: "1", nodes: [node()]))
        _ = try sync.handle(VivaldiRequest(action: "ack", client: client, scope: "1", nodes: [node()], transaction: first.transaction, created: [:]))
        let backup = try XCTUnwrap(store.backupNow())
        let deleted = VivaldiRequest(action: "plan", client: client, scope: "1", nodes: [])
        XCTAssertEqual(try sync.handle(deleted).status, "review"); XCTAssertEqual(sync.deletions, 1)
        sync.approveDeletions(); let plan = try sync.handle(deleted); XCTAssertEqual(plan.status, "apply")
        _ = try sync.handle(VivaldiRequest(action: "ack", client: client, scope: "1", nodes: [], transaction: plan.transaction, created: [:]))
        XCTAssertTrue(store.data.entries.isEmpty)
        XCTAssertTrue(store.restoreLibrary(try Data(contentsOf: backup)))
        XCTAssertThrowsError(try sync.handle(deleted))
        let persisted = try JSONDecoder().decode(VivaldiConfiguration.self, from: Data(contentsOf: config)); XCTAssertTrue(persisted.reconnectRequired); XCTAssertFalse(persisted.enabled)
    }
    @MainActor func testNewRootEntriesUseTheChosenBrowserDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(storageURL: directory.appendingPathComponent("library.json"))
        let sync = VivaldiSyncCoordinator(store: store, configurationURL: directory.appendingPathComponent("connection.json"), automaticallyStart: false)
        let folder = node("1", title: "Bookmarks", url: nil, locked: true), client = "synthetic-client-identity"
        let first = try sync.handle(VivaldiRequest(action: "plan", client: client, scope: "1", nodes: [folder]))
        _ = try sync.handle(VivaldiRequest(action: "ack", client: client, scope: "1", nodes: [folder], transaction: first.transaction, created: [:]))
        let root = try XCTUnwrap(store.data.vivaldi?.root)
        let id = try XCTUnwrap(store.addURL(name: "New", location: "https://example.org", collectionID: root))
        let plan = try sync.handle(VivaldiRequest(action: "plan", client: client, scope: "1", nodes: [folder], destination: "1"))
        let new = try XCTUnwrap(plan.desired?.first { $0.id.hasPrefix("s:") }); XCTAssertEqual(new.parent, "1")
        let browser = VivaldiGraph.remap(plan.desired!, created: [new.id: "42"])
        _ = try sync.handle(VivaldiRequest(action: "ack", client: client, scope: "1", nodes: browser, transaction: plan.transaction, created: [new.id: "42"]))
        XCTAssertEqual(store.data.entries.first { $0.id == id }?.collectionID, store.data.vivaldi?.mapping["1"])
        XCTAssertEqual(try sync.handle(VivaldiRequest(action: "plan", client: client, scope: "1", nodes: browser, destination: "1")).status, "complete")
    }
    @MainActor func testInterruptedCreationCanReconcileWithoutDuplicateBookmarks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(storageURL: directory.appendingPathComponent("library.json"))
        let sync = VivaldiSyncCoordinator(store: store, configurationURL: directory.appendingPathComponent("connection.json"), automaticallyStart: false)
        let folder = node("1", title: "Bookmarks", url: nil, locked: true), client = "synthetic-client-identity"
        let first = try sync.handle(VivaldiRequest(action: "plan", client: client, scope: "1", nodes: [folder]))
        _ = try sync.handle(VivaldiRequest(action: "ack", client: client, scope: "1", nodes: [folder], transaction: first.transaction, created: [:]))
        let root = try XCTUnwrap(store.data.vivaldi?.root)
        let id = try XCTUnwrap(store.addURL(name: "New", location: "https://example.org", collectionID: root))
        let plan = try sync.handle(VivaldiRequest(action: "plan", client: client, scope: "1", nodes: [folder], destination: "1"))
        let created = ["s:\(id.uuidString)": "42"]
        let browser = VivaldiGraph.remap(plan.desired!, created: created)
        let abort = VivaldiRequest(action: "abort", client: client, scope: "1", nodes: browser, transaction: plan.transaction, created: created)
        XCTAssertEqual(try sync.handle(abort).status, "complete"); XCTAssertEqual(try sync.handle(abort).status, "complete")
        let fresh = try sync.handle(VivaldiRequest(action: "plan", client: client, scope: "1", nodes: browser, destination: "1"))
        XCTAssertEqual(fresh.status, "apply"); XCTAssertEqual(fresh.desired, browser)
        _ = try sync.handle(VivaldiRequest(action: "ack", client: client, scope: "1", nodes: browser, transaction: fresh.transaction, created: [:]))
        XCTAssertEqual(store.data.entries.count, 1); XCTAssertEqual(store.data.entries[0].id, id)
    }
    @MainActor func testKeepingLocalAfterBrowserDeletionRecreatesWithANewBrowserIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(storageURL: directory.appendingPathComponent("library.json"))
        let sync = VivaldiSyncCoordinator(store: store, configurationURL: directory.appendingPathComponent("connection.json"), automaticallyStart: false)
        let folder = node("1", title: "Bookmarks", url: nil, locked: true), before = node(parent: "1"), client = "synthetic-client-identity"
        let initial = [folder, before]
        let first = try sync.handle(VivaldiRequest(action: "plan", client: client, scope: "1", nodes: initial))
        _ = try sync.handle(VivaldiRequest(action: "ack", client: client, scope: "1", nodes: initial, transaction: first.transaction, created: [:]))
        var entry = try XCTUnwrap(store.data.entries.first); entry.name = "Keep local edit"; store.update(entry)
        let request = VivaldiRequest(action: "plan", client: client, scope: "1", nodes: [folder], destination: "1")
        XCTAssertEqual(try sync.handle(request).status, "review")
        sync.resolve(try XCTUnwrap(sync.conflicts.first), keepLocal: true)
        let plan = try sync.handle(request); let replacement = try XCTUnwrap(plan.desired?.first { $0.id.hasPrefix("s:") })
        XCTAssertEqual(replacement.id, "s:\(entry.id.uuidString)")
        let remote = VivaldiGraph.remap(plan.desired!, created: [replacement.id: "99"])
        _ = try sync.handle(VivaldiRequest(action: "ack", client: client, scope: "1", nodes: remote, transaction: plan.transaction, created: [replacement.id: "99"]))
        XCTAssertEqual(store.data.entries.count, 1); XCTAssertEqual(store.data.entries[0].id, entry.id)
        XCTAssertEqual(store.data.vivaldi?.mapping["99"], entry.id); XCTAssertNil(store.data.vivaldi?.mapping[before.id])
        XCTAssertEqual(try sync.handle(VivaldiRequest(action: "plan", client: client, scope: "1", nodes: remote, destination: "1")).status, "complete")
    }
    @MainActor func testRepeatedTwoWayCyclesConvergeAfterAddsEditsAndDeletes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(storageURL: directory.appendingPathComponent("library.json"))
        let sync = VivaldiSyncCoordinator(store: store, configurationURL: directory.appendingPathComponent("connection.json"), automaticallyStart: false)
        let folder = node("1", title: "Bookmarks", url: nil, locked: true), client = "synthetic-client-identity"
        var browser = [folder, node("2", parent: "1")]; var counter = 100
        func converge() throws {
            let request = VivaldiRequest(action: "plan", client: client, scope: "1", nodes: browser, destination: "1")
            var plan = try sync.handle(request)
            if plan.status == "review" {
                for conflict in sync.conflicts { sync.resolve(conflict, keepLocal: true) }
                sync.approveDeletions(); plan = try sync.handle(request)
            }
            if plan.status == "apply" {
                var created: [String: String] = [:]
                for node in plan.desired! where node.id.hasPrefix("s:") { counter += 1; created[node.id] = String(counter) }
                browser = VivaldiGraph.remap(plan.desired!, created: created)
                _ = try sync.handle(VivaldiRequest(action: "ack", client: client, scope: "1", nodes: browser, transaction: plan.transaction, created: created))
            }
            XCTAssertEqual(try sync.handle(VivaldiRequest(action: "plan", client: client, scope: "1", nodes: browser, destination: "1")).status, "complete")
            XCTAssertEqual(store.data.entries.count, browser.filter { $0.url != nil }.count)
            try VivaldiGraph.validate(store.data.vivaldi!.baseline)
        }
        try converge()
        for index in 0..<36 {
            switch index % 6 {
            case 0: counter += 1; browser.append(node(String(counter), title: "Browser \(index)", parent: "1"))
            case 1: if var entry = store.data.entries.first { entry.name = "Local edit \(index)"; store.update(entry) }
            case 2: if let position = browser.firstIndex(where: { $0.url != nil }) { browser[position].title = "Browser edit \(index)" }
            case 3: _ = store.addURL(name: "Local addition \(index)", location: "https://example.org/\(index)", collectionID: store.data.vivaldi!.mapping["1"])
            case 4: if let position = browser.firstIndex(where: { $0.url != nil }) { browser.remove(at: position) }
            default: if let entry = store.data.entries.last { _ = store.remove([entry.id]) }
            }
            try converge()
        }
    }
    func testHTTPRejectsSmugglingUntrustedOriginsAndBadCredentials() throws {
        let good = Data("POST /sync HTTP/1.1\r\nHost: 127.0.0.1:1\r\nContent-Length: 2\r\n\r\n{}".utf8)
        XCTAssertEqual(try VivaldiHTTP.parse(good)?.body, Data("{}".utf8))
        XCTAssertNil(try VivaldiHTTP.parse(good.dropLast()))
        XCTAssertThrowsError(try VivaldiHTTP.parse(good + Data("extra".utf8)))
        XCTAssertThrowsError(try VivaldiHTTP.parse(Data("POST /sync HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 2\r\n\r\n".utf8)))
        XCTAssertThrowsError(try VivaldiHTTP.parse(Data("POST /sync HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)))
        XCTAssertThrowsError(try VivaldiHTTP.parse(Data(repeating: 0, count: 16_385)))
        XCTAssertFalse(VivaldiHTTP.allowedOrigin("https://example.com")); XCTAssertFalse(VivaldiHTTP.allowedOrigin("null"))
        XCTAssertTrue(VivaldiHTTP.allowedOrigin("chrome-extension://" + String(repeating: "a", count: 32)))
        XCTAssertFalse(VivaldiHTTP.authenticates("Bearer wrong", token: "correct")); XCTAssertTrue(VivaldiHTTP.authenticates("Bearer correct", token: "correct"))
    }
    func testLiveBridgeBindsLoopbackAndAuthenticatesRequests() async throws {
        let server = try VivaldiBridge(port: 0, token: "test-token") { bytes in bytes }
        defer { server.stop() }
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            server.ready = { continuation.resume(with: $0) }; server.start()
        }
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/sync")!)
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, rejected) = try await session.data(for: request); XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 401)
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        let (bytes, accepted) = try await session.data(for: request); XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200); XCTAssertEqual(bytes, request.httpBody)
        request.setValue("https://example.com", forHTTPHeaderField: "Origin")
        let (_, origin) = try await session.data(for: request); XCTAssertEqual((origin as? HTTPURLResponse)?.statusCode, 400)
    }
}
