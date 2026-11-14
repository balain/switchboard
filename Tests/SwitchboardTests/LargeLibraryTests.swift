import XCTest
@testable import Switchboard

final class LargeLibraryTests: XCTestCase {
    @MainActor func testThreeThousandBookmarkSync() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(storageURL: directory.appendingPathComponent("library.json"))
        let config = directory.appendingPathComponent("connection.json")
        let sync = VivaldiSyncCoordinator(store: store, configurationURL: config, automaticallyStart: false)
        var nodes = (0..<190).map { VivaldiNode(id: "f\($0)", title: "Folder \($0)", parent: $0 == 0 ? nil : "f0") }
        nodes += (0..<3000).map { VivaldiNode(id: "b\($0)", title: "Bookmark \($0)", parent: "f\($0 % 190)", url: "https://example.com/\($0)") }
        let request = VivaldiRequest(action: "plan", client: "synthetic-large-library-client", scope: "large", nodes: nodes)
        let start = Date()
        let plan = try sync.handle(request)
        XCTAssertEqual(plan.status, "apply")
        let ack = VivaldiRequest(action: "ack", client: request.client, scope: request.scope, nodes: nodes, transaction: plan.transaction, created: [:])
        XCTAssertEqual(try sync.handle(ack).status, "complete")
        let imported = Date()
        XCTAssertEqual(store.data.entries.count, 3000)
        let previousSettings = try FileManager.default.attributesOfItem(atPath: config.path)[.modificationDate] as? Date
        for _ in 0..<3 { XCTAssertEqual(try sync.handle(request).status, "complete") }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: config.path)[.modificationDate] as? Date, previousSettings, "Unchanged polls should not rewrite settings")
        print("Large-library timing: import \(imported.timeIntervalSince(start))s; unchanged sync average \(Date().timeIntervalSince(imported) / 3)s")
    }
    func testSidebarAggregatesNestedCollectionsAndCountsEachTagOnce() {
        var data = LibraryData()
        let root = LibraryCollection(name: "Vivaldi"), other = LibraryCollection(name: "Other")
        let child = LibraryCollection(name: "Child", parentID: root.id)
        let grandchild = LibraryCollection(name: "Grandchild", parentID: child.id)
        data.collections = [root, child, grandchild, other]
        data.vivaldi = VivaldiBinding(connection: UUID(), scope: "test", root: root.id)
        data.entries = [
            LibraryEntry(name: "Root", location: "https://example.com", kind: .url, tags: ["Tag", "Tag"], collectionID: root.id, favorite: true),
            LibraryEntry(name: "Nested", location: "https://example.org", kind: .url, collectionID: grandchild.id),
            LibraryEntry(name: "Other", location: "/tmp/example", kind: .file, collectionID: other.id),
            LibraryEntry(name: "Unfiled", location: "https://example.net", kind: .url)
        ]
        let snapshot = LibrarySidebarSnapshot(data: data)
        XCTAssertEqual(snapshot.collections.map(\.id), [root.id, other.id])
        XCTAssertEqual(snapshot.vivaldiCollectionIDs, [root.id, child.id, grandchild.id])
        XCTAssertEqual(snapshot.collectionCounts[root.id], 2)
        XCTAssertEqual(snapshot.collectionCounts[other.id], 1)
        XCTAssertEqual(snapshot.kinds[.url], 3); XCTAssertEqual(snapshot.favorites, 1)
        XCTAssertEqual(snapshot.tags["Tag"], 1)
        data.vivaldi?.root = UUID()
        XCTAssertEqual(LibrarySidebarSnapshot(data: data).collections.count, 4)
        XCTAssertNil(LibrarySidebarSnapshot(data: data).vivaldiRoot)
    }

    func testDescendantsTerminatesWithCyclesAndMissingRoots() {
        var a = LibraryCollection(name: "A"), b = LibraryCollection(name: "B")
        a.parentID = b.id; b.parentID = a.id
        XCTAssertEqual(LibraryLogic.descendants(of: a.id, in: [a, b]), [a.id, b.id])
        let missing = UUID()
        XCTAssertEqual(LibraryLogic.descendants(of: missing, in: [a, b]), [missing])
    }

    func testLargeSidebarMatchesPreviousCounts() {
        var data = LibraryData()
        let root = LibraryCollection(name: "Vivaldi")
        data.collections = [root] + (0..<190).map { LibraryCollection(name: "Folder \($0)", parentID: root.id) }
        data.vivaldi = VivaldiBinding(connection: UUID(), scope: "test", root: root.id)
        data.entries = (0..<3000).map { LibraryEntry(name: "Bookmark \($0)", location: "https://example.com/\($0)", kind: .url, collectionID: data.collections[1 + $0 % 190].id) }
        let start = Date()
        let snapshot = LibrarySidebarSnapshot(data: data)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(snapshot.collectionCounts[root.id], 3000)
        XCTAssertEqual(snapshot.collections.count, 1)
        // Opt-in comparison with the old rendering algorithm; keep normal tests fast.
        if ProcessInfo.processInfo.environment["SWITCHBOARD_BENCHMARK"] == "1" {
            func previousDescendants() -> Set<UUID> {
                var result: Set<UUID> = [root.id], pending = [root.id]
                while let parent = pending.popLast() {
                    for child in data.collections where child.parentID == parent && result.insert(child.id).inserted { pending.append(child.id) }
                }
                return result
            }
            let before = Date()
            let previousCount = data.entries.filter { entry in entry.collectionID.map { previousDescendants().contains($0) } == true }.count
            XCTAssertEqual(previousCount, snapshot.collectionCounts[root.id])
            print("Sidebar timing: previous \(Date().timeIntervalSince(before))s; indexed \(elapsed)s")
        }
    }

}
