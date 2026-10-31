import XCTest
import SwiftUI
@testable import Switchboard

final class ViewStateTests: XCTestCase {
    @MainActor func testActiveViewStateRestoresInNewWindowState() throws {
        let suite = "SwitchboardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let collection = UUID()
        let entry = UUID()
        let state = LibraryWindowState(defaults: defaults)
        state.scope = collection.uuidString
        state.query = "reading"
        state.showInspector = false
        state.columnVisibility = .detailOnly
        state.selection = [entry]
        state.showURL = true
        state.showCollections = true
        state.showSettings = true
        state.searchPresented = true
        let restored = LibraryWindowState(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(restored.scope, collection.uuidString)
        XCTAssertEqual(restored.query, "reading")
        XCTAssertFalse(restored.showInspector)
        XCTAssertEqual(restored.columnVisibility, .detailOnly)
        XCTAssertEqual(restored.selection, [entry])
        XCTAssertFalse(restored.showURL)
        XCTAssertFalse(restored.showCollections)
        XCTAssertFalse(restored.showSettings)
        XCTAssertFalse(restored.searchPresented)
    }

    @MainActor func testMissingPreferencesUseOriginalDefaults() throws {
        let suite = "SwitchboardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = LibraryWindowState(defaults: defaults)
        XCTAssertEqual(state.scope, "all")
        XCTAssertEqual(state.query, "")
        XCTAssertTrue(state.showInspector)
        XCTAssertEqual(state.columnVisibility, .automatic)
        XCTAssertTrue(state.selection.isEmpty)
    }

    @MainActor func testRestoredStateDiscardsDeletedCollectionsAndEntries() throws {
        let suite = "SwitchboardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = LibraryWindowState(defaults: defaults)
        let collection = LibraryCollection(name: "Work")
        let entry = LibraryEntry(name: "Notes", location: "/tmp/notes.txt", kind: .file)
        var data = LibraryData()
        data.collections = [collection]
        data.entries = [entry]
        state.scope = collection.id.uuidString
        state.selection = [entry.id, UUID()]
        state.validate(in: data)
        XCTAssertEqual(state.scope, collection.id.uuidString)
        XCTAssertEqual(state.selection, [entry.id])
        data.collections = []
        data.entries = []
        state.validate(in: data)
        let restored = LibraryWindowState(defaults: defaults)
        XCTAssertEqual(restored.scope, "all")
        XCTAssertTrue(restored.selection.isEmpty)
        state.scope = "favorites"
        state.validate(in: data)
        XCTAssertEqual(state.scope, "favorites")
    }
}
