import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class LibraryStore: ObservableObject {
    @Published var data = LibraryData()
    @Published var error: String?
    private let storageURL: URL
    private var canSave = true

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Switchboard/library.json")
        do {
            if FileManager.default.fileExists(atPath: self.storageURL.path) {
                data = try JSONDecoder().decode(LibraryData.self, from: Data(contentsOf: self.storageURL))
            }
            registerEntryTags()
        } catch { canSave = false; self.error = "Could not read the library: \(error.localizedDescription). Your saved library has not been changed." }
    }
    @discardableResult
    func save() -> Bool { persist(data) }
    private func persist(_ candidate: LibraryData) -> Bool {
        guard canSave else { error = "Saving is disabled because the existing library could not be read."; return false }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let checkpoint = storageURL.appendingPathExtension("before-smart-collections")
            if FileManager.default.fileExists(atPath: storageURL.path), !FileManager.default.fileExists(atPath: checkpoint.path) {
                try FileManager.default.copyItem(at: storageURL, to: checkpoint)
            }
            try JSONEncoder().encode(candidate).write(to: storageURL, options: .atomic)
            return true
        } catch { self.error = "Could not save the library: \(error.localizedDescription)"; return false }
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
        guard persist(candidate) else { return false }
        data = candidate
        return true
    }
    func removeSavedFilter(_ id: UUID) {
        var candidate = data
        candidate.savedFilters.removeAll { $0.id == id }
        if persist(candidate) { data = candidate }
    }
    var configuration: ViewConfiguration {
        get { data.configurations[data.view.rawValue] ?? ViewConfiguration() }
        set { data.configurations[data.view.rawValue] = newValue; save() }
    }
    func importFiles(collectionID: UUID?) {
        let panel = NSOpenPanel()
        panel.title = "Add files and folders"
        panel.prompt = "Add to Library"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { add(panel.urls, collectionID: collectionID) }
    }
    func add(_ urls: [URL], collectionID: UUID?) {
        for url in urls {
            let location = url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
            if data.entries.contains(where: { $0.location == location }) { continue }
            let kind: EntryKind = url.isFileURL
                ? ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? .folder : .file) : .url
            let bookmark = url.isFileURL ? try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) : nil
            data.entries.append(LibraryEntry(name: url.isFileURL ? url.lastPathComponent : (url.host ?? location),
                                             location: location, kind: kind, collectionID: collectionID, bookmark: bookmark))
        }
        save()
    }
    func addURL(name: String, location: String, collectionID: UUID?) -> UUID? {
        guard let url = LibraryLogic.webURL(location) else { return nil }
        if let existing = data.entries.first(where: { $0.location == url.absoluteString }) { return existing.id }
        let entry = LibraryEntry(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (url.host ?? location) : name,
                                 location: url.absoluteString, kind: .url, collectionID: collectionID)
        data.entries.append(entry); save(); return entry.id
    }
    func update(_ entry: LibraryEntry) {
        guard let index = data.entries.firstIndex(where: { $0.id == entry.id }) else { return }
        data.entries[index] = entry; registerEntryTags(); save()
    }
    func remove(_ ids: Set<UUID>) { data.entries.removeAll { ids.contains($0.id) }; save() }
    func resolve(_ entry: LibraryEntry) -> URL? {
        if let bookmark = entry.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                if url.path != entry.location || stale {
                    var updated = entry
                    updated.location = url.path
                    updated.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                    update(updated)
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
    // Preserve existing entry tags while giving every tag a stable identity.
    private func registerEntryTags() {
        for index in data.entries.indices {
            var names: [String] = []
            for raw in data.entries[index].tags {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let id = addTag(name, persist: false)
                guard let canonical = data.tags.first(where: { $0.id == id })?.name else { continue }
                if !names.contains(canonical) { names.append(canonical) }
            }
            data.entries[index].tags = names
        }
    }
    @discardableResult
    func addTag(_ raw: String, persist: Bool = true) -> UUID? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains(",") else { return nil }
        if let existing = data.tags.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return existing.id }
        let tag = LibraryTag(name: name)
        data.tags.append(tag)
        if persist { save() }
        return tag.id
    }
    func updateTag(_ tag: LibraryTag) -> Bool {
        guard let index = data.tags.firstIndex(where: { $0.id == tag.id }) else { return false }
        var updated = tag
        updated.name = tag.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.name.isEmpty, !updated.name.contains(","),
              !data.tags.contains(where: { $0.id != tag.id && $0.name.caseInsensitiveCompare(updated.name) == .orderedSame }) else { return false }
        let oldName = data.tags[index].name
        data.tags[index] = updated
        for index in data.entries.indices {
            data.entries[index].tags = data.entries[index].tags.map {
                $0.caseInsensitiveCompare(oldName) == .orderedSame ? updated.name : $0
            }
        }
        save()
        return true
    }
    func removeTag(_ id: UUID) {
        guard let tag = data.tags.first(where: { $0.id == id }) else { return }
        for index in data.entries.indices {
            data.entries[index].tags.removeAll { $0.caseInsensitiveCompare(tag.name) == .orderedSame }
        }
        data.tags.removeAll { $0.id == id }
        save()
    }

    func addCollection(_ name: String) -> UUID {
        let collection = LibraryCollection(name: name)
        data.collections.append(collection); save(); return collection.id
    }
    func updateCollection(_ collection: LibraryCollection) {
        guard let index = data.collections.firstIndex(where: { $0.id == collection.id }) else { return }
        if let parent = collection.parentID {
            guard data.collections.contains(where: { $0.id == parent }),
                  !LibraryLogic.descendants(of: collection.id, in: data.collections).contains(parent) else { return }
        }
        guard !collection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        data.collections[index] = collection
        save()
    }
    func removeCollection(_ id: UUID) {
        let parent = data.collections.first { $0.id == id }?.parentID
        for index in data.collections.indices where data.collections[index].parentID == id {
            data.collections[index].parentID = parent
        }
        data.collections.removeAll { $0.id == id }
        for index in data.entries.indices where data.entries[index].collectionID == id { data.entries[index].collectionID = nil }
        save()
    }
}
