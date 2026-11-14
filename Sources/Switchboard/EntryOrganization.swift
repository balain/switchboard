import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let switchboardEntries = UTType(exportedAs: "app.switchboard.entry-selection")
}

/// Carries references only; a drop never imports entries or touches original files.
struct EntryDrag: Codable, Transferable {
    let ids: Set<UUID>
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .switchboardEntries)
    }
}

extension LibraryStore {
    @discardableResult func organizeDrop(_ payloads: [EntryDrag], action: BulkAction) -> Bool {
        let ids = payloads.reduce(into: Set<UUID>()) { $0.formUnion($1.ids) }
        guard !ids.isEmpty, ids.isSubset(of: Set(data.entries.map(\.id))) else { return false }
        switch action {
        case .collection(let id):
            guard id == nil || data.collections.contains(where: { $0.id == id }) else { return false }
        case .addTag(let id):
            guard data.tags.contains(where: { $0.id == id }) else { return false }
        default: return false
        }
        return applyBulk(action, to: ids) > 0
    }
}

struct EntryDropTarget: ViewModifier {
    @ObservedObject var store: LibraryStore
    let action: BulkAction
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .background(targeted ? Color.accentColor.opacity(0.18) : Color.clear)
            .dropDestination(for: EntryDrag.self) { payloads, _ in
                store.organizeDrop(payloads, action: action)
            } isTargeted: { targeted = $0 }
    }
}

struct QuickTagEditor: View {
    @ObservedObject var store: LibraryStore
    let ids: Set<UUID>
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var entries: [LibraryEntry] { store.data.entries.filter { ids.contains($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tags for \(entries.count) selected entries").font(.title2)
            Text("Changes save immediately and support Undo. Adding a mixed tag applies it to every selected entry.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Find tags", text: $query).textFieldStyle(.roundedBorder)
            List(store.data.tags.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { tag in
                let count = entries.filter { $0.tags.contains { $0.caseInsensitiveCompare(tag.name) == .orderedSame } }.count
                HStack {
                    Toggle(isOn: Binding(get: { !entries.isEmpty && count == entries.count }, set: { enabled in
                        store.applyBulk(enabled ? .addTag(tag.id) : .removeTag(tag.id), to: ids)
                    })) { Label(tag.name, systemImage: tag.symbol) }.toggleStyle(.checkbox)
                    Spacer()
                    if count > 0 && count < entries.count {
                        Text("Mixed").foregroundStyle(.secondary)
                        Button("Remove from All") { store.applyBulk(.removeTag(tag.id), to: ids) }
                    }
                }.disabled(entries.isEmpty)
            }
            if store.data.tags.isEmpty { Text("Create tags in File → Manage Tags.").foregroundStyle(.secondary) }
            if let error = store.error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 470, height: 400)
    }
}
