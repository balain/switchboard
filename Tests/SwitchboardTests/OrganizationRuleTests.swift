import XCTest
@testable import Switchboard

final class OrganizationRuleTests: XCTestCase {
    func testExactHostFolderBoundariesAndMetadataConditions() {
        var rule = OrganizationRule(name: "Host"); rule.host = "example.com"
        let data = LibraryData()
        XCTAssertTrue(rule.matches(LibraryEntry(name: "A", location: "https://example.com/a", kind: .url), in: data))
        XCTAssertFalse(rule.matches(LibraryEntry(name: "A", location: "https://sub.example.com/a", kind: .url), in: data))
        rule.host = ""; rule.folder = "/tmp/work"
        XCTAssertTrue(rule.matches(LibraryEntry(name: "A", location: "/tmp/work/a.pdf", kind: .file), in: data))
        XCTAssertFalse(rule.matches(LibraryEntry(name: "A", location: "/tmp/work-other/a.pdf", kind: .file), in: data))
        rule.criteria.fileExtension = "txt"
        XCTAssertFalse(rule.matches(LibraryEntry(name: "A", location: "/tmp/work/a.pdf", kind: .file), in: data))
    }
    func testOrderedRulesSeeEarlierChangesAndReportOverrides() {
        let tag = LibraryTag(name: "Research"); var data = LibraryData(); data.tags = [tag]
        var first = OrganizationRule(name: "Tag"); first.enabled = true; first.actions = [.addTag(tag.id), .favorite(true)]
        var second = OrganizationRule(name: "Later"); second.enabled = true; second.criteria.tagIDs = [tag.id]; second.actions = [.favorite(false)]
        data.rules = [first, second]
        let entry = LibraryEntry(name: "A", location: "/tmp/a", kind: .file)
        let preview = RuleEngine.preview(entries: [entry], data: data, event: .manual)
        XCTAssertEqual(preview.updated[0].tags, ["Research"]); XCTAssertFalse(preview.updated[0].favorite)
        XCTAssertEqual(preview.reasons[entry.id], ["Tag", "Later"]); XCTAssertEqual(preview.conflicts.count, 1)
        XCTAssertEqual(RuleEngine.preview(entries: [entry], data: data, event: .manual).updated, preview.updated)
        data.rules[0].stopProcessing = true
        XCTAssertTrue(RuleEngine.preview(entries: [entry], data: data, event: .manual).updated[0].favorite)
    }
    @MainActor func testAutomaticAdditionsManualPreviewUndoAndPersistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.json"); let store = LibraryStore(storageURL: url)
        let tag = try XCTUnwrap(store.addTag("Research"))
        var rule = OrganizationRule(name: "Tag new URLs"); rule.enabled = true; rule.criteria.kind = .url; rule.actions = [.addTag(tag), .favorite(true)]
        XCTAssertTrue(store.putRule(rule))
        let id = try XCTUnwrap(store.addURL(name: "A", location: "example.com", collectionID: nil))
        XCTAssertEqual(store.data.entries[0].tags, ["Research"]); XCTAssertTrue(store.data.entries[0].favorite)
        store.undoManager.undo(); XCTAssertEqual(store.data.entries[0].tags, []); XCTAssertFalse(store.data.entries[0].favorite)
        XCTAssertEqual(store.data.entries[0].id, id)
        store.undoManager.removeAllActions()
        let preview = RuleEngine.preview(entries: store.data.entries, data: store.data, event: .manual)
        XCTAssertEqual(store.data.entries[0].tags, [])
        XCTAssertEqual(store.applyRulePreview(preview), 1)
        store.undoManager.undo(); XCTAssertEqual(store.data.entries[0].tags, [])
        XCTAssertEqual(LibraryStore(storageURL: url).data.rules, [rule])
    }
    @MainActor func testNoRetriggerOnUpdatesDuplicatesUndoOrImportedOptOut() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(storageURL: dir.appendingPathComponent("library.json"))
        var rule = OrganizationRule(name: "Favorite"); rule.enabled = true; rule.actions = [.favorite(true)]; XCTAssertTrue(store.putRule(rule))
        _ = store.addURL(name: "A", location: "example.com", collectionID: nil)
        store.undoManager.undo(); XCTAssertFalse(store.data.entries[0].favorite)
        var entry = store.data.entries[0]; entry.notes = "Unrelated"; store.update(entry)
        XCTAssertFalse(store.data.entries[0].favorite)
        _ = store.addURL(name: "Duplicate", location: "example.com", collectionID: nil); XCTAssertFalse(store.data.entries[0].favorite)
        var candidate = store.data
        store.prepareImportedRules(&candidate, importedIDs: [entry.id], enabled: false); XCTAssertFalse(candidate.entries[0].favorite)
        store.prepareImportedRules(&candidate, importedIDs: [entry.id], enabled: true); XCTAssertTrue(candidate.entries[0].favorite)
        XCTAssertFalse(store.data.entries[0].favorite)
    }
    @MainActor func testMissingTargetsDisableRulesAndStalePreviewCannotApply() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(storageURL: dir.appendingPathComponent("library.json"))
        let tag = try XCTUnwrap(store.addTag("Research")); _ = store.addURL(name: "A", location: "example.com", collectionID: nil)
        var rule = OrganizationRule(name: "Tag"); rule.enabled = true; rule.actions = [.addTag(tag)]; XCTAssertTrue(store.putRule(rule))
        let preview = RuleEngine.preview(entries: store.data.entries, data: store.data, event: .manual)
        store.removeTag(tag); XCTAssertFalse(store.data.rules[0].enabled)
        XCTAssertEqual(store.applyRulePreview(preview), 0); XCTAssertTrue(store.data.entries[0].tags.isEmpty)
        XCTAssertNotNil(store.data.rules[0].validation(in: store.data))
    }
    @MainActor func testFailedWritePublishesNeitherNewEntryNorRuleEffects() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var failing = false
        let store = LibraryStore(storageURL: dir.appendingPathComponent("library.json")) { bytes, url in
            if failing { throw CocoaError(.fileWriteNoPermission) }; try bytes.write(to: url, options: .atomic)
        }
        var rule = OrganizationRule(name: "Favorite"); rule.enabled = true; XCTAssertTrue(store.putRule(rule))
        let bytes = try Data(contentsOf: dir.appendingPathComponent("library.json")); failing = true
        XCTAssertNil(store.addURL(name: "A", location: "example.com", collectionID: nil)); XCTAssertTrue(store.data.entries.isEmpty)
        XCTAssertFalse(store.undoManager.canUndo); XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("library.json")), bytes)
    }
    func testLegacyDataDefaultsToNoRulesAndInvalidTargetsFailClosed() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LibraryData())) as? [String: Any]); object.removeValue(forKey: "rules")
        let legacy = try JSONDecoder().decode(LibraryData.self, from: JSONSerialization.data(withJSONObject: object)); XCTAssertTrue(legacy.rules.isEmpty)
        var rule = OrganizationRule(name: "Invalid"); rule.enabled = true; rule.actions = [.collection(UUID())]
        var data = LibraryData(); data.rules = [rule]
        let entry = LibraryEntry(name: "A", location: "/tmp/a", kind: .file)
        XCTAssertEqual(RuleEngine.preview(entries: [entry], data: data, event: .manual).updated, [entry])
    }
}
