import SwiftUI

enum RemovalDateMode: String, CaseIterable, Identifiable {
    case any, before, after, range
    var id: String { rawValue }
    var title: String {
        switch self { case .any: "Any Date"; case .before: "Before"; case .after: "On or After"; case .range: "Date Range" }
    }
}

struct EntryRemovalFilter: Equatable {
    var query = ""
    var kind: EntryKind?
    var dateMode: RemovalDateMode = .any
    var startDate = Date()
    var endDate = Date()
    var folder: URL?
    var includeSubfolders = true
    var collection = "all"
    var includeSubcollections = true

    func matching(_ entries: [LibraryEntry], collections: [LibraryCollection] = [], calendar: Calendar = .current) -> [LibraryEntry] {
        let parsed = SearchQuery(query)
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        let upper = calendar.date(byAdding: .day, value: 1, to: end)
        let collectionID = UUID(uuidString: collection)
        let collectionIDs: Set<UUID>
        if let collectionID, collections.contains(where: { $0.id == collectionID }) {
            collectionIDs = includeSubcollections ? LibraryLogic.descendants(of: collectionID, in: collections) : [collectionID]
        } else { collectionIDs = [] }
        let folderParts = folder?.standardizedFileURL.pathComponents
        return entries.filter { entry in
            guard (kind == nil || entry.kind == kind), parsed.matchesMetadata(entry) else { return false }
            switch dateMode {
            case .any: break
            case .before: guard entry.added < start else { return false }
            case .after: guard entry.added >= start else { return false }
            case .range: guard start <= end, let upper, entry.added >= start, entry.added < upper else { return false }
            }
            if let folderParts {
                guard entry.kind != .url else { return false }
                let parts = URL(fileURLWithPath: entry.location).standardizedFileURL.pathComponents
                guard parts.count > folderParts.count, parts.starts(with: folderParts),
                      includeSubfolders || parts.count == folderParts.count + 1 else { return false }
            }
            if collection == "unfiled" { guard entry.collectionID == nil else { return false } }
            else if collection != "all" {
                guard let id = entry.collectionID, collectionIDs.contains(id) else { return false }
            }
            return true
        }.sorted { a, b in
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.id.uuidString < b.id.uuidString : order == .orderedAscending
        }
    }
}

extension LibraryStore {
    /// Remove only the exact entries reviewed in the confirmation, as one undoable action.
    @discardableResult func removeReviewedEntries(_ reviewed: [LibraryEntry]) -> Int {
        let current = Dictionary(data.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard !reviewed.isEmpty, Set(reviewed.map(\.id)).count == reviewed.count,
              reviewed.allSatisfy({ current[$0.id] == $0 }) else {
            error = "The selection changed since review. Select the entries again before removing them."
            return 0
        }
        return remove(Set(reviewed.map(\.id)))
    }
}

struct EntryRemovalReview: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var kind = "all"
    @State private var dateMode: RemovalDateMode = .any
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var folder: URL?
    @State private var includeSubfolders = true
    @State private var collection = "all"
    @State private var includeSubcollections = true

    private var filter: EntryRemovalFilter {
        EntryRemovalFilter(query: query, kind: EntryKind(rawValue: kind), dateMode: dateMode,
            startDate: startDate, endDate: endDate, folder: folder, includeSubfolders: includeSubfolders,
            collection: collection, includeSubcollections: includeSubcollections)
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        if panel.runModal() == .OK { folder = panel.url }
    }
    @State private var selection: Set<UUID> = []
    @State private var reviewed: [LibraryEntry] = []
    @State private var reviewedSyncedCount = 0
    @State private var confirming = false
    @State private var expectedRemovalCount = 0
    @State private var message = ""

