import XCTest
@testable import Switchboard

final class BulkOrganizationTests: XCTestCase {
    @MainActor private func fixture(writer: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws -> (LibraryStore, URL, UUID, UUID, UUID) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(storageURL: dir.appendingPathComponent("library.json"), writer: writer)
        let a = try XCTUnwrap(store.addURL(name: "A", location: "a.example.com", collectionID: nil))
        let b = try XCTUnwrap(store.addURL(name: "B", location: "b.example.com", collectionID: nil))
        let tag = try XCTUnwrap(store.addTag("Reading"))
        return (store, dir, a, b, tag)
    }
    @MainActor func testBulkTagsPreserveOtherTagsAndUndoAsOneGroup() throws {
        let (store, dir, a, b, tag) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        var entry = store.data.entries[0]; entry.tags = ["Other"]; store.update(entry)
        store.undoManager.removeAllActions()
        XCTAssertEqual(store.applyBulk(.addTag(tag), to: [a, b, UUID()]), 2)
        XCTAssertEqual(store.data.entries[0].tags, ["Other", "Reading"])
        XCTAssertEqual(store.data.entries[1].tags, ["Reading"])
        store.undoManager.undo()
        XCTAssertEqual(store.data.entries[0].tags, ["Other"]); XCTAssertEqual(store.data.entries[1].tags, [])
        XCTAssertFalse(store.undoManager.canUndo); XCTAssertTrue(store.undoManager.canRedo)
        store.undoManager.redo()
        XCTAssertEqual(LibraryStore(storageURL: dir.appendingPathComponent("library.json")).data.entries[1].tags, ["Reading"])
        XCTAssertEqual(store.applyBulk(.removeTag(tag), to: [a, b]), 2)
        XCTAssertEqual(store.data.entries[0].tags, ["Other"])
    }
    @MainActor func testUndoPreservesUnrelatedEditsAndDetectsConflicts() throws {
        let (store, dir, a, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        store.applyBulk(.favorite(true), to: [a])
        store.data.entries[0].notes = "Later unrelated note"; store.save()
        store.undoManager.undo()
        XCTAssertFalse(store.data.entries[0].favorite); XCTAssertEqual(store.data.entries[0].notes, "Later unrelated note")
        store.undoManager.redo(); store.data.entries[0].favorite = false; store.save()
        store.undoManager.undo()
        XCTAssertFalse(store.data.entries[0].favorite); XCTAssertNotNil(store.error); XCTAssertFalse(store.undoManager.canUndo)
    }
    @MainActor func testRemovalUndoRestoresOrderAndMetadata() throws {
        let (store, dir, a, b, _) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let original = store.data.entries
        XCTAssertEqual(store.remove([a, b]), 2); XCTAssertTrue(store.data.entries.isEmpty)
        store.undoManager.undo(); XCTAssertEqual(store.data.entries, original)
        store.undoManager.redo(); XCTAssertTrue(store.data.entries.isEmpty)
    }
    @MainActor func testFailedTransactionDoesNotPublishOrRegisterUndo() throws {
        var fail = false
        let (store, dir, a, b, _) = try fixture { bytes, url in
            if fail { throw CocoaError(.fileWriteNoPermission) }
            try bytes.write(to: url, options: .atomic)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = store.data.entries; let url = dir.appendingPathComponent("library.json"); let bytes = try Data(contentsOf: url)
        fail = true
        XCTAssertEqual(store.applyBulk(.favorite(true), to: [a, b]), 0)
        XCTAssertEqual(store.data.entries, old); XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertFalse(store.undoManager.canUndo)
        var edited = old[0]; edited.name = "Failed"; store.update(edited)
        XCTAssertEqual(store.data.entries, old); XCTAssertFalse(store.undoManager.canUndo)
    }
    @MainActor func testFailedUndoKeepsPersistedStateAndClearsHistorySafely() throws {
        var fail = false
        let (store, dir, a, _, _) = try fixture { bytes, url in
            if fail { throw CocoaError(.fileWriteNoPermission) }
            try bytes.write(to: url, options: .atomic)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        store.applyBulk(.favorite(true), to: [a])
        let bytes = try Data(contentsOf: dir.appendingPathComponent("library.json"))
        fail = true; store.undoManager.undo()
        XCTAssertTrue(store.data.entries[0].favorite)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("library.json")), bytes)
        XCTAssertFalse(store.undoManager.canUndo); XCTAssertFalse(store.undoManager.canRedo)
        XCTAssertTrue(store.error?.contains("history was cleared") == true)
    }
    @MainActor func testMissingTargetsAndNoopsDoNotChangeHistory() throws {
        let (store, dir, a, b, _) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(store.applyBulk(.collection(UUID()), to: [a, b]), 0)
        XCTAssertEqual(store.applyBulk(.addTag(UUID()), to: [a]), 0)
        XCTAssertEqual(store.applyBulk(.favorite(false), to: [a, b]), 0)
        XCTAssertFalse(store.undoManager.canUndo)
        let collection = store.addCollection("Work")
        XCTAssertEqual(store.applyBulk(.collection(collection), to: [a, b]), 2)
        store.undoManager.undo(); XCTAssertTrue(store.data.entries.allSatisfy { $0.collectionID == nil })
    }
    @MainActor func testDeletedReferencesCannotBeResurrectedByUndo() throws {
        let (store, dir, a, _, tag) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        store.applyBulk(.addTag(tag), to: [a]); store.undoManager.removeAllActions()
        store.applyBulk(.removeTag(tag), to: [a]); store.removeTag(tag)
        store.undoManager.undo()
        XCTAssertTrue(store.data.entries[0].tags.isEmpty); XCTAssertNotNil(store.error)
        XCTAssertFalse(store.undoManager.canRedo)
    }
    @MainActor func testGlobalHistoryHandlesInterleavedSelections() throws {
        let (store, dir, a, b, _) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        store.applyBulk(.favorite(true), to: [a]); store.applyBulk(.favorite(true), to: [b])
        store.undoManager.undo()
        XCTAssertTrue(store.data.entries[0].favorite); XCTAssertFalse(store.data.entries[1].favorite)
        store.undoManager.undo(); XCTAssertTrue(store.data.entries.allSatisfy { !$0.favorite })
        store.undoManager.redo(); store.undoManager.redo(); XCTAssertTrue(store.data.entries.allSatisfy(\.favorite))
    }
    @MainActor func testSelectionRemovalRequestsAndGuards() throws {
        let (store, dir, a, b, _) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = try XCTUnwrap(store.addURL(name: "C", location: "c.example.com", collectionID: nil))
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = LibraryWindowState(defaults: defaults)

        XCTAssertFalse(window.canRemoveSelection(in: store.data))
        XCTAssertFalse(window.requestRemoveSelection(in: store.data))
        XCTAssertTrue(window.removeSelection.isEmpty)

        let missing = UUID()
        window.selection = [a, b, missing]
        XCTAssertFalse(window.canRemoveSelection(in: store.data, editingText: true))
        XCTAssertFalse(window.requestRemoveSelection(in: store.data, editingText: true))
        XCTAssertFalse(window.canRemoveSelection(in: store.data, hasExternalModal: true))
        XCTAssertFalse(window.requestRemoveSelection(in: store.data, hasExternalModal: true))

        store.error = "Disk error"
        XCTAssertFalse(window.canRemoveSelection(in: store.data, hasExternalModal: store.error != nil))
        store.error = nil

        window.showURL = true
        XCTAssertFalse(window.canRemoveSelection(in: store.data))
        XCTAssertFalse(window.requestRemoveSelection(in: store.data))
        window.showURL = false

        XCTAssertTrue(window.canRemoveSelection(in: store.data))
        XCTAssertTrue(window.requestRemoveSelection(in: store.data))
        XCTAssertEqual(window.removeSelection, [a, b])
        XCTAssertFalse(window.canRemoveSelection(in: store.data))

        XCTAssertEqual(store.remove(window.removeSelection), 2)
        window.removeSelection = []
        window.validate(in: store.data)
        XCTAssertEqual(store.data.entries.map(\.id), [c])
        XCTAssertTrue(window.selection.isEmpty)

        store.undoManager.undo()
        XCTAssertEqual(store.data.entries.count, 3)
    }

    @MainActor func testCommandResponderStateTracksTextFocusAndSheets() {
        _ = NSApplication.shared
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 180, height: 24))
        parent.contentView?.addSubview(field)
        let responder = CommandResponderState()

        responder.bind(keyWindow: parent, mainWindow: parent)
        XCTAssertFalse(responder.editingText)
        XCTAssertFalse(responder.hasModalSheet)

        parent.makeFirstResponder(field)
        XCTAssertTrue(responder.editingText)

        parent.makeFirstResponder(parent)
        XCTAssertFalse(responder.editingText)

        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        parent.beginSheet(sheet)
        defer { parent.endSheet(sheet) }

        responder.bind(keyWindow: sheet, mainWindow: parent)
        XCTAssertTrue(responder.hasModalSheet)

        responder.bind(keyWindow: parent, mainWindow: parent)
        XCTAssertTrue(responder.hasModalSheet)
    }
}
