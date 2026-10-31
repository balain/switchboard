import SwiftUI

struct CollectionManager: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?
    @State private var draft: LibraryCollection?
    @State private var deleting = false
    private let symbols = ["folder.fill", "tray.fill", "briefcase.fill", "house.fill", "book.fill",
                           "graduationcap.fill", "star.fill", "heart.fill", "music.note", "photo", "globe", "archivebox.fill"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Manage Collections").font(.title2.weight(.semibold))
                Spacer()
                Button("Add Collection", systemImage: "plus") {
                    saveDraft()
                    selected = store.addCollection("New collection")
                }
            }.padding(20)
            Divider()
            HSplitView {
                List(selection: $selected) {
                    ForEach(store.data.collections) { collection in
                        Label(LibraryLogic.collectionPath(collection, in: store.data.collections), systemImage: collection.symbol)
                            .padding(.vertical, 5)
                            .tag(collection.id)
                            .listRowBackground(collection.palette?.color.opacity(0.18))
                    }
                }.frame(minWidth: 190, idealWidth: 220, maxWidth: 300)
                if let draft {
                    editor(draft).id(draft.id)
                } else {
                    ContentUnavailableView("Collections", systemImage: "folder", description: Text("Add a collection or select one to edit."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Text("Deleting a collection keeps its items and moves subcollections up one level.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { saveDraft(); dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(20)
        }
        .frame(width: 760, height: 500)
        .onAppear { selected = store.data.collections.first?.id; loadDraft() }
        .onChange(of: selected) { old, _ in
            if let draft, draft.id == old { saveDraft() }
            loadDraft()
        }
        .alert("Delete collection?", isPresented: $deleting) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let selected { store.removeCollection(selected) }
                draft = nil
                selected = store.data.collections.first?.id
                loadDraft()
            }
        } message: {
            Text("Items remain in your library. Subcollections move to the deleted collection’s parent.")
        }
    }

    private func field<Value>(_ path: WritableKeyPath<LibraryCollection, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { draft?[keyPath: path] ?? fallback }, set: { draft?[keyPath: path] = $0 })
    }

    private func editor(_ collection: LibraryCollection) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(collection.name, systemImage: collection.symbol).font(.title2)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(collection.palette?.color.opacity(0.2) ?? Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            Form {
                TextField("Name", text: field(\.name, fallback: ""))
                Picker("Icon", selection: field(\.icon, fallback: nil)) {
                    ForEach(symbols, id: \.self) { symbol in
                        Label(symbol.replacingOccurrences(of: ".fill", with: ""), systemImage: symbol).tag(Optional(symbol))
                    }
                }
                Picker("Background", selection: field(\.palette, fallback: nil)) {
                    Text("Default").tag(nil as Palette?)
                    ForEach(Palette.allCases) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                }
                Picker("Parent collection", selection: field(\.parentID, fallback: nil)) {
                    Text("Top level").tag(nil as UUID?)
                    ForEach(store.data.collections.filter {
                        !LibraryLogic.descendants(of: collection.id, in: store.data.collections).contains($0.id)
                    }) { parent in
                        Text(LibraryLogic.collectionPath(parent, in: store.data.collections)).tag(Optional(parent.id))
                    }
                }
            }
            Spacer()
            HStack {
                Button("Delete Collection…", role: .destructive) { deleting = true }
                Spacer()
                Button("Save Changes") { saveDraft() }
                    .disabled(collection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(minWidth: 390)
    }

    private func loadDraft() {
        draft = store.data.collections.first { $0.id == selected }
        if draft?.icon == nil { draft?.icon = "folder.fill" }
    }
    private func saveDraft() {
        guard var draft else { return }
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        store.updateCollection(draft)
    }
}
