import XCTest
@testable import Switchboard

final class SmartCollectionTests: XCTestCase {
    func testConditionsCombineAndReferencesFailClosed() {
        let root = LibraryCollection(name: "Work")
        let child = LibraryCollection(name: "Child", parentID: root.id)
        let tag = LibraryTag(name: "Reading")
        var data = LibraryData(); data.collections = [root, child]; data.tags = [tag]
        let entry = LibraryEntry(name: "Alpha", location: "/tmp/report.PDF", kind: .file, tags: ["reading"], collectionID: child.id, favorite: true)
        var p = EntryPredicate(); p.queries = ["alpha", "report"]; p.kind = .file; p.fileExtension = ".pdf"
        p.favorite = true; p.collectionID = root.id; p.tagIDs = [tag.id]
        XCTAssertTrue(p.matches(entry, in: data))
        p.queries.append("missing"); XCTAssertFalse(p.matches(entry, in: data)); p.queries.removeLast()
        data.tags = []; XCTAssertTrue(p.unavailable(in: data)); XCTAssertFalse(p.matches(entry, in: data))
        data.tags = [tag]; data.collections = []; XCTAssertFalse(p.matches(entry, in: data))
    }
    func testRelativeDatesUseCalendarDaysAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let parser = ISO8601DateFormatter()
        let now = try XCTUnwrap(parser.date(from: "2026-11-01T17:00:00Z"))
        var entry = LibraryEntry(name: "Today", location: "/tmp/a", kind: .file)
        var p = EntryPredicate(); p.added = .today
        entry.added = try XCTUnwrap(parser.date(from: "2026-11-02T04:59:59Z"))
        XCTAssertTrue(p.matches(entry, in: LibraryData(), now: now, calendar: calendar))
        entry.added = try XCTUnwrap(parser.date(from: "2026-11-02T05:00:00Z"))
        XCTAssertFalse(p.matches(entry, in: LibraryData(), now: now, calendar: calendar))
        p.added = .lastSevenDays
        entry.added = try XCTUnwrap(parser.date(from: "2026-10-26T04:00:00Z"))
        XCTAssertTrue(p.matches(entry, in: LibraryData(), now: now, calendar: calendar))
        p.added = .range; p.startDate = now; p.endDate = now
        entry.added = now; XCTAssertTrue(p.matches(entry, in: LibraryData(), calendar: calendar))
    }
    @MainActor func testPersistenceLegacyCheckpointAndSafeDeletion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("library.json")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LibraryData())) as? [String: Any])
        legacy.removeValue(forKey: "savedFilters")
        let original = try JSONSerialization.data(withJSONObject: legacy); try original.write(to: url)
        let store = LibraryStore(storageURL: url)
        XCTAssertTrue(store.data.savedFilters.isEmpty)
        let entry = try XCTUnwrap(store.addURL(name: "Example", location: "example.com", collectionID: nil))
        let filter = SavedFilter(name: "Reading")
        XCTAssertTrue(store.putSavedFilter(filter))
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("before-smart-collections")), original)
        XCTAssertFalse(store.putSavedFilter(SavedFilter(name: " reading ")))
        let restored = LibraryStore(storageURL: url)
        XCTAssertEqual(restored.data.savedFilters, [filter]); restored.removeSavedFilter(filter.id)
        XCTAssertEqual(restored.data.entries.first?.id, entry)
        XCTAssertTrue(LibraryStore(storageURL: url).data.savedFilters.isEmpty)
    }
    @MainActor func testFailedWritesDoNotPublishCandidates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(storageURL: dir.appendingPathComponent("library.json"))
        try Data("block directory creation".utf8).write(to: dir)
        XCTAssertFalse(store.putSavedFilter(SavedFilter(name: "Test")))
        XCTAssertTrue(store.data.savedFilters.isEmpty); XCTAssertNotNil(store.error)
    }
    @MainActor func testSnapshotKeepsANDConditionsAndSmartScopeRestores() throws {
        let suite = UUID().uuidString; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = LibraryTag(name: "A"), b = LibraryTag(name: "B")
        var saved = SavedFilter(name: "Base"); saved.criteria.queries = ["alpha"]; saved.criteria.tagIDs = [a.id]
        var data = LibraryData(); data.savedFilters = [saved]; data.tags = [a, b]
        let state = LibraryWindowState(defaults: defaults); state.scope = saved.scope; state.query = "report"; state.selectedTags = [b.id]
        let copy = state.currentFilter(in: data)
        let entry = LibraryEntry(name: "Alpha report", location: "/tmp/a", kind: .file, tags: ["A", "B"])
        XCTAssertTrue(copy.criteria.matches(entry, in: data))
        var other = entry; other.tags = ["B"]; XCTAssertFalse(copy.criteria.matches(other, in: data))
        XCTAssertNil(UUID(uuidString: state.scope))
        let restored = LibraryWindowState(defaults: defaults); restored.validate(in: data); XCTAssertEqual(restored.scope, saved.scope)
        data.savedFilters = []; restored.validate(in: data); XCTAssertEqual(restored.scope, "all")
    }
}
