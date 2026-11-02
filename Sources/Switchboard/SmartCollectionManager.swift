import SwiftUI

struct SmartCollectionManager: View {
    @ObservedObject var store: LibraryStore
    var initial: SavedFilter?
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SavedFilter(name: "New smart collection")
    @State private var baseline: SavedFilter?
    @State private var deleting = false
    private var exists: Bool { store.data.savedFilters.contains { $0.id == draft.id } }
    private var matches: Int { store.data.entries.filter { draft.criteria.matches($0, in: store.data) }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Smart Collections").font(.title2.weight(.semibold))
                Spacer()
                Button("Add", systemImage: "plus") { if save() { newDraft() } }
            }.padding(20)
            Divider()
            HSplitView {
                List(selection: Binding(get: { Optional(draft.id) }, set: { id in
                    guard id != draft.id, let next = store.data.savedFilters.first(where: { $0.id == id }), save() else { return }
                    draft = next; baseline = next
                })) {
                    ForEach(store.data.savedFilters) { item in
                        Label(item.name, systemImage: item.icon ?? "line.3.horizontal.decrease.circle")
                            .tag(item.id).listRowBackground(item.palette?.color.opacity(0.18))
                    }
                }.frame(minWidth: 180, idealWidth: 210, maxWidth: 240)
                ScrollView {
                    Form {
                        TextField("Name", text: $draft.name)
                        Picker("Icon", selection: $draft.icon) {
                            Text("Default").tag(nil as String?)
                            ForEach(["folder.badge.gearshape", "star.fill", "book.fill", "briefcase.fill", "tag.fill"], id: \.self) {
                                Label($0, systemImage: $0).tag(Optional($0))
                            }
                        }
                        Picker("Color", selection: $draft.palette) {
                            Text("Default").tag(nil as Palette?)
                            ForEach(Palette.allCases) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                        }
                        ForEach(draft.criteria.queries.indices, id: \.self) { index in
                            TextField(index == 0 ? "Search" : "Also matching", text: $draft.criteria.queries[index])
                        }
                        Button("Add Search Condition") { draft.criteria.queries.append("") }
                        Picker("Kind", selection: $draft.criteria.kind) {
                            Text("Any kind").tag(nil as EntryKind?)
                            ForEach(EntryKind.allCases) { Text($0.title).tag(Optional($0)) }
                        }
                        TextField("Extension", text: $draft.criteria.fileExtension, prompt: Text("pdf"))
                        Picker("Favorite", selection: $draft.criteria.favorite) {
                            Text("Either").tag(nil as Bool?)
                            Text("Favorite").tag(Optional(true)); Text("Not favorite").tag(Optional(false))
                        }
                        Picker("Collection", selection: $draft.criteria.collectionID) {
                            Text("Entire library").tag(nil as UUID?)
                            if let id = draft.criteria.collectionID, !store.data.collections.contains(where: { $0.id == id }) {
                                Text("Unavailable collection").tag(Optional(id))
                            }
                            ForEach(store.data.collections) { Text(LibraryLogic.collectionPath($0, in: store.data.collections)).tag(Optional($0.id)) }
                        }
                        Picker("Tags", selection: $draft.criteria.tagMatch) {
                            ForEach(TagMatch.allCases) { Text($0.title).tag($0) }
                        }
                        ForEach(store.data.tags) { tag in
                            Toggle(tag.name, isOn: Binding(get: { draft.criteria.tagIDs.contains(tag.id) }, set: { enabled in
                                if enabled { draft.criteria.tagIDs.insert(tag.id) } else { draft.criteria.tagIDs.remove(tag.id) }
                            }))
                        }
                        ForEach(Array(draft.criteria.tagIDs.subtracting(Set(store.data.tags.map(\.id)))), id: \.self) { id in
                            Button("Remove unavailable tag \(id.uuidString.prefix(8))") { draft.criteria.tagIDs.remove(id) }
                        }
                        ForEach(draft.criteria.additionalTags.indices, id: \.self) { index in
                            VStack(alignment: .leading) {
                                Text("Additional tag condition \(index + 1)").font(.headline)
                                Picker("Match", selection: $draft.criteria.additionalTags[index].match) {
                                    ForEach(TagMatch.allCases) { Text($0.title).tag($0) }
                                }
                                ForEach(store.data.tags) { tag in
                                    Toggle(tag.name, isOn: Binding(get: { draft.criteria.additionalTags[index].ids.contains(tag.id) }, set: { enabled in
                                        if enabled { draft.criteria.additionalTags[index].ids.insert(tag.id) }
                                        else { draft.criteria.additionalTags[index].ids.remove(tag.id) }
                                    }))
                                }
                                Button("Clear This Condition") { draft.criteria.additionalTags[index].ids = [] }
                            }
                        }
                        Picker("Added", selection: $draft.criteria.added) {
                            ForEach(AddedDateRule.allCases) { Text($0.title).tag($0) }
                        }
                        if draft.criteria.added == .range {
                            DatePicker("From", selection: $draft.criteria.startDate, displayedComponents: .date)
                            DatePicker("Through", selection: $draft.criteria.endDate, displayedComponents: .date)
                        }
                        Picker("Sort", selection: $draft.sort) {
                            Text("Current sort").tag(nil as EntrySort?)
                            ForEach(EntrySort.allCases) { Text($0.title).tag(Optional($0)) }
                        }
                        if draft.criteria.unavailable(in: store.data) {
                            Text("A referenced tag or collection is unavailable. This smart collection matches nothing until repaired.").foregroundStyle(.red)
                        }
                        Text("\(matches) matching entries · All conditions must match.").foregroundStyle(.secondary)
                        Text("Adding from a smart collection adds to the library. The entry appears here only if it matches these conditions.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(width: 520).padding(20)
                }.frame(minWidth: 560)
            }
            Divider()
            HStack {
                Button("Delete…", role: .destructive) { deleting = true }.disabled(!exists)
                Button("Duplicate") {
                    var copy = draft; copy.id = UUID(); copy.name = uniqueName(draft.name + " copy")
                    if store.putSavedFilter(copy) { draft = copy }
                }
                Spacer()
                Button("Save Changes") { _ = save(force: true) }
                Button("Done") { if save() { dismiss() } }.keyboardShortcut(.defaultAction)
            }.padding(20)
        }
        .frame(width: 820, height: 650)
        .onAppear { draft = initial ?? store.data.savedFilters.first ?? SavedFilter(name: uniqueName("New smart collection")); baseline = initial == nil ? draft : nil }
        .interactiveDismissDisabled()
        .alert("Delete smart collection?", isPresented: $deleting) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                store.removeSavedFilter(draft.id)
                if !store.data.savedFilters.contains(where: { $0.id == draft.id }) {
                    draft = store.data.savedFilters.first ?? SavedFilter(name: uniqueName("New smart collection")); baseline = draft
                }
            }
        } message: { Text("Entries remain in your library.") }
        .alert("Smart Collections", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
    private func save(force: Bool = false) -> Bool {
        if !force, !exists, draft == baseline { return true }
        guard store.putSavedFilter(draft) else { return false }
        baseline = draft; return true
    }
    private func uniqueName(_ base: String) -> String {
        var name = base; var number = 2
        while store.data.savedFilters.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = base + " \(number)"; number += 1
        }
        return name
    }
    private func newDraft() { draft = SavedFilter(name: uniqueName("New smart collection")); baseline = nil }
}

struct SmartCollectionMenu: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var window: LibraryWindowState
    var body: some View {
        ForEach(store.data.savedFilters) { filter in
            Button { window.scope = filter.scope; window.query = ""; window.selectedTags = [] } label: {
                Label(filter.name, systemImage: filter.icon ?? "line.3.horizontal.decrease.circle")
            }
        }
        Divider()
        Button("Save Current Filters…") { window.smartDraft = window.currentFilter(in: store.data); window.showSmartCollections = true }
        Button("Manage Smart Collections…") { window.smartDraft = nil; window.showSmartCollections = true }
    }
}
