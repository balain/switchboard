import XCTest
@testable import Switchboard

@MainActor private final class IntegrationHotKey: LauncherHotKeyBackend {
    func register(_ shortcut: LauncherShortcut, action: @escaping () -> Void) throws { }
    func unregister() { }
}

final class FeatureIntegrationTests: XCTestCase {
    @MainActor func testBulkUndoUpdatesSmartCollectionsAndLauncherTogether() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let url = directory.appendingPathComponent("library.json")
        let store = LibraryStore(storageURL: url)
        let a = try XCTUnwrap(store.addURL(name: "First", location: "first.example.com", collectionID: nil))
        let b = try XCTUnwrap(store.addURL(name: "Second", location: "second.example.com", collectionID: nil))
        let tag = try XCTUnwrap(store.addTag("Research"))
        var saved = SavedFilter(name: "Research entries"); saved.criteria.tagIDs = [tag]
        XCTAssertTrue(store.putSavedFilter(saved))
        let launcher = QuickLauncherCoordinator(store: store, defaults: defaults, hotKey: IntegrationHotKey())
        launcher.query = "Research"
        func matches() -> Int { store.data.entries.filter { saved.criteria.matches($0, in: store.data) }.count }
        XCTAssertEqual(matches(), 0); XCTAssertTrue(launcher.results.isEmpty)
        XCTAssertEqual(store.applyBulk(.addTag(tag), to: [a, b]), 2)
        XCTAssertEqual(matches(), 2); XCTAssertEqual(launcher.results.count, 2)
        store.undoManager.undo()
        XCTAssertEqual(matches(), 0); XCTAssertTrue(launcher.results.isEmpty)
        store.undoManager.redo()
        XCTAssertEqual(matches(), 2); XCTAssertEqual(launcher.results.count, 2)
        let restored = LibraryStore(storageURL: url)
        XCTAssertEqual(restored.data.savedFilters, [saved])
        XCTAssertEqual(restored.data.entries.filter { saved.criteria.matches($0, in: restored.data) }.count, 2)
    }

    @MainActor func testFailedSmartSavePreservesBulkHistoryAndPersistedFilters() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var failing = false
        let store = LibraryStore(storageURL: directory.appendingPathComponent("library.json")) { bytes, url in
            if failing { throw CocoaError(.fileWriteNoPermission) }
            try bytes.write(to: url, options: .atomic)
        }
        let id = try XCTUnwrap(store.addURL(name: "First", location: "example.com", collectionID: nil))
        let saved = SavedFilter(name: "Existing")
        XCTAssertTrue(store.putSavedFilter(saved))
        store.applyBulk(.favorite(true), to: [id])
        failing = true
        XCTAssertFalse(store.putSavedFilter(SavedFilter(name: "Must not publish")))
        XCTAssertEqual(store.data.savedFilters, [saved]); XCTAssertTrue(store.undoManager.canUndo)
        failing = false; store.undoManager.undo()
        XCTAssertFalse(store.data.entries[0].favorite)
        XCTAssertEqual(LibraryStore(storageURL: directory.appendingPathComponent("library.json")).data.savedFilters, [saved])
    }

    @MainActor func testLauncherRevealLeavesSmartScopeAndPreservesSelection() throws {
        let suite = UUID().uuidString; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var data = LibraryData()
        let collection = LibraryCollection(name: "Physical")
        let entry = LibraryEntry(name: "Entry", location: "/tmp/integration", kind: .file, collectionID: collection.id)
        let saved = SavedFilter(name: "Smart")
        data.entries = [entry]; data.collections = [collection]; data.savedFilters = [saved]
        let state = LibraryWindowState(defaults: defaults)
        state.scope = saved.scope; state.query = "excludes entry"; state.selectedTags = [UUID()]
        state.reveal(entry); state.clearSelectionForFilterChange(); state.validate(in: data)
        XCTAssertEqual(state.scope, collection.id.uuidString)
        XCTAssertEqual(state.selection, [entry.id]); XCTAssertTrue(state.query.isEmpty); XCTAssertTrue(state.selectedTags.isEmpty)
        XCTAssertNil(SavedFilter.id(in: state.scope))
    }

    @MainActor func testDeletingTagKeepsSmartCriteriaUnavailableThroughUnrelatedUndo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(storageURL: directory.appendingPathComponent("library.json"))
        let id = try XCTUnwrap(store.addURL(name: "First", location: "example.com", collectionID: nil))
        let tag = try XCTUnwrap(store.addTag("Research"))
        store.applyBulk(.addTag(tag), to: [id]); store.undoManager.removeAllActions()
        var saved = SavedFilter(name: "Research"); saved.criteria.tagIDs = [tag]
        XCTAssertTrue(store.putSavedFilter(saved))
        store.applyBulk(.favorite(true), to: [id]); store.removeTag(tag); store.undoManager.undo()
        XCTAssertFalse(store.data.entries[0].favorite)
        XCTAssertEqual(store.data.savedFilters.first?.criteria.tagIDs, [tag])
        XCTAssertTrue(saved.criteria.unavailable(in: store.data))
        XCTAssertFalse(saved.criteria.matches(store.data.entries[0], in: store.data))
    }
}
