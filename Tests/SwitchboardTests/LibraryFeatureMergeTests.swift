import XCTest
@testable import Switchboard

final class LibraryFeatureMergeTests: XCTestCase {
    func testPortableRulesRoundTripAndLegacyEnvelopeWithoutRules() throws {
        let tag = LibraryTag(name: "Research"), collection = LibraryCollection(name: "Reading")
        var rule = OrganizationRule(name: "Organize PDFs"); rule.enabled = true
        rule.criteria.tagIDs = [tag.id]; rule.actions = [.addTag(tag.id), .collection(collection.id)]
        var original = LibraryData(); original.tags = [tag]; original.collections = [collection]; original.rules = [rule]
        let bytes = try LibraryTransfer.export(original, format: .json)
        XCTAssertEqual(try LibraryTransfer.parse(bytes, html: false).rules, [rule])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object.removeValue(forKey: "rules")
        XCTAssertTrue(try LibraryTransfer.parse(JSONSerialization.data(withJSONObject: object), html: false).rules.isEmpty)
        var existing = original; existing.rules[0].name = "Existing"
        let preview = try ImportPreview.prepare(original, into: existing, policy: .skip)
        let copy = try XCTUnwrap(preview.candidate.rules.last)
        XCTAssertNotEqual(copy.id, rule.id); XCTAssertFalse(copy.enabled)
        let copiedCollection = try XCTUnwrap(preview.candidate.collections.last)
        XCTAssertEqual(copy.actions, [.addTag(tag.id), .collection(copiedCollection.id)])
    }
    func testMissingImportedRuleTargetsCannotBindUnrelatedExistingMetadata() throws {
        let tag = LibraryTag(name: "Existing"), collection = LibraryCollection(name: "Existing")
        var existing = LibraryData(); existing.tags = [tag]; existing.collections = [collection]
        var rule = OrganizationRule(name: "Missing targets"); rule.enabled = true
        rule.criteria.tagIDs = [tag.id]; rule.actions = [.addTag(tag.id), .collection(collection.id)]
        var incoming = LibraryData(); incoming.rules = [rule]
        let preview = try ImportPreview.prepare(incoming, into: existing, policy: .skip)
        let copy = try XCTUnwrap(preview.candidate.rules.first)
        XCTAssertFalse(copy.enabled); XCTAssertTrue(copy.unavailable(in: preview.candidate))
        XCTAssertNotEqual(copy.criteria.tagIDs, [tag.id]); XCTAssertNotEqual(copy.actions, rule.actions)
    }
    @MainActor func testImportRuleOptInAndBackupRestoreDoNotRunRulesAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(storageURL: directory.appendingPathComponent("library.json"))
        var rule = OrganizationRule(name: "Favorite additions"); rule.enabled = true
        XCTAssertTrue(store.putRule(rule)); XCTAssertTrue(store.importRulesAvailable)
        var incoming = LibraryData(); incoming.entries = [LibraryEntry(name: "Imported", location: "https://example.com", kind: .url)]
        XCTAssertFalse(try store.prepareImport(incoming, policy: .skip).candidate.entries[0].favorite)
        let preview = try store.prepareImport(incoming, policy: .skip, applyRules: true)
        XCTAssertTrue(preview.candidate.entries[0].favorite); XCTAssertTrue(store.data.entries.isEmpty)
        XCTAssertTrue(store.importLibrary(preview))
        let id = try XCTUnwrap(store.data.entries.first?.id)
        store.applyBulk(.favorite(false), to: [id])
        let backup = try XCTUnwrap(store.backupNow())
        store.applyBulk(.favorite(true), to: [id])
        XCTAssertTrue(store.restoreLibrary(try Data(contentsOf: backup)))
        XCTAssertEqual(store.data.rules, [rule]); XCTAssertFalse(store.data.entries[0].favorite)
        XCTAssertFalse(store.undoManager.canUndo)
    }
    @MainActor func testHealthRepairPreservesRuleStateAndSupportsUndoWithBackups() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(storageURL: directory.appendingPathComponent("library.json"))
        let id = try XCTUnwrap(store.addURL(name: "Before", location: "https://example.com", collectionID: nil))
        var rule = OrganizationRule(name: "Favorite new entries"); rule.enabled = true
        XCTAssertTrue(store.putRule(rule))
        let original = try XCTUnwrap(store.data.entries.first)
        var replacement = original; replacement.location = "https://replacement.example.com"
        XCTAssertEqual(store.applyEntryChanges(expected: [original], updated: [replacement], title: "Repair Reference"), 1)
        XCTAssertFalse(store.data.entries[0].favorite)
        store.undoManager.undo(); XCTAssertEqual(store.data.entries.first { $0.id == id }, original)
        XCTAssertEqual(store.data.rules, [rule]); XCTAssertNotNil(store.backupNow())
    }
}
