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
        } catch { canSave = false; self.error = "Could not read the library: \(error.localizedDescription). Your saved library has not been changed." }
    }
    func save() {
        guard canSave else { error = "Saving is disabled because the existing library could not be read. Restore library.json from a backup and restart Switchboard."; return }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(data).write(to: storageURL, options: .atomic)
        } catch { self.error = "Could not save the library: \(error.localizedDescription)" }
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
        data.entries[index] = entry; save()
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
