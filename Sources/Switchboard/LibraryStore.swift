import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

@MainActor
final class LibraryStore: ObservableObject {
    @Published var data = LibraryData()
    @Published var error: String?
    var importRuleProcessor: ((inout LibraryData, Set<UUID>) -> Void)?
    var importRulesAvailable: Bool { importRuleProcessor != nil }
    @Published var lastAffectedCount = 0
    let undoManager = UndoManager()
    private let storageURL: URL
    let backups: LibraryBackups
    private let writer: (Data, URL) throws -> Void
    private var lastPersisted = LibraryData()
    private var canSave = true
    private var clearHistoryAfterReplay = false
    private var historySubscriptions: [AnyCancellable] = []

    convenience init(storageURL: URL? = nil, writer: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.init(storageURL: storageURL, backupDirectory: nil, clock: Date.init, writer: writer)
    }
    init(storageURL: URL? = nil, backupDirectory: URL?, clock: @escaping () -> Date = Date.init, writer: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.storageURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Switchboard/library.json")
        self.backups = LibraryBackups(directory: backupDirectory ?? self.storageURL.deletingLastPathComponent().appendingPathComponent("Backups"), clock: clock)
        self.writer = writer
        undoManager.groupsByEvent = false
        for name in [NSNotification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.publisher(for: name, object: undoManager).sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.clearHistoryAfterReplay else { return }
                    self.clearHistoryAfterReplay = false
                    self.undoManager.removeAllActions()
                    self.objectWillChange.send()
                }
            }.store(in: &historySubscriptions)
        }
        do {
            if FileManager.default.fileExists(atPath: self.storageURL.path) {
                data = try JSONDecoder().decode(LibraryData.self, from: Data(contentsOf: self.storageURL))
            }
            normalize(&data)
        } catch { canSave = false; self.error = "Could not read the library: \(error.localizedDescription). Your saved library has not been changed." }
        lastPersisted = data
    }
    private func persist(_ candidate: LibraryData) -> Bool {
        guard canSave else { error = "Saving is disabled because the existing library could not be read."; return false }
        do {
            let encoded = try JSONEncoder().encode(candidate)
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            for suffix in ["before-smart-collections", "before-bulk-organization"] {
                let checkpoint = storageURL.appendingPathExtension(suffix)
                if FileManager.default.fileExists(atPath: storageURL.path), !FileManager.default.fileExists(atPath: checkpoint.path) {
                    try FileManager.default.copyItem(at: storageURL, to: checkpoint)
                }
            }
            if FileManager.default.fileExists(atPath: storageURL.path) { _ = try backups.daily(Data(contentsOf: storageURL)) }
            try writer(encoded, storageURL)
            lastPersisted = candidate
            return true
        } catch { self.error = "Could not save the library: \(error.localizedDescription)"; return false }
    }
    @discardableResult func save() -> Bool {
        guard persist(data) else { data = lastPersisted; return false }
        return true
    }
    @discardableResult private func commit(_ candidate: LibraryData) -> Bool {
        guard persist(candidate) else { return false }
        data = candidate
        return true
    }
    @discardableResult
    func putSavedFilter(_ value: SavedFilter) -> Bool {
        var value = value
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty, !data.savedFilters.contains(where: {
            $0.id != value.id && $0.name.caseInsensitiveCompare(value.name) == .orderedSame
        }) else { error = "Enter a unique smart collection name."; return false }
        var candidate = data
        if let index = candidate.savedFilters.firstIndex(where: { $0.id == value.id }) { candidate.savedFilters[index] = value }
        else { candidate.savedFilters.append(value) }
        return commit(candidate)
    }
    func removeSavedFilter(_ id: UUID) {
        var candidate = data
        candidate.savedFilters.removeAll { $0.id == id }
        _ = commit(candidate)
    }
    @discardableResult func backupNow() -> URL? {
        guard canSave else { error = "The unreadable library cannot be saved as a verified backup. Restore a valid backup instead."; return nil }
        do {
            guard FileManager.default.fileExists(atPath: storageURL.path) || save() else { return nil }
            return try backups.checkpoint(Data(contentsOf: storageURL), label: "manual")
        } catch { self.error = "Backup failed: \(error.localizedDescription)"; return nil }
    }
    func backupIfNeeded() {
        guard canSave, FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do { _ = try backups.daily(Data(contentsOf: storageURL)) }
        catch { self.error = "Automatic backup failed: \(error.localizedDescription)" }
    }
    func prepareImport(_ incoming: LibraryData, policy: DuplicatePolicy, applyRules: Bool = false) throws -> ImportPreview {
        let preview = try ImportPreview.prepare(incoming, into: data, policy: policy)
        guard applyRules else { return preview }
        guard let importRuleProcessor else { throw TransferError(message: "Organization rules are not available.") }
        var candidate = preview.candidate
        let imported = Set(candidate.entries.map(\.id)).subtracting(Set(data.entries.map(\.id)))
        importRuleProcessor(&candidate, imported)
        try LibraryIntegrity.validate(candidate)
        return ImportPreview(baseline: preview.baseline, candidate: candidate, added: preview.added, skipped: preview.skipped,
                             conflicts: preview.conflicts + ["Enabled organization rules were applied to \(imported.count) imported entries in this preview."])
    }
    @discardableResult func importLibrary(_ preview: ImportPreview) -> Bool {
        do {
            guard canSave, try LibraryIntegrity.fingerprint(data) == preview.baseline else {
                throw TransferError(message: "The library changed or is unreadable. Generate a fresh import preview.")
            }
            try LibraryIntegrity.validate(preview.candidate)
            if FileManager.default.fileExists(atPath: storageURL.path) {
                _ = try backups.checkpoint(Data(contentsOf: storageURL), label: "pre-import")
            }
            guard commit(preview.candidate) else { return false }
            undoManager.removeAllActions(); return true
        } catch { self.error = "Import failed: \(error.localizedDescription)"; return false }
    }
    @discardableResult func restoreLibrary(_ bytes: Data) -> Bool {
        do {
            guard bytes.count <= LibraryTransfer.maximumImportBytes * 4 else { throw TransferError(message: "Backup is too large.") }
            let restored = try JSONDecoder().decode(LibraryBackup.self, from: bytes).validated()
            if FileManager.default.fileExists(atPath: storageURL.path) {
                let original = try Data(contentsOf: storageURL)
                if canSave { _ = try backups.checkpoint(original, label: "pre-restore") }
                else {
                    try FileManager.default.createDirectory(at: backups.directory, withIntermediateDirectories: true)
                    try original.write(to: backups.directory.appendingPathComponent("unreadable-\(UUID().uuidString).json"), options: .atomic)
                }
            }
            let previous = canSave; canSave = true
            // A malformed source has already been preserved separately; avoid treating it as a daily backup.
            let encoded = try JSONEncoder().encode(restored)
            do {
                try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try writer(encoded, storageURL)
            } catch { canSave = previous; throw error }
            lastPersisted = restored; data = restored; self.error = nil
            undoManager.removeAllActions(); NotificationCenter.default.post(name: .libraryReplaced, object: self)
            return true
        } catch { self.error = "Restore failed: \(error.localizedDescription)"; return false }
    }
    var configuration: ViewConfiguration {
        get { data.configurations[data.view.rawValue] ?? ViewConfiguration() }
        set { var candidate = data; candidate.configurations[data.view.rawValue] = newValue; _ = commit(candidate) }
    }
    func importFiles(collectionID: UUID?) {
        let panel = NSOpenPanel()
        panel.title = "Add files and folders"; panel.prompt = "Add to Library"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { add(panel.urls, collectionID: collectionID) }
    }
    func add(_ urls: [URL], collectionID: UUID?) {
        var candidate = data
        for url in urls {
            let location = url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
            if candidate.entries.contains(where: { $0.location == location }) { continue }
            let kind: EntryKind = url.isFileURL
                ? ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? .folder : .file) : .url
            let bookmark = url.isFileURL ? try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) : nil
            candidate.entries.append(LibraryEntry(name: url.isFileURL ? url.lastPathComponent : (url.host ?? location),
                                                  location: location, kind: kind, collectionID: collectionID, bookmark: bookmark))
        }
        _ = commit(candidate)
    }
    func addURL(name: String, location: String, collectionID: UUID?) -> UUID? {
        guard let url = LibraryLogic.webURL(location) else { return nil }
        if let existing = data.entries.first(where: { $0.location == url.absoluteString }) { return existing.id }
        let entry = LibraryEntry(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (url.host ?? location) : name,
                                 location: url.absoluteString, kind: .url, collectionID: collectionID)
        var candidate = data; candidate.entries.append(entry)
        return commit(candidate) ? entry.id : nil
    }
    func update(_ entry: LibraryEntry, undoable: Bool = true) {
        guard let index = data.entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let before = data.entries[index]
        if let id = entry.collectionID, id != before.collectionID, !data.collections.contains(where: { $0.id == id }) {
            error = "That collection is no longer available."; return
        }
        var candidate = data; candidate.entries[index] = entry; normalize(&candidate)
        let after = candidate.entries[index]
        guard before != after else { return }
        if commit(candidate), undoable { record([.update(EntryPatch(before: before, after: after))], inverse: true, title: "Edit Entry") }
    }
    @discardableResult func remove(_ ids: Set<UUID>) -> Int { applyBulk(.remove, to: ids) }

    @discardableResult func applyBulk(_ action: BulkAction, to ids: Set<UUID>) -> Int {
        lastAffectedCount = 0
        var candidate = data
        var mutations: [LibraryMutation] = []
        var tagName: String?
        switch action {
        case .addTag(let id), .removeTag(let id):
            guard let tag = data.tags.first(where: { $0.id == id }) else { error = "That tag is no longer available."; return 0 }
            tagName = tag.name
        case .collection(let id):
            if let id, !data.collections.contains(where: { $0.id == id }) { error = "That collection is no longer available."; return 0 }
        default: break
        }
        for (index, entry) in data.entries.enumerated() where ids.contains(entry.id) {
            if case .remove = action { mutations.append(.remove(entry, index)); continue }
            var updated = entry
            switch action {
            case .addTag:
                if let tagName, !updated.tags.contains(where: { $0.caseInsensitiveCompare(tagName) == .orderedSame }) { updated.tags.append(tagName) }
            case .removeTag:
                if let tagName { updated.tags.removeAll { $0.caseInsensitiveCompare(tagName) == .orderedSame } }
            case .collection(let id): updated.collectionID = id
            case .favorite(let value): updated.favorite = value
            case .remove: break
            }
            if updated != entry { mutations.append(.update(EntryPatch(before: entry, after: updated))) }
        }
        guard !mutations.isEmpty else { return 0 }
        guard mutations.allSatisfy({ $0.apply(to: &candidate, inverse: false) }), commit(candidate) else { return 0 }
        record(mutations, inverse: true, title: action.title)
        lastAffectedCount = mutations.count
        return mutations.count
    }
    private func record(_ mutations: [LibraryMutation], inverse: Bool, title: String) {
        let grouping = !undoManager.isUndoing && !undoManager.isRedoing
        if grouping { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { target in target.replay(mutations, inverse: inverse, title: title) }
        undoManager.setActionName(title)
        if grouping { undoManager.endUndoGrouping() }
        objectWillChange.send()
    }
    private func replay(_ mutations: [LibraryMutation], inverse: Bool, title: String) {
        var candidate = data
        guard mutations.allSatisfy({ $0.apply(to: &candidate, inverse: inverse) }) else {
            error = "Cannot undo or redo because affected entries or referenced tags/collections changed. Library history was cleared."
            clearHistoryAfterReplay = true; objectWillChange.send(); return
        }
        guard commit(candidate) else { error = (error ?? "Could not save.") + " Library history was cleared after the failed Undo/Redo."; clearHistoryAfterReplay = true; objectWillChange.send(); return }
        record(mutations, inverse: !inverse, title: title)
        lastAffectedCount = mutations.count
    }
    private func normalize(_ candidate: inout LibraryData) {
        for index in candidate.entries.indices {
            var names: [String] = []
            for raw in candidate.entries[index].tags {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !name.contains(",") else { continue }
                if !candidate.tags.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { candidate.tags.append(LibraryTag(name: name)) }
                if let canonical = candidate.tags.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.name,
                   !names.contains(canonical) { names.append(canonical) }
            }
            candidate.entries[index].tags = names
        }
    }
    @discardableResult func addTag(_ raw: String, persist: Bool = true) -> UUID? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains(",") else { return nil }
        if let existing = data.tags.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return existing.id }
        let tag = LibraryTag(name: name); var candidate = data; candidate.tags.append(tag)
        if persist { return commit(candidate) ? tag.id : nil }
        data = candidate; return tag.id
    }
    func updateTag(_ tag: LibraryTag) -> Bool {
        guard let index = data.tags.firstIndex(where: { $0.id == tag.id }) else { return false }
        var updated = tag; updated.name = tag.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.name.isEmpty, !updated.name.contains(","),
              !data.tags.contains(where: { $0.id != tag.id && $0.name.caseInsensitiveCompare(updated.name) == .orderedSame }) else { return false }
        var candidate = data; candidate.tags[index] = updated
        for i in candidate.entries.indices {
            candidate.entries[i].tags = candidate.entries[i].tags.map { $0.caseInsensitiveCompare(data.tags[index].name) == .orderedSame ? updated.name : $0 }
        }
        return commit(candidate)
    }
    func removeTag(_ id: UUID) {
        guard let tag = data.tags.first(where: { $0.id == id }) else { return }
        var candidate = data; candidate.tags.removeAll { $0.id == id }
        for index in candidate.entries.indices { candidate.entries[index].tags.removeAll { $0.caseInsensitiveCompare(tag.name) == .orderedSame } }
        _ = commit(candidate)
    }
    func addCollection(_ name: String) -> UUID {
        let collection = LibraryCollection(name: name); var candidate = data; candidate.collections.append(collection)
        _ = commit(candidate); return collection.id
    }
    func updateCollection(_ collection: LibraryCollection) {
        guard let index = data.collections.firstIndex(where: { $0.id == collection.id }),
              !collection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let parent = collection.parentID {
            guard data.collections.contains(where: { $0.id == parent }),
                  !LibraryLogic.descendants(of: collection.id, in: data.collections).contains(parent) else { return }
        }
        var candidate = data; candidate.collections[index] = collection; _ = commit(candidate)
    }
    func removeCollection(_ id: UUID) {
        var candidate = data
        let parent = candidate.collections.first { $0.id == id }?.parentID
        for index in candidate.collections.indices where candidate.collections[index].parentID == id { candidate.collections[index].parentID = parent }
        candidate.collections.removeAll { $0.id == id }
        for index in candidate.entries.indices where candidate.entries[index].collectionID == id { candidate.entries[index].collectionID = nil }
        _ = commit(candidate)
    }
    func resolve(_ entry: LibraryEntry) -> URL? {
        if let bookmark = entry.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                if url.path != entry.location || stale {
                    var updated = entry
                    updated.location = url.path
                    updated.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                    update(updated, undoable: false)
                }
                return url
            }
        }
        return entry.url
    }
    func open(_ entry: LibraryEntry) {
        guard let url = resolve(entry) else { return }
        NSWorkspace.shared.open(url, configuration: .init()) { _, error in
            if let error { Task { @MainActor in self.error = "Could not open \(entry.name): \(error.localizedDescription)" } }
        }
    }
    func reveal(_ entry: LibraryEntry) {
        guard let url = resolve(entry), url.isFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

extension Notification.Name { static let libraryReplaced = Notification.Name("Switchboard.libraryReplaced") }
