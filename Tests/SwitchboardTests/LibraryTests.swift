import XCTest
@testable import Switchboard

final class LibraryTests: XCTestCase {
    func testFlatHierarchyAndSearchScopes() {
        let parent = LibraryCollection(name: "Parent")
        let child = LibraryCollection(name: "Child", parentID: parent.id)
        let collections = [parent, child]
        let loose = LibraryEntry(name: "Loose", location: "/tmp/loose", kind: .folder)
        let direct = LibraryEntry(name: "Direct", location: "/tmp/direct", kind: .file, collectionID: parent.id)
        let nested = LibraryEntry(name: "Nested", location: "/tmp/nested", kind: .file, collectionID: child.id, favorite: true)
        let entries = [loose, direct, nested]
        func ids(_ scope: String, hierarchical: Bool, query: String = "") -> Set<UUID> {
            Set(LibraryLogic.scopedEntries(entries, collections: collections, scope: scope,
                                          hierarchical: hierarchical, query: query, sort: .name).map(\.id))
        }
        XCTAssertEqual(ids("all", hierarchical: false), [loose.id, direct.id, nested.id])
        XCTAssertEqual(ids("all", hierarchical: true), [loose.id])
        XCTAssertEqual(ids(parent.id.uuidString, hierarchical: false), [direct.id, nested.id])
        XCTAssertEqual(ids(parent.id.uuidString, hierarchical: true), [direct.id])
        XCTAssertEqual(ids(parent.id.uuidString, hierarchical: true, query: "nested"), [nested.id])
        XCTAssertEqual(ids("all", hierarchical: true, query: "nested"), [nested.id])
        XCTAssertEqual(ids("favorites", hierarchical: true), [nested.id])
        XCTAssertEqual(ids("folder", hierarchical: false), [loose.id])
    }

    func testLegacyCollectionsDecodeWithoutNewFields() throws {
        let id = UUID()
        let json = Data("{\"id\":\"\(id.uuidString)\",\"name\":\"Work\"}".utf8)
        let collection = try JSONDecoder().decode(LibraryCollection.self, from: json)
        XCTAssertEqual(collection.id, id)
        XCTAssertEqual(collection.symbol, "folder.fill")
        XCTAssertNil(collection.parentID)
        XCTAssertNil(collection.palette)
    }

    @MainActor func testNestedCollectionsPersistRejectCyclesAndReparentOnDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        let store = LibraryStore(storageURL: url)
        let root = store.addCollection("Work")
        let child = store.addCollection("Projects")
        let grandchild = store.addCollection("Current")
        store.updateCollection(LibraryCollection(id: child, name: "Projects", parentID: root, icon: "briefcase.fill", palette: .forest))
        store.updateCollection(LibraryCollection(id: grandchild, name: "Current", parentID: child))
        XCTAssertEqual(LibraryLogic.descendants(of: root, in: store.data.collections), [root, child, grandchild])
        XCTAssertEqual(LibraryLogic.collectionPath(store.data.collections[2], in: store.data.collections), "Work / Projects / Current")
        store.updateCollection(LibraryCollection(id: root, name: "Work", parentID: grandchild))
        XCTAssertNil(store.data.collections.first { $0.id == root }?.parentID)
        let item = try XCTUnwrap(store.addURL(name: "Example", location: "example.com", collectionID: child))
        let restored = LibraryStore(storageURL: url)
        XCTAssertEqual(restored.data.collections.first { $0.id == child }?.palette, .forest)
        XCTAssertEqual(restored.data.collections.first { $0.id == child }?.symbol, "briefcase.fill")
        restored.removeCollection(child)
        XCTAssertEqual(restored.data.collections.first { $0.id == grandchild }?.parentID, root)
        XCTAssertNil(restored.data.entries.first { $0.id == item }?.collectionID)
        XCTAssertEqual(LibraryStore(storageURL: url).data.entries.count, 1)
    }

    func testURLValidation() {
        XCTAssertEqual(LibraryLogic.webURL(" example.com/path ")?.absoluteString, "https://example.com/path")
        XCTAssertNil(LibraryLogic.webURL("javascript://alert(1)"))
        XCTAssertNil(LibraryLogic.webURL("file:///etc/passwd"))
        XCTAssertNil(LibraryLogic.webURL(""))
        XCTAssertNil(LibraryLogic.webURL("not a host"))
    }
    func testSearchAndSort() {
        let a = LibraryEntry(name: "Zebra", location: "/tmp/a", kind: .file, tags: ["design"])
        let b = LibraryEntry(name: "Alpha", location: "https://example.com", kind: .url, notes: "Reading list")
        XCTAssertEqual(LibraryLogic.filtered([a, b], query: "DESIGN", sort: .name).map(\.id), [a.id])
        XCTAssertEqual(LibraryLogic.filtered([a, b], query: "reading", sort: .name).map(\.id), [b.id])
        XCTAssertEqual(LibraryLogic.filtered([a, b], query: "", sort: .name).map(\.name), ["Alpha", "Zebra"])
    }
    @MainActor func testPersistenceDeduplicationAndSafeCollectionRemoval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        let store = LibraryStore(storageURL: url)
        let collection = store.addCollection("Work")
        let id = try XCTUnwrap(store.addURL(name: "Example", location: "example.com", collectionID: collection))
        _ = store.addURL(name: "Duplicate", location: "https://example.com", collectionID: nil)
        XCTAssertEqual(store.data.entries.count, 1)
        store.data.view = .largeCards
        store.configuration = ViewConfiguration(fields: [.notes], palette: .forest, fontName: "Menlo", fontSize: 18)
        let restored = LibraryStore(storageURL: url)
        XCTAssertEqual(restored.data.entries.first?.id, id)
        XCTAssertEqual(restored.configuration.palette, .forest)
        restored.removeCollection(collection)
        XCTAssertEqual(restored.data.entries.count, 1)
        XCTAssertNil(restored.data.entries.first?.collectionID)
        restored.remove([id])
        XCTAssertTrue(LibraryStore(storageURL: url).data.entries.isEmpty)
    }
    @MainActor func testUnreadableLibraryIsNeverOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("library.json")
        let original = Data("invalid json".utf8)
        try original.write(to: url)
        let store = LibraryStore(storageURL: url)
        XCTAssertNotNil(store.error)
        store.save()
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    @MainActor func testViewConfigurationsAreIndependent() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(storageURL: directory.appendingPathComponent("library.json"))
        store.configuration = ViewConfiguration(fields: [.notes], palette: .violet, fontName: "Menlo", fontSize: 20)
        store.data.view = .table
        XCTAssertEqual(store.configuration, ViewConfiguration())
        store.configuration = ViewConfiguration(fields: [.added], palette: .forest)
        store.data.view = .mediumCards
        XCTAssertEqual(store.configuration.fontSize, 20)
        XCTAssertEqual(store.configuration.fields, [.notes])
    }

}
