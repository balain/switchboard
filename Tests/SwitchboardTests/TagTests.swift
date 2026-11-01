import XCTest
@testable import Switchboard

final class TagTests: XCTestCase {
    func testTagFiltersCombineWithScopeSearchAndHierarchy() {
        let parent = LibraryCollection(name: "Work")
        let child = LibraryCollection(name: "Projects", parentID: parent.id)
        let both = LibraryEntry(name: "Both", location: "/tmp/both", kind: .file, tags: ["Work", "Reading"], collectionID: child.id, favorite: true)
        let work = LibraryEntry(name: "Work only", location: "/tmp/work", kind: .file, tags: ["Work"], collectionID: parent.id)
        let other = LibraryEntry(name: "Other", location: "/tmp/other", kind: .url, tags: ["Reading"])
        let untagged = LibraryEntry(name: "None", location: "/tmp/none", kind: .file)
        func ids(_ scope: String = "all", query: String = "", tags: Set<String>, match: TagMatch = .any) -> Set<UUID> {
            Set(LibraryLogic.scopedEntries([both, work, other, untagged], collections: [parent, child], scope: scope,
                                          hierarchical: true, query: query, sort: .name, tags: tags, tagMatch: match).map(\.id))
        }
        XCTAssertEqual(ids(tags: ["WORK", "reading"]), [both.id, work.id, other.id])
        XCTAssertEqual(ids(tags: ["WORK", "reading"], match: .all), [both.id])
        XCTAssertEqual(ids(parent.id.uuidString, tags: ["reading"]), [both.id])
        XCTAssertEqual(ids("favorites", tags: ["work"]), [both.id])
        XCTAssertEqual(ids("url", tags: ["work"]), [])
        XCTAssertEqual(ids(query: "only", tags: ["work"]), [work.id])
        XCTAssertEqual(ids(tags: ["missing"]), [])
        XCTAssertEqual(ids(tags: []), [other.id, untagged.id]) // Hierarchical root without filtering.
    }

    @MainActor func testCatalogMigrationRenamingDeletionAndPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("library.json")
        var legacy = LibraryData()
        let entry = LibraryEntry(name: "Notes", location: "/tmp/notes", kind: .file, tags: [" Work ", "work", "Reading", ""])
        legacy.entries = [entry]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json.removeValue(forKey: "tags")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let store = LibraryStore(storageURL: url)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.data.tags.map(\.name), ["Work", "Reading"])
        XCTAssertEqual(store.data.entries[0].tags, ["Work", "Reading"])
        let work = try XCTUnwrap(store.data.tags.first)
        XCTAssertEqual(store.addTag(" work "), work.id)
        XCTAssertNil(store.addTag(" "))
        XCTAssertNil(store.addTag("two,tags"))
        XCTAssertFalse(store.updateTag(LibraryTag(id: work.id, name: "READING")))
        XCTAssertFalse(store.updateTag(LibraryTag(id: work.id, name: "")))
        XCTAssertTrue(store.updateTag(LibraryTag(id: work.id, name: "Projects", icon: "briefcase.fill", palette: .forest)))
        XCTAssertEqual(store.data.entries[0].tags, ["Projects", "Reading"])
        let unused = try XCTUnwrap(store.addTag("Unused"))
        var updated = store.data.entries[0]
        updated.tags += ["projects", "New", " new "]
        store.update(updated)
        XCTAssertEqual(store.data.entries[0].tags, ["Projects", "Reading", "New"])
        let restored = LibraryStore(storageURL: url)
        XCTAssertEqual(restored.data.tags.first?.id, work.id)
        XCTAssertEqual(restored.data.tags.first?.palette, .forest)
        XCTAssertTrue(restored.data.tags.contains { $0.id == unused })
        restored.removeTag(work.id)
        let final = LibraryStore(storageURL: url)
        XCTAssertEqual(final.data.entries.map(\.id), [entry.id])
        XCTAssertEqual(final.data.entries[0].tags, ["Reading", "New"])
        XCTAssertFalse(final.data.tags.contains { $0.id == work.id })
    }

    @MainActor func testTagFilterPreferencesRestoreAndDiscardDeletedTags() throws {
        let suite = "SwitchboardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tag = LibraryTag(name: "Work")
        let state = LibraryWindowState(defaults: defaults)
        XCTAssertTrue(state.selectedTags.isEmpty)
        XCTAssertEqual(state.tagMatch, .any)
        state.selectedTags = [tag.id, UUID()]
        state.tagMatch = .all
        state.showTags = true
        let restored = LibraryWindowState(defaults: defaults)
        XCTAssertEqual(restored.selectedTags, state.selectedTags)
        XCTAssertEqual(restored.tagMatch, .all)
        XCTAssertFalse(restored.showTags)
        var data = LibraryData()
        data.tags = [tag]
        restored.validate(in: data)
        XCTAssertEqual(restored.selectedTags, [tag.id])
        data.tags = []
        restored.validate(in: data)
        XCTAssertTrue(LibraryWindowState(defaults: defaults).selectedTags.isEmpty)
    }
}
