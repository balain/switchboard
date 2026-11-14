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
    func testFolderBoundaryAndDirectChildren() {
        let root = URL(fileURLWithPath: "/tmp/work")
        let entries = [
            LibraryEntry(name: "Root", location: "/tmp/work", kind: .folder),
            LibraryEntry(name: "Direct", location: "/tmp/work/a.txt", kind: .file),
            LibraryEntry(name: "Nested", location: "/tmp/work/sub/b.txt", kind: .file),
            LibraryEntry(name: "Sibling", location: "/tmp/work-other/a.txt", kind: .file),
            LibraryEntry(name: "Web", location: "https://example.com/tmp/work/a.txt", kind: .url)
        ]
        XCTAssertEqual(Set(EntryRemovalFilter(folder: root).matching(entries).map(\.name)), ["Direct", "Nested"])
        XCTAssertEqual(EntryRemovalFilter(folder: root, includeSubfolders: false).matching(entries).map(\.name), ["Direct"])
        XCTAssertTrue(EntryRemovalFilter(kind: .url, folder: root).matching(entries).isEmpty)
    }
    func testCollectionDescendantsUnfiledAndMissingReference() {
        let parent = LibraryCollection(name: "Parent")
        let child = LibraryCollection(name: "Child", parentID: parent.id)
        let entries = [
            LibraryEntry(name: "Parent entry", location: "/tmp/a", kind: .file, collectionID: parent.id),
            LibraryEntry(name: "Child entry", location: "/tmp/b", kind: .file, collectionID: child.id),
            LibraryEntry(name: "Unfiled", location: "/tmp/c", kind: .file)
        ]
        let collections = [parent, child]
        XCTAssertEqual(EntryRemovalFilter(collection: parent.id.uuidString).matching(entries, collections: collections).count, 2)
        XCTAssertEqual(EntryRemovalFilter(collection: parent.id.uuidString, includeSubcollections: false).matching(entries, collections: collections).map(\.id), [entries[0].id])
        XCTAssertEqual(EntryRemovalFilter(collection: "unfiled").matching(entries).map(\.id), [entries[2].id])
        XCTAssertTrue(EntryRemovalFilter(collection: parent.id.uuidString).matching(entries).isEmpty)
    }
    func testDateBoundsAcrossDaylightSavingAndCombinedFilters() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        let next = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
        let collection = LibraryCollection(name: "Work")
        let entries = [start.addingTimeInterval(-1), start, next.addingTimeInterval(-1), next].enumerated().map { index, date in
            LibraryEntry(name: "Report \(index)", location: "/tmp/work/\(index).txt", kind: .file, collectionID: collection.id, added: date)
        }
        var filter = EntryRemovalFilter(query: "report", kind: .file, dateMode: .range, startDate: start, endDate: start, folder: URL(fileURLWithPath: "/tmp/work"), collection: collection.id.uuidString)
        XCTAssertEqual(Set(filter.matching(entries, collections: [collection], calendar: calendar).map(\.id)), [entries[1].id, entries[2].id])
        filter.dateMode = .before
        XCTAssertEqual(filter.matching(entries, collections: [collection], calendar: calendar).map(\.id), [entries[0].id])
        filter.dateMode = .after
        XCTAssertEqual(filter.matching(entries, collections: [collection], calendar: calendar).count, 3)
        filter.dateMode = .range; filter.endDate = start.addingTimeInterval(-86400)
        XCTAssertTrue(filter.matching(entries, collections: [collection], calendar: calendar).isEmpty)
    }

}
