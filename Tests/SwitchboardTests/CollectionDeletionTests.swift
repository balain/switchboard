import XCTest
@testable import Switchboard

final class CollectionDeletionTests: XCTestCase {
    @MainActor func testDeletingOnlyCollectionReparentsChildrenAndKeepsTheirEntriesAssigned() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json"), store = LibraryStore(storageURL: directory.appendingPathComponent("library.json"))
        let parent = store.addCollection("Parent"), branch = store.addCollection("Branch"), child = store.addCollection("Child"), leaf = store.addCollection("Leaf")
        store.updateCollection(LibraryCollection(id: branch, name: "Branch", parentID: parent))
        store.updateCollection(LibraryCollection(id: child, name: "Child", parentID: branch))
        store.updateCollection(LibraryCollection(id: leaf, name: "Leaf", parentID: child))
        let direct = try XCTUnwrap(store.addURL(name: "Direct", location: "https://example.com/direct", collectionID: branch))
        let nested = try XCTUnwrap(store.addURL(name: "Nested", location: "https://example.com/nested", collectionID: leaf))
        XCTAssertTrue(store.removeCollection(branch))
        let restored = LibraryStore(storageURL: url)
        XCTAssertEqual(Set(restored.data.collections.map(\.id)), [parent, child, leaf])
        XCTAssertEqual(restored.data.collections.first { $0.id == child }?.parentID, parent)
        XCTAssertEqual(restored.data.collections.first { $0.id == leaf }?.parentID, child)
        XCTAssertNil(restored.data.entries.first { $0.id == direct }?.collectionID)
        XCTAssertEqual(restored.data.entries.first { $0.id == nested }?.collectionID, leaf)
    }
    @MainActor func testDeletingHierarchyRemovesEveryDescendantAndPreservesAllEntriesAndMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json"), store = LibraryStore(storageURL: directory.appendingPathComponent("library.json"))
        let root = store.addCollection("Root"), branch = store.addCollection("Branch"), child = store.addCollection("Child"), leaf = store.addCollection("Leaf"), sibling = store.addCollection("Sibling")
        store.updateCollection(LibraryCollection(id: branch, name: "Branch", parentID: root))
        store.updateCollection(LibraryCollection(id: child, name: "Child", parentID: branch))
        store.updateCollection(LibraryCollection(id: leaf, name: "Leaf", parentID: child))
        store.updateCollection(LibraryCollection(id: sibling, name: "Sibling", parentID: root))
        for (index, collection) in [branch, child, leaf, sibling].enumerated() {
            _ = store.addURL(name: "Entry \(index)", location: "https://example.com/\(index)", collectionID: collection)
        }
        var entry = store.data.entries[0]; entry.notes = "Keep this note"; entry.favorite = true; entry.tags = ["Research"]; store.update(entry)
        let before = store.data.entries
        var rule = OrganizationRule(name: "Uses removed collection"); rule.enabled = true; rule.actions = [.collection(leaf)]
        XCTAssertTrue(store.putRule(rule))
        XCTAssertTrue(store.removeCollection(branch, includingSubcollections: true))
        let restored = LibraryStore(storageURL: url)
        XCTAssertEqual(Set(restored.data.collections.map(\.id)), [root, sibling])
        XCTAssertEqual(restored.data.entries, before.map { item in var copy = item; if item.collectionID != sibling { copy.collectionID = nil }; return copy })
        XCTAssertEqual(restored.data.collections.first { $0.id == sibling }?.parentID, root)
        XCTAssertFalse(restored.data.rules[0].enabled)
        try LibraryIntegrity.validate(restored.data)
    }
    @MainActor func testFailedHierarchyDeletionLeavesDiskAndMemoryUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        var fail = false
        let store = LibraryStore(storageURL: url) { bytes, destination in
            if fail { throw CocoaError(.fileWriteNoPermission) }; try bytes.write(to: destination, options: .atomic)
        }
        let root = store.addCollection("Root"), child = store.addCollection("Child")
        store.updateCollection(LibraryCollection(id: child, name: "Child", parentID: root))
        _ = store.addURL(name: "Entry", location: "https://example.com", collectionID: child)
        let collections = store.data.collections, entries = store.data.entries, bytes = try Data(contentsOf: url)
        fail = true
        XCTAssertFalse(store.removeCollection(root, includingSubcollections: true))
        XCTAssertEqual(store.data.collections, collections); XCTAssertEqual(store.data.entries, entries)
        XCTAssertEqual(try Data(contentsOf: url), bytes); XCTAssertNotNil(store.error)
        XCTAssertFalse(store.removeCollection(UUID(), includingSubcollections: true))
    }
}