    var body: some View {
        let matches = filter.matching(store.data.entries, collections: store.data.collections)
        let rootIDs = store.data.vivaldi.map { LibraryLogic.descendants(of: $0.root, in: store.data.collections) } ?? []
        let collectionNames = Dictionary(uniqueKeysWithValues: store.data.collections.map { ($0.id, LibraryLogic.collectionPath($0, in: store.data.collections)) })
        return VStack(alignment: .leading, spacing: 14) {
            Text("Find and Remove Entries").font(.title2.weight(.semibold))
            Text("Combine text, type, date added, folder, and collection filters. Select matching references to remove from the library; original files and folders stay on disk.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Search entries", text: $query).textFieldStyle(.roundedBorder)
                Picker("Type", selection: $kind) {
                    Text("All Types").tag("all")
                    Text("Files").tag(EntryKind.file.rawValue)
                    Text("Folders").tag(EntryKind.folder.rawValue)
                    Text("URLs").tag(EntryKind.url.rawValue)
                }.frame(width: 180)
            }
            HStack {
                Picker("Date added", selection: $dateMode) {
                    ForEach(RemovalDateMode.allCases) { Text($0.title).tag($0) }
                }.frame(width: 240)
                if dateMode != .any {
                    DatePicker(dateMode == .range ? "From" : "Date", selection: $startDate, displayedComponents: .date)
                    if dateMode == .range { DatePicker("Through", selection: $endDate, displayedComponents: .date) }
                }
                Spacer()
            }
            if dateMode == .range && Calendar.current.startOfDay(for: startDate) > Calendar.current.startOfDay(for: endDate) {
                Text("The end date must be on or after the start date.").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Choose Folder…") { chooseFolder() }
                Text(folder?.path ?? "Any folder").lineLimit(1).truncationMode(.middle).help(folder?.path ?? "No folder restriction")
                if folder != nil { Button("Clear Folder") { folder = nil } }
                Spacer()
                Toggle("Include subfolders", isOn: $includeSubfolders).disabled(folder == nil)
            }
            if folder != nil {
                Text("Matches stored file and folder paths inside this folder, excluding the folder itself and URLs. Does not follow symbolic links.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Picker("Collection", selection: $collection) {
                    Text("All Collections").tag("all")
                    Text("Unfiled").tag("unfiled")
                    ForEach(store.data.collections.sorted { LibraryLogic.collectionPath($0, in: store.data.collections).localizedStandardCompare(LibraryLogic.collectionPath($1, in: store.data.collections)) == .orderedAscending }) { item in
                        Text(LibraryLogic.collectionPath(item, in: store.data.collections)).tag(item.id.uuidString)
                    }
                }
                Toggle("Include subcollections", isOn: $includeSubcollections).disabled(UUID(uuidString: collection) == nil)
                Button("Reset Filters") {
                    query = ""; kind = "all"; dateMode = .any; folder = nil; collection = "all"
                    includeSubfolders = true; includeSubcollections = true
                }
            }
            if let error = SearchQuery(query).error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("\(matches.count) matching · \(selection.count) selected")
                Spacer()
                Button("Select All Matching") { selection = Set(matches.map(\.id)) }.disabled(matches.isEmpty)
                Button("Deselect All") { selection = [] }.disabled(selection.isEmpty)
            }
            if matches.isEmpty {
                Text("No matching entries").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(matches) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Toggle("Select", isOn: Binding(get: { selection.contains(entry.id) }, set: { enabled in
                            if enabled { selection.insert(entry.id) } else { selection.remove(entry.id) }
                        })).toggleStyle(.checkbox).accessibilityLabel("Select \(entry.name)")
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.name).font(.headline)
                                Text(entry.kind.title).foregroundStyle(.secondary)
                                if entry.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                                if entry.kind == .url, entry.collectionID.map(rootIDs.contains) == true { Text("Vivaldi sync").foregroundStyle(.secondary) }
                            }
                            Text(entry.location).lineLimit(1).truncationMode(.middle).help(entry.location)
                            Text(entry.collectionID.flatMap { collectionNames[$0] } ?? "Unfiled").foregroundStyle(.secondary)
                            Text("Added \(entry.added.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                            if !entry.tags.isEmpty { Text("Tags: " + entry.tags.joined(separator: ", ")).lineLimit(2) }
                            if !entry.notes.isEmpty { Text("Notes: " + entry.notes).lineLimit(2).help(entry.notes) }
                        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.vertical, 4)
                }
            }
            Text(message).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Remove Selected…", role: .destructive) {
                    reviewed = matches.filter { selection.contains($0.id) }
                    reviewedSyncedCount = reviewed.filter { $0.kind == .url && $0.collectionID.map(rootIDs.contains) == true }.count
                    confirming = true
                }.disabled(selection.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 900, height: 720)
        .onChange(of: filter) { _, _ in selection = []; message = "" }
        .onChange(of: store.data.collections) { _, _ in selection = []; message = "Collections changed. Review the filters and select entries again." }
        .onChange(of: store.data.entries) { _, _ in
            selection = []
            message = expectedRemovalCount > 0
                ? "Removed \(expectedRemovalCount) entries. Close this window, then choose Edit → Undo to restore them."
                : "Library changed. Select the entries again."
            expectedRemovalCount = 0
        }
        .alert("Remove \(reviewed.count) entries?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) { }
            Button("Remove Entries", role: .destructive) {
                expectedRemovalCount = reviewed.count
                if store.removeReviewedEntries(reviewed) == 0 { expectedRemovalCount = 0 }
            }
        } message: {
            Text("Original files and folders stay on disk. Close this window, then choose Edit → Undo to restore the removed entries and their metadata."
                 + (reviewedSyncedCount > 0 ? "\n\n\(reviewedSyncedCount) selected entries sync with Vivaldi. Their browser bookmarks may also be removed on the next sync, after any required review." : ""))
        }
        .alert("Find and Remove Entries", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}
