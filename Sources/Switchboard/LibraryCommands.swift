import SwiftUI

@MainActor
final class LibraryWindowState: ObservableObject {
    let windowID = UUID()
    private let defaults: UserDefaults
    @Published var scope: String { didSet { defaults.set(scope, forKey: "activeScope") } }
    @Published var query: String { didSet { defaults.set(query, forKey: "activeSearch") } }
    @Published var showInspector: Bool { didSet { defaults.set(showInspector, forKey: "showInspector") } }
    @Published var selection: Set<UUID> {
        didSet { defaults.set(selection.map(\.uuidString).sorted(), forKey: "selectedEntries") }
    }
    @Published var columnVisibility: NavigationSplitViewVisibility {
        didSet {
            let value = columnVisibility == .detailOnly ? "detailOnly" :
                columnVisibility == .all ? "all" : columnVisibility == .doubleColumn ? "doubleColumn" : "automatic"
            defaults.set(value, forKey: "sidebarVisibility")
        }
    }
    @Published var selectedTags: Set<UUID> {
        didSet { defaults.set(selectedTags.map(\.uuidString).sorted(), forKey: "selectedTags") }
    }
    @Published var tagMatch: TagMatch {
        didSet { defaults.set(tagMatch.rawValue, forKey: "tagMatch") }
    }
    private var revealedEntry: UUID?
    private var revealScope: String?
    func reveal(_ entry: LibraryEntry) {
        revealedEntry = entry.id
        revealScope = entry.collectionID?.uuidString ?? "all"
        scope = revealScope ?? "all"; query = ""; selectedTags = []
        selection = [entry.id]; showInspector = true
    }
    func clearSelectionForFilterChange() {
        if let revealedEntry, selection == [revealedEntry], scope == revealScope, query.isEmpty, selectedTags.isEmpty { return }
        revealedEntry = nil; revealScope = nil; selection = []
    }
    @Published var showTags = false
    @Published var showURL = false
    @Published var showCollections = false
    @Published var showSettings = false
    @Published var searchPresented = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedTags = Set((defaults.stringArray(forKey: "selectedTags") ?? []).compactMap(UUID.init(uuidString:)))
        tagMatch = TagMatch(rawValue: defaults.string(forKey: "tagMatch") ?? "") ?? .any
        scope = defaults.string(forKey: "activeScope") ?? "all"
        query = defaults.string(forKey: "activeSearch") ?? ""
        showInspector = defaults.object(forKey: "showInspector") as? Bool ?? true
        selection = Set((defaults.stringArray(forKey: "selectedEntries") ?? []).compactMap(UUID.init(uuidString:)))
        switch defaults.string(forKey: "sidebarVisibility") {
        case "detailOnly": columnVisibility = .detailOnly
        case "all": columnVisibility = .all
        case "doubleColumn": columnVisibility = .doubleColumn
        default: columnVisibility = .automatic
        }
    }

    func validate(in data: LibraryData) {
        let standardScopes = ["all", "favorites"] + EntryKind.allCases.map(\.rawValue)
        if !standardScopes.contains(scope), !data.collections.contains(where: { $0.id.uuidString == scope }) { scope = "all" }
        selectedTags.formIntersection(Set(data.tags.map(\.id)))
        selection.formIntersection(Set(data.entries.map(\.id)))
    }
}

struct LibraryCommands: Commands {
    @ObservedObject var store: LibraryStore
    @ObservedObject var launcher: QuickLauncherCoordinator
    @Environment(\.openWindow) private var openWindow
    @FocusedObject private var window: LibraryWindowState?
    @AppStorage("minimalView") private var minimal = false
    @AppStorage("minimalIconBloom") private var minimalIconBloom = true
    @AppStorage("hierarchicalCollections") private var hierarchical = false
    @AppStorage("showCollectionNames") private var showCollectionNames = true
    @AppStorage("singleClickOpen") private var singleClick = false

    private func binding<Value>(_ path: ReferenceWritableKeyPath<LibraryWindowState, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { window?[keyPath: path] ?? fallback }, set: { window?[keyPath: path] = $0 })
    }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Quick Launcher Settings…") { openWindow(id: "launcher-settings") }.keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("Quick Launcher…") { launcher.toggle() }
            Divider()
            Button("Add Files and Folders…") {
                store.importFiles(collectionID: window.flatMap { UUID(uuidString: $0.scope) })
            }.keyboardShortcut("o").disabled(window == nil)
            Button("Add URL…") { window?.showURL = true }.disabled(window == nil)
            Divider()
            Button("Manage Collections…") { window?.showCollections = true }.disabled(window == nil)
            Button("Manage Tags…") { window?.showTags = true }.disabled(window == nil)
        }
        CommandGroup(after: .toolbar) {
            Toggle("Minimal", isOn: $minimal)
            Toggle("Minimal Icon Bloom", isOn: $minimalIconBloom)
            Toggle("Show Details Panel", isOn: binding(\.showInspector, fallback: true)).disabled(window == nil)
            Menu("Display Format") {
                Picker("Display Format", selection: Binding(get: { store.data.view }, set: { store.data.view = $0; store.save() })) {
                    ForEach(LibraryView.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.inline)
            }
            Button("Configure Current View…") { window?.showSettings = true }.disabled(window == nil)
            Menu("Appearance") {
                Picker("Appearance", selection: Binding(get: { store.data.appearance }, set: { store.data.appearance = $0; store.save() })) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }.pickerStyle(.inline)
            }
            Menu("Filter") {
                Picker("Show", selection: binding(\.scope, fallback: "all")) {
                    Text("All Entries").tag("all")
                    Text("Favorites").tag("favorites")
                    ForEach(EntryKind.allCases) { Text($0 == .url ? "URLs" : $0.title + "s").tag($0.rawValue) }
                    Divider()
                    ForEach(store.data.collections) {
                        Text(LibraryLogic.collectionPath($0, in: store.data.collections)).tag($0.id.uuidString)
                    }
                }.pickerStyle(.inline)
            }.disabled(window == nil)
            Menu("Collections") {
                if let window { CollectionFilterMenu(store: store, window: window) }
            }.disabled(window == nil)
            Menu("Tags") {
                if let window { TagFilterMenu(store: store, window: window) }
            }.disabled(window == nil)
            Menu("Sort By") {
                Picker("Sort By", selection: Binding(get: { store.data.sort }, set: { store.data.sort = $0; store.save() })) {
                    ForEach(EntrySort.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.inline)
            }
            Toggle("Hierarchical Collections", isOn: $hierarchical)
            Toggle("Show Collection Names", isOn: $showCollectionNames)
            Menu("Open Items With") {
                Picker("Open Items With", selection: $singleClick) {
                    Text("Single Click").tag(true)
                    Text("Double Click").tag(false)
                }.pickerStyle(.inline)
            }
        }
        CommandGroup(after: .textEditing) {
            Button("Search Library…") {
                minimal = false
                window?.searchPresented = true
            }.keyboardShortcut("f").disabled(window == nil)
            Button("Clear Search") { window?.query = "" }.disabled(window?.query.isEmpty != false)
        }
    }
}
