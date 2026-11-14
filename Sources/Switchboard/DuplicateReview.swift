import SwiftUI

struct DuplicateReview: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [DuplicateGroup] = []
    @State private var selection: Set<UUID> = []
    @State private var syncedIDs: Set<UUID> = []
    @State private var collectionNames: [UUID: String] = [:]
    @State private var message = ""
    @State private var confirming = false
    @State private var removalGroups: [DuplicateGroup] = []
    @State private var removalIDs: Set<UUID> = []
    @State private var expectedRemovalCount = 0
    @State private var showEntryRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Duplicate Checker").font(.title2.weight(.semibold))
                Spacer()
                Button("Find Other Entries…") { showEntryRemoval = true }
                Button("Scan Again") { scan() }
            }
            Text("Review entries with the same web address or stored file/folder path. Query strings and fragments stay distinct. This scan does not contact websites or open files.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("\(groups.count) groups · \(groups.reduce(0) { $0 + $1.entries.count - 1 }) extra copies")
                Spacer()
                Button("Select Extra Copies") { selection = DuplicateChecker.extraCopies(in: groups) }.disabled(groups.isEmpty)
                Button("Deselect All") { selection = [] }.disabled(selection.isEmpty)
            }
            Text("Select Extra Copies keeps one per group, preferring Vivaldi-synced entries, then entries with favorites, notes, or tags. Use Keep This Copy to choose a different survivor.")
                .font(.caption).foregroundStyle(.secondary)
            if groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.largeTitle)
                    Text("No duplicate references found")
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups) { group in
                        let selectedCount = group.entries.reduce(0) { $0 + (selection.contains($1.id) ? 1 : 0) }
                        Section {
                            ForEach(group.entries) { entry in
                                HStack(alignment: .top, spacing: 12) {
                                    Toggle("Remove", isOn: Binding(get: { selection.contains(entry.id) }, set: { selected in
                                        if selected { selection.insert(entry.id) } else { selection.remove(entry.id) }
                                    }))
                                    .toggleStyle(.checkbox)
                                    .accessibilityLabel("Remove \(entry.name)")
                                    .disabled(!selection.contains(entry.id) && selectedCount == group.entries.count - 1)
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(entry.name).font(.headline)
                                            if entry.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                                            if syncedIDs.contains(entry.id) { Text("Vivaldi sync").foregroundStyle(.secondary) }
                                        }
                                        Text(entry.collectionID.flatMap { collectionNames[$0] } ?? "Unfiled").foregroundStyle(.secondary)
                                        if !entry.tags.isEmpty { Text("Tags: " + entry.tags.joined(separator: ", ")).lineLimit(2) }
                                        if !entry.notes.isEmpty { Text("Notes: " + entry.notes).lineLimit(2).help(entry.notes) }
                                        Text("Added " + entry.added.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.tertiary)
                                    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                                    Button("Keep This Copy") {
                                        selection.formUnion(group.entries.map(\.id)); selection.remove(entry.id)
                                    }.buttonStyle(.borderless).accessibilityLabel("Keep \(entry.name)")
                                }.padding(.vertical, 4).accessibilityElement(children: .contain)
                            }
                        } header: {
                            Text(group.entries[0].location).textCase(nil).lineLimit(2).help(group.entries[0].location)
                        }
                    }
                }
            }
            Text(message).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Remove Selected…", role: .destructive) {
                    removalGroups = groups; removalIDs = selection; confirming = true
                }.disabled(selection.isEmpty)
                Text("\(selection.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 900, height: 650)
        .onAppear { scan() }
        .sheet(isPresented: $showEntryRemoval) { EntryRemovalReview(store: store) }
        .onChange(of: store.data.entries) { _, _ in
            let status = expectedRemovalCount > 0
                ? "Removed \(expectedRemovalCount) duplicate copies. Undo is available in the Edit menu."
                : "Library changed. Results refreshed; select the copies to remove."
            expectedRemovalCount = 0
            scan(message: status)
        }
        .onChange(of: store.data.collections) { _, _ in scan() }
        .alert("Remove \(removalIDs.count) duplicate copies?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) { }
            Button("Remove Copies", role: .destructive) {
                expectedRemovalCount = removalIDs.count
                let count = store.removeDuplicates(removalIDs, reviewed: removalGroups)
                if count == 0 { expectedRemovalCount = 0 }
            }
        } message: {
            let syncedCount = removalIDs.intersection(syncedIDs).count
            Text("At least one copy per group is kept. Removed copies’ notes, tags, and favorites are not merged. Original files stay on disk. One Undo restores the removed entries and their metadata."
                 + (syncedCount > 0 ? "\n\n\(syncedCount) selected copies sync with Vivaldi. Their browser bookmarks may also be removed on the next sync, after any required review." : ""))
        }
        .alert("Duplicate Checker", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    private func scan(message: String = "") {
        let scope = store.data.vivaldi.map { LibraryLogic.descendants(of: $0.root, in: store.data.collections) } ?? []
        syncedIDs = Set(store.data.entries.filter { $0.kind == .url && $0.collectionID.map(scope.contains) == true }.map(\.id))
        collectionNames = Dictionary(uniqueKeysWithValues: store.data.collections.map { ($0.id, LibraryLogic.collectionPath($0, in: store.data.collections)) })
        groups = DuplicateChecker.groups(in: store.data.entries, syncedIDs: syncedIDs)
        selection = []
        self.message = message
    }
}
