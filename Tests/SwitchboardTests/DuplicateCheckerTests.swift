import XCTest
@testable import Switchboard

final class DuplicateCheckerTests: XCTestCase {
    func testConservativeMatchingAndRecommendedSurvivor() throws {
        var synced = LibraryEntry(name: "Synced", location: "HTTPS://EXAMPLE.com:443", kind: .url)
        synced.added = Date(timeIntervalSince1970: 100)
        var annotated = LibraryEntry(name: "Annotated", location: "https://example.com/", kind: .url, notes: "Important", tags: ["Research"], favorite: true)
        annotated.added = Date(timeIntervalSince1970: 10)
        let differentQuery = LibraryEntry(name: "Query", location: "https://example.com/?a=1", kind: .url)
        let differentFragment = LibraryEntry(name: "Fragment", location: "https://example.com/#part", kind: .url)
        let file = LibraryEntry(name: "File", location: "/tmp/example/../item", kind: .file)
        let sameFile = LibraryEntry(name: "File copy", location: "/tmp/item", kind: .file)
        let folder = LibraryEntry(name: "Folder", location: "/tmp/item", kind: .folder)
        let groups = DuplicateChecker.groups(in: [synced, annotated, differentQuery, differentFragment, file, sameFile, folder], syncedIDs: [synced.id])
        XCTAssertEqual(groups.count, 2)
        let urlGroup = try XCTUnwrap(groups.first { $0.entries.contains(synced) })
        XCTAssertEqual(urlGroup.entries.first?.id, synced.id)
        XCTAssertTrue(DuplicateChecker.extraCopies(in: groups).contains(annotated.id))
        XCTAssertFalse(groups.flatMap(\.entries).contains(differentQuery))
        XCTAssertFalse(groups.flatMap(\.entries).contains(differentFragment))
        XCTAssertFalse(groups.flatMap(\.entries).contains(folder))
        XCTAssertEqual(DuplicateChecker.groups(in: [synced, annotated]).first?.entries.first?.id, annotated.id)
    }

    @MainActor func testRemovalIsAtomicAndUndoRestoresMetadata() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(storageURL: dir.appendingPathComponent("library.json"))
        let root = LibraryCollection(name: "Vivaldi")
        let synced = LibraryEntry(name: "Synced", location: "https://example.com", kind: .url, collectionID: root.id)
        let copy = LibraryEntry(name: "Copy", location: "https://example.com/", kind: .url, notes: "Notes", tags: ["Tag"], favorite: true)
        store.data.collections = [root]; store.data.tags = [LibraryTag(name: "Tag")]; store.data.entries = [synced, copy]
        let node = VivaldiNode(id: "10", title: synced.name, parent: nil, url: synced.location)
        let binding = VivaldiBinding(connection: UUID(), scope: "test", root: root.id, mapping: [node.id: synced.id], baseline: [node])
        store.data.vivaldi = binding
        XCTAssertTrue(store.save())
        let review = DuplicateChecker.groups(in: store.data.entries, syncedIDs: [synced.id])
        XCTAssertEqual(store.removeDuplicates([synced.id, copy.id], reviewed: review), 0)
        XCTAssertEqual(store.data.entries.count, 2)
        store.error = nil
        XCTAssertEqual(store.removeDuplicates([copy.id], reviewed: review), 1)
        XCTAssertEqual(store.data.entries.map(\.id), [synced.id])
        XCTAssertEqual(try VivaldiGraph.local(store.data, binding: binding), [node])
        store.undoManager.undo()
        XCTAssertEqual(store.data.entries, [synced, copy])
        XCTAssertEqual(LibraryStore(storageURL: dir.appendingPathComponent("library.json")).data.entries, [synced, copy])
    }

    @MainActor func testStaleReviewRejectsEntireRemoval() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(storageURL: dir.appendingPathComponent("library.json"))
        let a = LibraryEntry(name: "A", location: "https://example.com/", kind: .url)
        let b = LibraryEntry(name: "B", location: "https://example.com/", kind: .url)
        store.data.entries = [a, b]; XCTAssertTrue(store.save())
        let review = DuplicateChecker.groups(in: store.data.entries)
        store.data.entries[0].notes = "Changed after review"; XCTAssertTrue(store.save())
        XCTAssertEqual(store.removeDuplicates([b.id], reviewed: review), 0)
        XCTAssertEqual(store.data.entries.count, 2)
        XCTAssertNotNil(store.error)
        store.error = nil
        let newReview = DuplicateChecker.groups(in: store.data.entries)
        store.data.entries.append(LibraryEntry(name: "New", location: "https://example.com/", kind: .url))
        XCTAssertEqual(store.removeDuplicates([b.id], reviewed: newReview), 0)
        XCTAssertEqual(store.data.entries.count, 3)
    }
    @MainActor func testBulkRemovalAndUndoWithThousandsOfDuplicates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(storageURL: dir.appendingPathComponent("library.json"))
        store.data.entries = (0..<3000).flatMap { index in
            [LibraryEntry(name: "First \(index)", location: "https://example.com/\(index)", kind: .url),
             LibraryEntry(name: "Second \(index)", location: "https://example.com/\(index)", kind: .url)]
        }
        XCTAssertTrue(store.save())
        let original = store.data.entries
        let groups = DuplicateChecker.groups(in: original)
        XCTAssertEqual(groups.count, 3000)
        XCTAssertEqual(store.removeDuplicates(DuplicateChecker.extraCopies(in: groups), reviewed: groups), 3000)
        XCTAssertEqual(store.data.entries.count, 3000)
        store.undoManager.undo()
        XCTAssertEqual(store.data.entries, original)
    }

}
