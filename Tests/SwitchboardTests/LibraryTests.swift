import XCTest
@testable import Switchboard

final class LibraryTests: XCTestCase {
    func testFlatHierarchyAndSearchScopes() {
        let parent = LibraryCollection(name: "Parent")
        let child = LibraryCollection(name: "Child", parentID: parent.id)
        let collections = [parent, child]
        let loose = LibraryEntry(name: "Loose", location: "/tmp/loose", kind: .folder)
        let direct = LibraryEntry(name: "Direct", location: "/tmp/direct", kind: .file, collectionID: parent.id)
        let nested = LibraryEntry(name: "Nested", location: "/tmp/nested", kind: .file, collectionID: child.id, favorite: true)
        let entries = [loose, direct, nested]
        func ids(_ scope: String, hierarchical: Bool, query: String = "") -> Set<UUID> {
            Set(LibraryLogic.scopedEntries(entries, collections: collections, scope: scope,
                                          hierarchical: hierarchical, query: query, sort: .name).map(\.id))
        }
        XCTAssertEqual(ids("all", hierarchical: false), [loose.id, direct.id, nested.id])
        XCTAssertEqual(ids("all", hierarchical: true), [loose.id])
        XCTAssertEqual(ids(parent.id.uuidString, hierarchical: false), [direct.id, nested.id])
        XCTAssertEqual(ids(parent.id.uuidString, hierarchical: true), [direct.id])
        XCTAssertEqual(ids(parent.id.uuidString, hierarchical: true, query: "nested"), [nested.id])
        XCTAssertEqual(ids("all", hierarchical: true, query: "nested"), [nested.id])
        XCTAssertEqual(ids("favorites", hierarchical: true), [nested.id])
        XCTAssertEqual(ids("folder", hierarchical: false), [loose.id])
    }

    func testLegacyCollectionsDecodeWithoutNewFields() throws {
        let id = UUID()
        let json = Data("{\"id\":\"\(id.uuidString)\",\"name\":\"Work\"}".utf8)
        let collection = try JSONDecoder().decode(LibraryCollection.self, from: json)
        XCTAssertEqual(collection.id, id)
        XCTAssertEqual(collection.symbol, "folder.fill")
        XCTAssertNil(collection.parentID)
        XCTAssertNil(collection.palette)
    }

