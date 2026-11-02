import SwiftUI
import AppKit

private enum ActionKind: String, CaseIterable, Identifiable {
    case addTag, removeTag, collection, favorite
    var id: String { rawValue }
    var title: String { switch self { case .addTag: "Add tag"; case .removeTag: "Remove tag"; case .collection: "Set collection"; case .favorite: "Set favorite" } }
}
private struct RuleActionEditor: View {
    @Binding var action: OrganizationAction
    let data: LibraryData
    private var kind: Binding<ActionKind> {
        Binding(get: { switch action { case .addTag: .addTag; case .removeTag: .removeTag; case .collection: .collection; case .favorite: .favorite } }, set: {
            switch $0 { case .addTag: action = .addTag(data.tags.first?.id ?? UUID()); case .removeTag: action = .removeTag(data.tags.first?.id ?? UUID())
            case .collection: action = .collection(nil); case .favorite: action = .favorite(true) }
        })
    }
    var body: some View {
        VStack {
            Picker("Action", selection: kind) { ForEach(ActionKind.allCases) { Text($0.title).tag($0) } }
            switch action {
            case .addTag(let id), .removeTag(let id):
                Picker("Tag", selection: Binding(get: { id }, set: { action = kind.wrappedValue == .addTag ? .addTag($0) : .removeTag($0) })) {
                    if !data.tags.contains(where: { $0.id == id }) { Text("Unavailable tag").tag(id) }
                    ForEach(data.tags) { Text($0.name).tag($0.id) }
                }
            case .collection(let id):
                Picker("Collection", selection: Binding(get: { id }, set: { action = .collection($0) })) {
                    Text("Clear collection").tag(nil as UUID?)
                    if let id, !data.collections.contains(where: { $0.id == id }) { Text("Unavailable collection").tag(Optional(id)) }
                    ForEach(data.collections) { Text(LibraryLogic.collectionPath($0, in: data.collections)).tag(Optional($0.id)) }
                }
            case .favorite(let enabled): Toggle("Favorite", isOn: Binding(get: { enabled }, set: { action = .favorite($0) }))
            }
        }
    }
}

