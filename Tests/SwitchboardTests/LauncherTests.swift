import XCTest
import AppKit
@testable import Switchboard

@MainActor private final class FakeHotKey: LauncherHotKeyBackend {
    var registrations: [LauncherShortcut] = []
    var fail = false
    var action: (() -> Void)?
    var unregisterCount = 0
    func register(_ shortcut: LauncherShortcut, action: @escaping () -> Void) throws {
        if fail { throw LauncherHotKeyError.registration(-9878) }
        registrations.append(shortcut); self.action = action
    }
    func unregister() { unregisterCount += 1; action = nil }
}

final class LauncherTests: XCTestCase {
    func testRankingMetadataUnicodeAndLimits() {
        let entries = [
            LibraryEntry(name: "Other", location: "/tmp/other", kind: .file, notes: "alpha"),
            LibraryEntry(name: "An alpha item", location: "/tmp/a", kind: .file),
            LibraryEntry(name: "Alphabet", location: "/tmp/b", kind: .file),
            LibraryEntry(name: "Alpha", location: "/tmp/c", kind: .file),
            LibraryEntry(name: "Café", location: "/tmp/cafe", kind: .file)
        ]
        let search = LauncherSearch(entries: entries)
        XCTAssertEqual(search.results(query: "ALPHA").map(\.name), ["Alpha", "Alphabet", "An alpha item", "Other"])
        XCTAssertEqual(search.results(query: "cafe").first?.name, "Café")
        XCTAssertEqual(search.results(query: "alpha", limit: 2).count, 2)
        XCTAssertTrue(search.results(query: "alpha", limit: 0).isEmpty)
        XCTAssertEqual(search.results(query: "").count, entries.count)
        XCTAssertTrue(search.results(query: "unmatched").isEmpty)
    }
    func testTenThousandEntryQueryPerformance() {
        let entries = (0..<10_000).map { LibraryEntry(name: "Report \($0)", location: "/tmp/\($0)", kind: .file, tags: ["research"]) }
        let search = LauncherSearch(entries: entries)
        measure {
            XCTAssertEqual(search.results(query: "research").count, 50)
            XCTAssertEqual(search.results(query: "Report 9999").first?.name, "Report 9999")
        }
    }
    @MainActor func testShortcutPreferencesFailureFallbackAndCleanup() throws {
        let suite = UUID().uuidString; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(storageURL: dir.appendingPathComponent("library.json"))
        let backend = FakeHotKey(); let launcher = QuickLauncherCoordinator(store: store, defaults: defaults, hotKey: backend)
        launcher.start(); launcher.start(); XCTAssertEqual(backend.registrations.count, 1)
        launcher.shortcut.keyCode = 37
        XCTAssertEqual(backend.registrations.last?.keyCode, 37)
        let restored = QuickLauncherCoordinator(store: store, defaults: defaults, hotKey: FakeHotKey())
        XCTAssertEqual(restored.shortcut.keyCode, 37)
        backend.fail = true; launcher.shortcut.shift = true
        XCTAssertTrue(launcher.shortcutStatus.contains("could not be registered"))
        launcher.enabled = false; XCTAssertTrue(launcher.shortcutStatus.contains("disabled"))
        launcher.shutdown(); XCTAssertNil(backend.action)
    }
    @MainActor func testSelectionSurvivesRenameAndDoesNotJumpAfterDeletion() throws {
        let suite = UUID().uuidString; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(storageURL: dir.appendingPathComponent("library.json"))
        let a = try XCTUnwrap(store.addURL(name: "A", location: "a.example.com", collectionID: nil))
        let b = try XCTUnwrap(store.addURL(name: "B", location: "b.example.com", collectionID: nil))
        let launcher = QuickLauncherCoordinator(store: store, defaults: defaults, hotKey: FakeHotKey())
        launcher.query = ""; launcher.selectedID = a
        var updated = store.data.entries[0]; updated.name = "Z"; store.update(updated)
        XCTAssertEqual(launcher.selectedID, a)
        store.remove([a]); XCTAssertNil(launcher.selectedID)
        launcher.move(1); XCTAssertEqual(launcher.selectedID, b)
        store.remove([b]); launcher.open(); XCTAssertNotNil(launcher.message)
    }
    @MainActor func testRevealRequestsWindowWhenNoneIsOpen() throws {
        let suite = UUID().uuidString; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(storageURL: dir.appendingPathComponent("library.json"))
        let id = try XCTUnwrap(store.addURL(name: "A", location: "a.example.com", collectionID: nil))
        let launcher = QuickLauncherCoordinator(store: store, defaults: defaults, hotKey: FakeHotKey())
        var requested = 0; launcher.openLibrary = { requested += 1 }
        launcher.selectedID = id; launcher.showInSwitchboard(); XCTAssertEqual(requested, 1)
    }
    @MainActor func testRevealSelectionSurvivesProgrammaticFilterResetButNotUserFilters() throws {
        let suite = UUID().uuidString; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = LibraryWindowState(defaults: defaults)
        let entry = LibraryEntry(name: "Inside", location: "/tmp/a", kind: .file, collectionID: UUID())
        state.query = "unrelated"; state.selectedTags = [UUID()]
        state.reveal(entry); state.clearSelectionForFilterChange()
        XCTAssertEqual(state.scope, entry.collectionID?.uuidString)
        XCTAssertEqual(state.selection, [entry.id]); XCTAssertTrue(state.query.isEmpty); XCTAssertTrue(state.selectedTags.isEmpty)
        state.scope = "favorites"; state.clearSelectionForFilterChange(); XCTAssertTrue(state.selection.isEmpty)
    }
    func testPanelFitsScreensWithNegativeOrigins() {
        for bounds in [CGRect(x: -1920, y: 0, width: 1920, height: 1080), CGRect(x: 0, y: -800, width: 320, height: 240)] {
            let frame = QuickLauncherCoordinator.panelFrame(in: bounds)
            XCTAssertTrue(bounds.contains(frame))
        }
        XCTAssertFalse(LauncherShortcut(keyCode: 49, control: false, option: true).valid)
        XCTAssertFalse(LauncherShortcut(keyCode: 999).valid)
    }
}