    @MainActor func testNestedCollectionsPersistRejectCyclesAndReparentOnDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        let store = LibraryStore(storageURL: url)
        let root = store.addCollection("Work")
        let child = store.addCollection("Projects")
        let grandchild = store.addCollection("Current")
        store.updateCollection(LibraryCollection(id: child, name: "Projects", parentID: root, icon: "briefcase.fill", palette: .forest))
        store.updateCollection(LibraryCollection(id: grandchild, name: "Current", parentID: child))
        XCTAssertEqual(LibraryLogic.descendants(of: root, in: store.data.collections), [root, child, grandchild])
        XCTAssertEqual(LibraryLogic.collectionPath(store.data.collections[2], in: store.data.collections), "Work / Projects / Current")
        store.updateCollection(LibraryCollection(id: root, name: "Work", parentID: grandchild))
        XCTAssertNil(store.data.collections.first { $0.id == root }?.parentID)
        let item = try XCTUnwrap(store.addURL(name: "Example", location: "example.com", collectionID: child))
        let restored = LibraryStore(storageURL: url)
        XCTAssertEqual(restored.data.collections.first { $0.id == child }?.palette, .forest)
        XCTAssertEqual(restored.data.collections.first { $0.id == child }?.symbol, "briefcase.fill")
        restored.removeCollection(child)
        XCTAssertEqual(restored.data.collections.first { $0.id == grandchild }?.parentID, root)
        XCTAssertNil(restored.data.entries.first { $0.id == item }?.collectionID)
        XCTAssertEqual(LibraryStore(storageURL: url).data.entries.count, 1)
    }

    func testURLValidation() {
        XCTAssertEqual(LibraryLogic.webURL(" example.com/path ")?.absoluteString, "https://example.com/path")
        XCTAssertNil(LibraryLogic.webURL("javascript://alert(1)"))
        XCTAssertNil(LibraryLogic.webURL("file:///etc/passwd"))
        XCTAssertNil(LibraryLogic.webURL(""))
        XCTAssertNil(LibraryLogic.webURL("not a host"))
    }
    func testSearchAndSort() {
        let a = LibraryEntry(name: "Zebra", location: "/tmp/a", kind: .file, tags: ["design"])
        let b = LibraryEntry(name: "Alpha", location: "https://example.com", kind: .url, notes: "Reading list")
        XCTAssertEqual(LibraryLogic.filtered([a, b], query: "DESIGN", sort: .name).map(\.id), [a.id])
        XCTAssertEqual(LibraryLogic.filtered([a, b], query: "reading", sort: .name).map(\.id), [b.id])
        XCTAssertEqual(LibraryLogic.filtered([a, b], query: "", sort: .name).map(\.name), ["Alpha", "Zebra"])
    }
    @MainActor func testPersistenceDeduplicationAndSafeCollectionRemoval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        let store = LibraryStore(storageURL: url)
        let collection = store.addCollection("Work")
        let id = try XCTUnwrap(store.addURL(name: "Example", location: "example.com", collectionID: collection))
        _ = store.addURL(name: "Duplicate", location: "https://example.com", collectionID: nil)
        XCTAssertEqual(store.data.entries.count, 1)
        store.data.view = .largeCards
        store.configuration = ViewConfiguration(fields: [.notes], palette: .forest, fontName: "Menlo", fontSize: 18)
        let restored = LibraryStore(storageURL: url)
        XCTAssertEqual(restored.data.entries.first?.id, id)
        XCTAssertEqual(restored.configuration.palette, .forest)
        restored.removeCollection(collection)
        XCTAssertEqual(restored.data.entries.count, 1)
        XCTAssertNil(restored.data.entries.first?.collectionID)
        restored.remove([id])
        XCTAssertTrue(LibraryStore(storageURL: url).data.entries.isEmpty)
    }
    @MainActor func testUnreadableLibraryIsNeverOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("library.json")
        let original = Data("invalid json".utf8)
        try original.write(to: url)
        let store = LibraryStore(storageURL: url)
        XCTAssertNotNil(store.error)
        store.save()
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    @MainActor func testViewConfigurationsAreIndependent() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(storageURL: directory.appendingPathComponent("library.json"))
        store.configuration = ViewConfiguration(fields: [.notes], palette: .violet, fontName: "Menlo", fontSize: 20)
        store.data.view = .table
        XCTAssertEqual(store.configuration, ViewConfiguration())
        store.configuration = ViewConfiguration(fields: [.added], palette: .forest)
        store.data.view = .mediumCards
        XCTAssertEqual(store.configuration.fontSize, 20)
        XCTAssertEqual(store.configuration.fields, [.notes])
    }

    @MainActor func testMissingFileAndFolderPromptToDeleteWithUndoAndCancel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("note.txt")
        let folderURL = directory.appendingPathComponent("Archive")
        try Data("hello".utf8).write(to: fileURL)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        var openedURLs: [URL] = []
        var revealedURLs: [URL] = []
        let store = LibraryStore(
            storageURL: directory.appendingPathComponent("library.json"),
            backupDirectory: nil,
            workspaceOpener: { url, completion in openedURLs.append(url); completion(nil) },
            finderRevealer: { url in revealedURLs.append(url) }
        )
        store.add([fileURL, folderURL], collectionID: nil)
        let urlID = try XCTUnwrap(store.addURL(name: "Example", location: "https://example.com", collectionID: nil))
        let fileEntry = try XCTUnwrap(store.data.entries.first { $0.kind == .file })
        let folderEntry = try XCTUnwrap(store.data.entries.first { $0.kind == .folder })

        // Healthy entries open and reveal normally.
        store.open(fileEntry)
        store.reveal(folderEntry)
        XCTAssertEqual(openedURLs.map(\.standardizedFileURL.path), [fileURL.standardizedFileURL.path])
        XCTAssertEqual(revealedURLs.map(\.standardizedFileURL.path), [folderURL.standardizedFileURL.path])
        XCTAssertNil(store.missingEntry)

        // Delete file and folder on disk.
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.removeItem(at: folderURL)
        openedURLs.removeAll()
        revealedURLs.removeAll()

        store.open(fileEntry)
        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.missingEntry?.id, fileEntry.id)

        // Cancel keeps the entry.
        store.missingEntry = nil
        XCTAssertTrue(store.data.entries.contains(where: { $0.id == fileEntry.id }))

        // Reveal on missing file also offers deletion without invoking Finder.
        store.reveal(fileEntry)
        XCTAssertTrue(revealedURLs.isEmpty)
        XCTAssertEqual(store.missingEntry?.id, fileEntry.id)
        store.missingEntry = nil

        // Opening missing folder and confirming deletion removes only that entry and supports Undo.
        store.open(folderEntry)
        XCTAssertEqual(store.missingEntry?.id, folderEntry.id)
        XCTAssertTrue(store.deleteMissingEntry())
        XCTAssertNil(store.missingEntry)
        XCTAssertEqual(Set(store.data.entries.map(\.id)), [fileEntry.id, urlID])

        store.undoManager.undo()
        XCTAssertEqual(Set(store.data.entries.map(\.id)), [fileEntry.id, folderEntry.id, urlID])
    }

    @MainActor func testTrashedEntryWithBookmarkPromptsToDeleteWithoutRewritingLocation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("trashed-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: fileURL)

        var openedURLs: [URL] = []
        let store = LibraryStore(
            storageURL: directory.appendingPathComponent("library.json"),
            backupDirectory: nil,
            workspaceOpener: { url, completion in openedURLs.append(url); completion(nil) }
        )
        store.add([fileURL], collectionID: nil)
        let originalEntry = try XCTUnwrap(store.data.entries.first)

        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: fileURL, resultingItemURL: &trashedURL)
        defer { if let url = trashedURL as URL? { try? FileManager.default.removeItem(at: url) } }

        store.open(originalEntry)
        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertEqual(store.missingEntry?.id, originalEntry.id)
        XCTAssertEqual(store.data.entries.first?.location, originalEntry.location)
    }

    @MainActor func testAsyncMissingErrorFallbackUnavailableVolumeAndURLEntries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var checkStatus: HealthStatus = .healthy
        var openErrorToReturn: Error?
        var openCallCount = 0
        var openExpectation: XCTestExpectation?
        let store = LibraryStore(
            storageURL: directory.appendingPathComponent("library.json"),
            backupDirectory: nil,
            localCheck: { _ in HealthCheck(status: checkStatus, detail: "Detail for \(checkStatus.rawValue)") },
            workspaceOpener: { _, completion in
                openCallCount += 1
                completion(openErrorToReturn)
                openExpectation?.fulfill()
            }
        )
        let brokenSymlinkURL = directory.appendingPathComponent("broken-link")
        try FileManager.default.createSymbolicLink(at: brokenSymlinkURL, withDestinationURL: directory.appendingPathComponent("target-missing"))
        let existingURL = directory.appendingPathComponent("existing.txt")
        try Data("ok".utf8).write(to: existingURL)

        let symlinkEntry = LibraryEntry(name: "BrokenLink", location: brokenSymlinkURL.path, kind: .file)
        let existingEntry = LibraryEntry(name: "Existing", location: existingURL.path, kind: .file)
        store.data.entries = [symlinkEntry, existingEntry]
        XCTAssertTrue(store.save())
        let urlID = try XCTUnwrap(store.addURL(name: "Site", location: "https://example.com", collectionID: nil))
        let urlEntry = try XCTUnwrap(store.data.entries.first { $0.id == urlID })

        func waitForOpenCompletion() async {
            for _ in 0..<50 {
                await Task.yield()
                if store.missingEntry != nil || store.error != nil { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        // Async missing-file error on a real broken symlink prompts for deletion.
        let fnfUnderlying = NSError(domain: NSOSStatusErrorDomain, code: -43)
        openErrorToReturn = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: [NSUnderlyingErrorKey: fnfUnderlying])
        openExpectation = expectation(description: "broken symlink open")
        store.open(symlinkEntry)
        await fulfillment(of: [openExpectation!], timeout: 1)
        await waitForOpenCompletion()
        XCTAssertEqual(openCallCount, 1)
        XCTAssertEqual(store.missingEntry?.id, symlinkEntry.id)
        XCTAssertNil(store.error)

        // Removing the entry through another mutation (e.g. remove/sync) clears missingEntry.
        XCTAssertEqual(store.remove([symlinkEntry.id]), 1)
        XCTAssertNil(store.missingEntry)

        // Existing files never prompt for deletion even if Launch Services reports a missing-file error.
        openExpectation = expectation(description: "existing file open")
        store.open(existingEntry)
        await fulfillment(of: [openExpectation!], timeout: 1)
        await waitForOpenCompletion()
        XCTAssertNil(store.missingEntry)
        XCTAssertNotNil(store.error)
        store.error = nil

        // URL entries never prompt to delete as missing local files.
        openExpectation = expectation(description: "url open")
        store.open(urlEntry)
        await fulfillment(of: [openExpectation!], timeout: 1)
        await waitForOpenCompletion()
        XCTAssertNil(store.missingEntry)
        XCTAssertNotNil(store.error)
        store.error = nil

        // Non-missing file errors show error without prompt.
        openErrorToReturn = CocoaError(.fileReadCorruptFile)
        openExpectation = expectation(description: "corrupt file error")
        store.open(existingEntry)
        await fulfillment(of: [openExpectation!], timeout: 1)
        await waitForOpenCompletion()
        XCTAssertNil(store.missingEntry)
        XCTAssertNotNil(store.error)
        store.error = nil

        // Unavailable volume does not offer deletion.
        checkStatus = .unavailableVolume
        let priorCalls = openCallCount
        store.open(existingEntry)
        XCTAssertEqual(openCallCount, priorCalls)
        XCTAssertNil(store.missingEntry)
        XCTAssertTrue(store.error?.contains("Detail for unavailableVolume") == true)
    }

    func testIsTrashedRulesForUserTrashVolumeTrashesAndOriginalTrashLocations() {
        XCTAssertTrue(LocalHealthProbe.isTrashed(URL(fileURLWithPath: "/Users/example/.Trash/note.txt"), originalLocation: "/Users/example/Desktop/note.txt"))
        XCTAssertTrue(LocalHealthProbe.isTrashed(URL(fileURLWithPath: "/Volumes/External/.Trashes/501/note.txt"), originalLocation: "/Volumes/External/note.txt"))
        XCTAssertFalse(LocalHealthProbe.isTrashed(URL(fileURLWithPath: "/Users/example/.Trash/note.txt"), originalLocation: "/Users/example/.Trash/note.txt"))
        XCTAssertFalse(LocalHealthProbe.isTrashed(URL(fileURLWithPath: "/Users/example/Documents/note.txt"), originalLocation: "/Users/example/Desktop/note.txt"))
    }

}
