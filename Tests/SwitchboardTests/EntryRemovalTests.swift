import XCTest
@testable import Switchboard

final class EntryRemovalTests: XCTestCase {
    func testTextAndTypeFiltersAcrossTheLibrary() {
        let url = LibraryEntry(name: "Reference", location: "https://example.com/report", kind: .url, tags: ["Reading"])
        let file = LibraryEntry(name: "Report", location: "/tmp/report.txt", kind: .file, notes: "Quarterly")
        let folder = LibraryEntry(name: "Archive", location: "/tmp/archive", kind: .folder)
        let entries = [url, file, folder]
        XCTAssertEqual(Set(EntryRemovalFilter(query: "report").matching(entries).map(\.id)), [url.id, file.id])
        XCTAssertEqual(EntryRemovalFilter(query: "REPORT", kind: .url).matching(entries).map(\.id), [url.id])
        XCTAssertEqual(EntryRemovalFilter(query: "reading", kind: .url).matching(entries).map(\.id), [url.id])
        XCTAssertEqual(EntryRemovalFilter(query: "quarterly", kind: .file).matching(entries).map(\.id), [file.id])
        XCTAssertEqual(EntryRemovalFilter(kind: .folder).matching(entries).map(\.id), [folder.id])
        XCTAssertEqual(EntryRemovalFilter(kind: .url).matching(entries).map(\.id), [url.id])
        XCTAssertEqual(EntryRemovalFilter().matching(entries).count, 3)
    }

    @MainActor func testRemovalRejectsChangedEntriesAndUndoRestoresSelection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(storageURL: dir.appendingPathComponent("library.json"))
        let a = LibraryEntry(name: "A", location: "https://example.com/a", kind: .url, notes: "Preserve")
        let b = LibraryEntry(name: "B", location: "https://example.com/b", kind: .url)
        let file = LibraryEntry(name: "File", location: "/tmp/example", kind: .file)
        store.data.entries = [a, b, file]; XCTAssertTrue(store.save())
        store.data.entries[1].notes = "Changed"; XCTAssertTrue(store.save())
        XCTAssertEqual(store.removeReviewedEntries([a, b]), 0)
        XCTAssertEqual(store.data.entries.count, 3); XCTAssertNotNil(store.error)
        store.error = nil
        let before = store.data.entries
        XCTAssertEqual(store.removeReviewedEntries(Array(before.prefix(2))), 2)
        XCTAssertEqual(store.data.entries, [file])
        store.undoManager.undo()
        XCTAssertEqual(store.data.entries, before)
        XCTAssertEqual(LibraryStore(storageURL: dir.appendingPathComponent("library.json")).data.entries, before)
    }
}
