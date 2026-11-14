import XCTest
@testable import Switchboard

final class EntryOrganizationTests: XCTestCase {
    @MainActor func testDropMovesSelectionAndUndoRestoresCollections() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(storageURL: directory.appendingPathComponent("library.json"))
        let first = try XCTUnwrap(store.addURL(name: "One", location: "https://one.example", collectionID: nil))
        let second = try XCTUnwrap(store.addURL(name: "Two", location: "https://two.example", collectionID: nil))
        let collection = LibraryCollection(name: "Reading")
        store.data.collections.append(collection); store.save(); store.undoManager.removeAllActions()
        XCTAssertTrue(store.organizeDrop([EntryDrag(ids: [first, second])], action: .collection(collection.id)))
        XCTAssertTrue(store.data.entries.allSatisfy { $0.collectionID == collection.id })
        store.undoManager.undo()
        XCTAssertTrue(store.data.entries.allSatisfy { $0.collectionID == nil })
        XCTAssertFalse(store.undoManager.canUndo)
        XCTAssertFalse(store.organizeDrop([EntryDrag(ids: [first, UUID()])], action: .collection(collection.id)))
        XCTAssertTrue(store.data.entries.allSatisfy { $0.collectionID == nil })
        XCTAssertFalse(store.organizeDrop([EntryDrag(ids: [first])], action: .collection(UUID())))
    }
    @MainActor func testTagDropPreservesExistingTagsAndRejectsMissingTag() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(storageURL: directory.appendingPathComponent("library.json"))
        let id = try XCTUnwrap(store.addURL(name: "One", location: "https://one.example", collectionID: nil))
        let first = try XCTUnwrap(store.addTag("Existing")), second = try XCTUnwrap(store.addTag("New"))
        store.applyBulk(.addTag(first), to: [id]); store.undoManager.removeAllActions()
        XCTAssertTrue(store.organizeDrop([EntryDrag(ids: [id])], action: .addTag(second)))
        XCTAssertEqual(Set(store.data.entries[0].tags), ["Existing", "New"])
        store.undoManager.undo()
        XCTAssertEqual(store.data.entries[0].tags, ["Existing"])
        XCTAssertFalse(store.organizeDrop([EntryDrag(ids: [id])], action: .addTag(UUID())))
    }
}
