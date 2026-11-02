import XCTest
@testable import Switchboard

final class LibraryTransferTests: XCTestCase {
    private func library() -> LibraryData {
        let parent = LibraryCollection(name: "Work & Study"), tag = LibraryTag(name: "Research", icon: "book.fill", palette: .forest)
        let child = LibraryCollection(name: "Nested", parentID: parent.id)
        var entry = LibraryEntry(name: "Café, \"notes\"", location: "https://example.com/a?x=1&y=2", kind: .url,
                                 notes: "First line, quoted \"text\"\nSecond & final", tags: [tag.name], collectionID: child.id, favorite: true)
        entry.bookmark = Data("private-bookmark".utf8)
        var saved = SavedFilter(name: "Saved"); saved.criteria.collectionID = child.id; saved.criteria.tagIDs = [tag.id]
        var data = LibraryData(); data.entries = [entry]; data.collections = [parent, child]; data.tags = [tag]; data.savedFilters = [saved]
        data.appearance = "dark"; data.view = .table
        return data
    }
    func testPortableRoundTripOmitsBookmarksAndPreferences() throws {
        let original = library(); let bytes = try LibraryTransfer.export(original, format: .json)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(object["appearance"]); XCTAssertNil(object["configurations"])
        let row = try XCTUnwrap((object["entries"] as? [[String: Any]])?.first); XCTAssertNil(row["bookmark"])
        let restored = try LibraryTransfer.parse(bytes, html: false)
        XCTAssertEqual(restored.entries[0].notes, original.entries[0].notes); XCTAssertNil(restored.entries[0].bookmark)
        XCTAssertEqual(restored.collections, original.collections); XCTAssertEqual(restored.tags, original.tags)
        XCTAssertEqual(restored.savedFilters, original.savedFilters); XCTAssertEqual(restored.appearance, "system")
    }
    func testHTMLRoundTripAndUntrustedMarkupAreDataOnly() throws {
        let original = library(); let bytes = try LibraryTransfer.export(original, format: .html)
        let parsed = try LibraryTransfer.parse(bytes, html: true)
        XCTAssertEqual(parsed.entries[0].name, original.entries[0].name)
        XCTAssertEqual(parsed.entries[0].notes, original.entries[0].notes)
        XCTAssertEqual(parsed.entries[0].tags, ["Research"]); XCTAssertTrue(parsed.entries[0].favorite)
        XCTAssertEqual(LibraryLogic.collectionPath(parsed.collections.last!, in: parsed.collections), "Work & Study / Nested")
        let hostile = Data("<script><A HREF='https://evil.invalid'>Hidden</A></script><DL><DT><A HREF='javascript:alert(1)'>Bad</A><DT><A HREF='https://example.com'>&#x3A9; &amp; safe</A></DL>".utf8)
        let safe = try LibraryTransfer.parse(hostile, html: true)
        XCTAssertEqual(safe.entries.count, 1); XCTAssertEqual(safe.entries[0].name, "Ω & safe")
        XCTAssertThrowsError(try LibraryTransfer.parse(Data("<html>no bookmarks".utf8), html: true))
    }
    func testCSVQuotesNotesAndFutureVersionsAndCyclesAreRejected() throws {
        let csv = String(decoding: try LibraryTransfer.export(library(), format: .csv), as: UTF8.self)
        XCTAssertTrue(csv.contains("\"\"notes\"\"")); XCTAssertTrue(csv.contains("\r\n")); XCTAssertTrue(csv.contains("\nSecond & final"))
        var portable = PortableLibrary(library()); portable.schemaVersion = 99
        XCTAssertThrowsError(try LibraryTransfer.parse(JSONEncoder().encode(portable), html: false))
        var invalid = library(); invalid.collections[0].parentID = invalid.collections[1].id
        XCTAssertThrowsError(try LibraryIntegrity.validate(invalid))
        invalid = library(); invalid.entries.append(invalid.entries[0]); XCTAssertThrowsError(try LibraryIntegrity.validate(invalid))
    }
    func testImportRemapsIDsPreservesReferencesAndReviewsDuplicates() throws {
        let incoming = library(); var existing = library()
        existing.collections = incoming.collections; existing.tags = incoming.tags; existing.entries = incoming.entries
        existing.savedFilters = incoming.savedFilters
        let skipped = try ImportPreview.prepare(incoming, into: existing, policy: .skip)
        XCTAssertEqual(skipped.added, 0); XCTAssertEqual(skipped.skipped, 1)
        let both = try ImportPreview.prepare(incoming, into: existing, policy: .keepBoth)
        XCTAssertEqual(both.added, 1); XCTAssertEqual(Set(both.candidate.entries.map(\.id)).count, 2)
        let copy = try XCTUnwrap(both.candidate.entries.last)
        XCTAssertNotEqual(copy.collectionID, incoming.entries[0].collectionID)
        XCTAssertEqual(both.candidate.savedFilters.last?.criteria.collectionID, copy.collectionID)
        XCTAssertEqual(both.candidate.savedFilters.last?.criteria.tagIDs, incoming.savedFilters[0].criteria.tagIDs)
        XCTAssertNil(copy.bookmark)
    }
    @MainActor func testDailyRetentionCheckpointRestoreAndStalePreviewProtection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let backups = LibraryBackups(directory: directory.appendingPathComponent("history"), clock: { now })
        let bytes = try JSONEncoder().encode(library())
        for _ in 0..<35 { _ = try backups.daily(bytes); now.addTimeInterval(86_400) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.directory.path).count, 30)
        let url = directory.appendingPathComponent("library.json")
        let store = LibraryStore(storageURL: url, backupDirectory: directory.appendingPathComponent("backups"), clock: { now })
        let id = try XCTUnwrap(store.addURL(name: "Original", location: "example.com", collectionID: nil))
        let backup = try XCTUnwrap(store.backupNow()); let snapshot = try Data(contentsOf: backup)
        store.applyBulk(.favorite(true), to: [id]); XCTAssertTrue(store.undoManager.canUndo)
        XCTAssertTrue(store.restoreLibrary(snapshot)); XCTAssertFalse(store.data.entries[0].favorite); XCTAssertFalse(store.undoManager.canUndo)
        let preview = try ImportPreview.prepare(library(), into: store.data, policy: .keepBoth)
        _ = store.addURL(name: "Later", location: "later.example.com", collectionID: nil)
        XCTAssertFalse(store.importLibrary(preview)); XCTAssertEqual(store.data.entries.count, 2)
    }
    @MainActor func testFailedBackupAndRestorePreserveCurrentFileAndRecoverUnreadableLibrary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("library.json"), blocked = directory.appendingPathComponent("blocked")
        try JSONEncoder().encode(LibraryData()).write(to: url); try Data("not a directory".utf8).write(to: blocked)
        let store = LibraryStore(storageURL: url, backupDirectory: blocked)
        let before = try Data(contentsOf: url)
        let preview = try ImportPreview.prepare(library(), into: store.data, policy: .keepBoth)
        XCTAssertFalse(store.importLibrary(preview)); XCTAssertEqual(try Data(contentsOf: url), before); XCTAssertTrue(store.data.entries.isEmpty)
        let corrupt = Data("unreadable original".utf8); try corrupt.write(to: url)
        let recovery = LibraryStore(storageURL: url)
        let snapshot = try JSONEncoder().encode(LibraryBackup(created: Date(), library: library()))
        XCTAssertTrue(recovery.restoreLibrary(snapshot)); XCTAssertNil(recovery.error)
        let files = try FileManager.default.contentsOfDirectory(at: recovery.backups.directory, includingPropertiesForKeys: nil)
        let preserved = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("unreadable-") })
        XCTAssertEqual(try Data(contentsOf: preserved), corrupt)
    }
    @MainActor func testImportRulesAreExplicitPreviewOnlyAndNeverRunDuringRestore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(storageURL: directory.appendingPathComponent("library.json"))
        _ = store.addURL(name: "Existing", location: "existing.example.com", collectionID: nil)
        let backup = try XCTUnwrap(store.backupNow()); var calls = 0
        store.importRuleProcessor = { candidate, ids in
            calls += 1
            for index in candidate.entries.indices where ids.contains(candidate.entries[index].id) { candidate.entries[index].favorite = true }
        }
        var incoming = LibraryData(); incoming.entries = [LibraryEntry(name: "Imported", location: "https://import.example.com", kind: .url)]
        let plain = try store.prepareImport(incoming, policy: .skip)
        XCTAssertFalse(plain.candidate.entries.last!.favorite); XCTAssertEqual(calls, 0)
        let reviewed = try store.prepareImport(incoming, policy: .skip, applyRules: true)
        XCTAssertTrue(reviewed.candidate.entries.last!.favorite); XCTAssertFalse(store.data.entries[0].favorite)
        XCTAssertEqual(calls, 1); XCTAssertTrue(store.importLibrary(reviewed)); XCTAssertEqual(calls, 1)
        XCTAssertTrue(store.restoreLibrary(try Data(contentsOf: backup))); XCTAssertEqual(calls, 1)
    }
    func testUnsafeURLsAndUnavailableSavedReferencesDoNotBindExistingTags() throws {
        var unsafe = LibraryData(); unsafe.entries = [LibraryEntry(name: "Unsafe", location: "javascript:alert(1)", kind: .url)]
        XCTAssertThrowsError(try PortableLibrary(unsafe).library())
        let tag = LibraryTag(name: "Existing"); var existing = LibraryData(); existing.tags = [tag]
        var incoming = LibraryData(); var filter = SavedFilter(name: "Missing reference"); filter.criteria.tagIDs = [tag.id]
        incoming.savedFilters = [filter]
        let preview = try ImportPreview.prepare(incoming, into: existing, policy: .skip)
        XCTAssertTrue(preview.candidate.savedFilters[0].criteria.unavailable(in: preview.candidate))
        XCTAssertNotEqual(preview.candidate.savedFilters[0].criteria.tagIDs, [tag.id])
    }
    @MainActor func testFailedRestoreLeavesFileMemoryAndUndoHistoryUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var failing = false
        let store = LibraryStore(storageURL: directory.appendingPathComponent("library.json")) { bytes, url in
            if failing { throw CocoaError(.fileWriteNoPermission) }; try bytes.write(to: url, options: .atomic)
        }
        let id = try XCTUnwrap(store.addURL(name: "Original", location: "example.com", collectionID: nil))
        let backup = try XCTUnwrap(store.backupNow()); store.applyBulk(.favorite(true), to: [id])
        let original = store.data.entries; let bytes = try Data(contentsOf: directory.appendingPathComponent("library.json"))
        failing = true; XCTAssertFalse(store.restoreLibrary(try Data(contentsOf: backup)))
        XCTAssertEqual(store.data.entries, original); XCTAssertTrue(store.undoManager.canUndo)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("library.json")), bytes)
    }

}
