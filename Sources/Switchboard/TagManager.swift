import SwiftUI

struct TagManager: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?
    @State private var draft: LibraryTag?
    @State private var deleting = false
    @State private var validation: String?
    private let symbols = ["tag.fill", "folder.fill", "tray.fill", "briefcase.fill", "house.fill", "book.fill",
                           "graduationcap.fill", "star.fill", "heart.fill", "music.note", "photo", "globe", "archivebox.fill"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Manage Tags").font(.title2.weight(.semibold))
                Spacer()
                Button("Add Tag", systemImage: "plus") {
                    guard saveDraft() else { return }
                    var name = "New tag"
                    var number = 2
                    while store.data.tags.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                        name = "New tag \(number)"; number += 1
                    }
                    selected = store.addTag(name)
                }
            }.padding(20)
            Divider()
            HSplitView {
                List(selection: Binding(get: { selected }, set: { value in
                    if saveDraft() { selected = value }
                })) {
                    ForEach(store.data.tags) { tag in
                        Label(tag.name, systemImage: tag.symbol)
                            .padding(.vertical, 5)
                            .tag(tag.id)
                            .listRowBackground(tag.palette?.color.opacity(0.18))
                    }
                }.frame(minWidth: 190, idealWidth: 220, maxWidth: 300)
                if let draft {
                    editor(draft).id(draft.id)
                } else {
                    ContentUnavailableView("Tags", systemImage: "tag", description: Text("Add a tag or select one to edit."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Text("Deleting a tag removes it from entries and keeps the entries in your library.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { if saveDraft() { dismiss() } }.keyboardShortcut(.defaultAction)
            }.padding(20)
        }
        .frame(width: 760, height: 500)
        .onAppear { selected = store.data.tags.first?.id; loadDraft() }
        .onChange(of: selected) { _, _ in loadDraft() }
        .alert("Delete tag?", isPresented: $deleting) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let selected { store.removeTag(selected) }
                draft = nil
                selected = store.data.tags.first?.id
                loadDraft()
            }
        } message: {
            Text("This tag will be removed from every entry. Items remain in your library.")
        }
    }

    private func field<Value>(_ path: WritableKeyPath<LibraryTag, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { draft?[keyPath: path] ?? fallback }, set: { draft?[keyPath: path] = $0 })
    }

    private func editor(_ tag: LibraryTag) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(tag.name, systemImage: tag.symbol).font(.title2)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(tag.palette?.color.opacity(0.2) ?? Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
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
            }
            if let validation { Text(validation).font(.caption).foregroundStyle(.red) }
            Spacer()
            HStack {
                Button("Delete Tag…", role: .destructive) { deleting = true }
                Spacer()
                Button("Save Changes") { saveDraft() }
                    .disabled(tag.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(minWidth: 390)
    }

    private func loadDraft() {
        validation = nil
        draft = store.data.tags.first { $0.id == selected }
        if draft?.icon == nil { draft?.icon = "tag.fill" }
    }
    @discardableResult
    private func saveDraft() -> Bool {
        guard var draft else { return true }
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.updateTag(draft) else {
            validation = "Enter a unique tag name without commas."
            return false
        }
        validation = nil
        return true
    }
}