struct RuleManager: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = OrganizationRule(name: "New rule")
    @State private var baseline: OrganizationRule?
    @State private var previewing = false
    @State private var deleting = false
    private var exists: Bool { store.data.rules.contains { $0.id == draft.id } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Organization Rules").font(.title2.weight(.semibold)); Spacer()
                Button("Add Rule") { if save() { draft = OrganizationRule(name: unique("New rule")); baseline = nil } }
            }.padding(20)
            Divider()
            HSplitView {
                List(selection: Binding(get: { Optional(draft.id) }, set: { id in
                    guard let item = store.data.rules.first(where: { $0.id == id }), item.id != draft.id, save() else { return }
                    draft = item; baseline = item
                })) {
                    ForEach(store.data.rules) { rule in
                        Label(rule.name, systemImage: rule.enabled ? "checkmark.circle" : "pause.circle").tag(rule.id)
                    }
                }.frame(minWidth: 180, idealWidth: 210, maxWidth: 240)
                ScrollView {
                    Form {
                        TextField("Name", text: $draft.name)
                        Toggle("Enabled", isOn: $draft.enabled)
                        Picker("Run", selection: $draft.trigger) { ForEach(RuleTrigger.allCases) { Text($0.title).tag($0) } }
                        TextField("Name contains", text: $draft.nameContains)
                        TextField("Path/URL contains", text: $draft.locationContains)
                        TextField("Metadata contains", text: Binding(get: { draft.criteria.queries.first ?? "" }, set: { value in if draft.criteria.queries.isEmpty { draft.criteria.queries = [value] } else { draft.criteria.queries[0] = value } }))
                        Picker("Kind", selection: $draft.criteria.kind) {
                            Text("Any").tag(nil as EntryKind?)
                            ForEach(EntryKind.allCases) { Text($0.title).tag(Optional($0)) }
                        }
                        TextField("Extension", text: $draft.criteria.fileExtension)
                        TextField("Exact host", text: $draft.host, prompt: Text("example.com"))
                        HStack {
                            TextField("Folder path", text: $draft.folder)
                            Button("Choose…") {
                                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                                if panel.runModal() == .OK { draft.folder = panel.url?.path ?? "" }
                            }
                        }
                        Picker("Favorite", selection: $draft.criteria.favorite) {
                            Text("Either").tag(nil as Bool?); Text("Favorite").tag(Optional(true)); Text("Not favorite").tag(Optional(false))
                        }
                        Picker("Tag match", selection: $draft.criteria.tagMatch) { ForEach(TagMatch.allCases) { Text($0.title).tag($0) } }
                        ForEach(store.data.tags) { tag in
                            Toggle(tag.name, isOn: Binding(get: { draft.criteria.tagIDs.contains(tag.id) }, set: { value in
                                if value { draft.criteria.tagIDs.insert(tag.id) } else { draft.criteria.tagIDs.remove(tag.id) }
                            }))
                        }
                        if draft.criteria.unavailable(in: store.data) {
                            Button("Clear Unavailable Conditions") {
                                draft.criteria.tagIDs.formIntersection(Set(store.data.tags.map(\.id)))
                                draft.criteria.collectionID = nil; draft.criteria.additionalTags = []
                            }
                        }
                        Divider()
                        ForEach(draft.actions.indices, id: \.self) { index in
                            RuleActionEditor(action: $draft.actions[index], data: store.data)
                        }
                        HStack {
                            Button("Add Action") { draft.actions.append(.favorite(true)) }
                            Button("Remove Last Action") { if !draft.actions.isEmpty { draft.actions.removeLast() } }.disabled(draft.actions.isEmpty)
                        }
                        Toggle("Stop after this rule matches", isOn: $draft.stopProcessing)
                        if let problem = draft.validation(in: store.data) { Text(problem).foregroundStyle(.red).font(.caption) }
                        Text("All conditions must match. Blank conditions match every entry. Rules run in list order; later assignments win unless processing stops.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(width: 520).padding(20)
                }.frame(minWidth: 560)
            }
            Divider()
            HStack {
                Button("Delete…", role: .destructive) { deleting = true }.disabled(!exists)
                Button("Duplicate") {
                    var copy = draft; copy.id = UUID(); copy.enabled = false; copy.name = unique(draft.name + " copy")
                    if store.putRule(copy) { draft = copy; baseline = copy }
                }
                Button("↑") { if save() { store.moveRule(draft.id, by: -1) } }.help("Move rule earlier")
                Button("↓") { if save() { store.moveRule(draft.id, by: 1) } }.help("Move rule later")
                Spacer()
                Button("Preview…") { if save() { previewing = true } }
                Button("Save") { _ = save(force: true) }
                Button("Done") { if save() { dismiss() } }.keyboardShortcut(.defaultAction)
            }.padding(20)
        }.frame(width: 860, height: 680)
        .onAppear { draft = store.data.rules.first ?? OrganizationRule(name: unique("New rule")); baseline = draft }
        .sheet(isPresented: $previewing) { RulePreviewPanel(store: store, ids: nil) }
        .alert("Delete this rule?", isPresented: $deleting) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                store.removeRule(draft.id)
                if !store.data.rules.contains(where: { $0.id == draft.id }) { draft = store.data.rules.first ?? OrganizationRule(name: unique("New rule")); baseline = draft }
            }
        }
        .alert("Rules", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
    private func save(force: Bool = false) -> Bool {
        if !force, !exists, draft == baseline { return true }
        guard store.putRule(draft) else { return false }; baseline = draft; return true
    }
    private func unique(_ base: String) -> String {
        var name = base; var suffix = 2
        while store.data.rules.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { name = base + " \(suffix)"; suffix += 1 }
        return name
    }
}

struct RulePreviewPanel: View {
    @ObservedObject var store: LibraryStore
    let ids: Set<UUID>?
    @Environment(\.dismiss) private var dismiss
    @State private var preview: RulePreview?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preview Rules").font(.title2.weight(.semibold))
            Text("Nothing changes until you apply this preview. Only enabled rules with a manual trigger participate.").font(.caption).foregroundStyle(.secondary)
            if let preview {
                Text("\(preview.changed) entries would change.").font(.headline)
                List {
                    ForEach(Array(zip(preview.expected, preview.updated)), id: \.0.id) { before, after in
                        if before != after {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(before.name).font(.headline)
                                Text("Tags: \(before.tags.joined(separator: ", ")) → \(after.tags.joined(separator: ", "))")
                                Text("Favorite: \(String(before.favorite)) → \(String(after.favorite))")
                                Text("Collection: \(collection(before.collectionID)) → \(collection(after.collectionID))")
                                Text("Rules: \((preview.reasons[before.id] ?? []).joined(separator: " → "))").foregroundStyle(.secondary)
                            }.font(.caption)
                        }
                    }
                }
                if !preview.conflicts.isEmpty {
                    DisclosureGroup("\(preview.conflicts.count) overriding assignments") {
                        ScrollView { Text(preview.conflicts.joined(separator: "\n")).font(.caption) }.frame(maxHeight: 100)
                    }
                }
            }
            HStack {
                Button("Refresh Preview") { refresh() }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply Changes") { if let preview, store.applyRulePreview(preview) > 0 { dismiss() } }
                    .disabled(preview?.changed == nil || preview?.changed == 0).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 760, height: 540).onAppear { refresh() }
        .alert("Rules", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }
    private func refresh() { preview = RuleEngine.preview(entries: store.data.entries.filter { ids == nil || ids!.contains($0.id) }, data: store.data, event: .manual) }
    private func collection(_ id: UUID?) -> String { store.data.collections.first { $0.id == id }?.name ?? "None" }
}
