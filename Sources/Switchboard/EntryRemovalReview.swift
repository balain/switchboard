import SwiftUI

struct EntryRemovalFilter {
    var query = ""
    var kind: EntryKind?
    func matching(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        entries.filter { (kind == nil || $0.kind == kind) && LibraryLogic.matches($0, query: query) }
            .sorted { a, b in
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
    @State private var selection: Set<UUID> = []
    @State private var reviewed: [LibraryEntry] = []
    @State private var reviewedSyncedCount = 0
    @State private var confirming = false
    @State private var expectedRemovalCount = 0
    @State private var message = ""

    var body: some View {
        let matches = EntryRemovalFilter(query: query, kind: EntryKind(rawValue: kind)).matching(store.data.entries)
        let rootIDs = store.data.vivaldi.map { LibraryLogic.descendants(of: $0.root, in: store.data.collections) } ?? []
        let collectionNames = Dictionary(uniqueKeysWithValues: store.data.collections.map { ($0.id, LibraryLogic.collectionPath($0, in: store.data.collections)) })
        return VStack(alignment: .leading, spacing: 14) {
            Text("Find and Remove Entries").font(.title2.weight(.semibold))
            Text("Search the whole library by name, location, notes, or tags. Choose a type to narrow the results, or leave the search empty to show every entry of that type.")
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
        }.padding(24).frame(width: 900, height: 650)
        .onChange(of: query) { _, _ in selection = []; message = "" }
        .onChange(of: kind) { _, _ in selection = []; message = "" }
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
