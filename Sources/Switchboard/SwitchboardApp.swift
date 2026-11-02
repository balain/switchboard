import SwiftUI
import AppKit

@main
struct SwitchboardApp: App {
    @NSApplicationDelegateAdaptor(LauncherAppDelegate.self) private var appDelegate
    @StateObject private var store: LibraryStore
    @StateObject private var launcher: QuickLauncherCoordinator
    init() {
        let store = LibraryStore()
        _store = StateObject(wrappedValue: store)
        _launcher = StateObject(wrappedValue: QuickLauncherCoordinator(store: store))
    }
    var body: some Scene {
        WindowGroup(id: "library") {
            ContentView(store: store, launcher: launcher)
                .frame(minWidth: 900, minHeight: 320.0 / 3.0)
                .preferredColorScheme(store.data.appearance == "system" ? nil : store.data.appearance == "dark" ? .dark : .light)
        }
        .defaultSize(width: 1250, height: 790)
        .commands { SidebarCommands(); LibraryCommands(store: store, launcher: launcher) }
        Window("Quick Launcher Settings", id: "launcher-settings") { LauncherSettings(launcher: launcher) }
            .windowResizability(.contentSize)
    }
}

extension Palette {
    var color: Color {
        switch self { case .ocean: .blue; case .violet: .purple; case .forest: .green; case .amber: .orange; case .graphite: .gray }
    }
}
extension ViewConfiguration {
    var font: Font { fontName == "System" ? .system(size: fontSize) : .custom(fontName, size: fontSize) }
}

struct ContentView: View {
    @ObservedObject var store: LibraryStore
    let launcher: QuickLauncherCoordinator
    @AppStorage("minimalView") private var minimalView = false
    @AppStorage("minimalIconBloom") private var minimalIconBloom = true
    @StateObject private var window = LibraryWindowState()
    @AppStorage("hierarchicalCollections") private var hierarchical = false
    @AppStorage("showCollectionNames") private var showCollectionNames = true
    @AppStorage("singleClickOpen") private var singleClick = false
    @AppStorage("contentSearchMode") private var contentMode: ContentSearchMode = .metadata
    @StateObject private var contentSearch = ContentSearchModel()
    @State private var contentCacheVersion = 0
    @State private var filterDate = Date()
    @State private var selectionAnchor: UUID?
    private var removeIDs: Set<UUID> {
        get { window.removeSelection }
        nonmutating set { window.removeSelection = newValue }
    }
    @State private var dropTarget = false
    var collectionID: UUID? { UUID(uuidString: window.scope) }
    var smartCollection: SavedFilter? { store.data.savedFilters.first { $0.scope == window.scope } }
    var title: String {
        if let smartCollection { return smartCollection.name }
        if let collectionID { return store.data.collections.first { $0.id == collectionID }?.name ?? "Collection" }
        switch window.scope { case "favorites": return "Favorites"; case "file": return "Files"; case "folder": return "Folders"; case "url": return "URLs"; default: return "All entries" }
    }
    var currentCollection: LibraryCollection? { store.data.collections.first { $0.id == collectionID } }
    var selectedTagNames: Set<String> {
        Set(store.data.tags.filter { window.selectedTags.contains($0.id) }.map(\.name))
    }
    var hasAdditionalFilters: Bool { !window.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !window.selectedTags.isEmpty }
    var searching: Bool { smartCollection != nil || hasAdditionalFilters }
    var contentQueryActive: Bool { !window.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && contentMode != .metadata }
    var contentCandidates: [LibraryEntry] {
        LibraryLogic.scopedEntries(smartCollection.map { saved in store.data.entries.filter { saved.criteria.matches($0, in: store.data, now: filterDate) } } ?? store.data.entries,
                                   collections: store.data.collections, scope: window.scope,
                                   hierarchical: smartCollection == nil && hierarchical && !contentQueryActive,
                                   query: contentQueryActive ? "" : window.query, sort: store.data.sort,
                                   tags: selectedTagNames, tagMatch: window.tagMatch)
    }
    var contentRequest: ContentSearchRequest {
        ContentSearchRequest(entries: contentCandidates, libraryIDs: Set(store.data.entries.map(\.id)), query: window.query.trimmingCharacters(in: .whitespacesAndNewlines), mode: contentMode, cacheVersion: contentCacheVersion)
    }
    func contentMatch(for entry: LibraryEntry) -> ContentMatch? {
        guard contentQueryActive, contentSearch.request == contentRequest else { return nil }
        return contentSearch.matches[entry.id]
    }
    var entries: [LibraryEntry] {
        guard contentQueryActive else { return contentCandidates }
        let candidates = contentCandidates
        let matches = contentSearch.request == contentRequest ? contentSearch.matches : [:]
        return candidates.filter { entry in
            matches[entry.id]?.state == .matched || (contentMode == .both && LibraryLogic.matches(entry, query: window.query))
        }
    }
    var searchMatches: [LibraryEntry] { entries }
    var childCollections: [LibraryCollection] {
        guard hierarchical, !searching, window.scope == "all" || collectionID != nil else { return [] }
        return store.data.collections.filter { $0.parentID == collectionID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $window.columnVisibility) { sidebar } detail: { detail }
        .toolbar(minimalView ? .hidden : .automatic, for: .windowToolbar)
        .focusedSceneObject(window)
        .background(LauncherWindowBridge(launcher: launcher, state: window))
        .tint(store.configuration.palette.color)
        .task(id: contentRequest) { await contentSearch.run(contentRequest) }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Switchboard.libraryReplaced"))) { _ in
            Task { await contentSearch.clearCache(); contentCacheVersion += 1 }
        }
        .onChange(of: store.data.view) { _, _ in store.save() }
        .onChange(of: store.data.sort) { _, _ in store.save() }
        .onChange(of: window.scope) { _, _ in
            window.clearSelectionForFilterChange(); selectionAnchor = nil
            if let sort = smartCollection?.sort { store.data.sort = sort }
        }
        .onAppear { window.validate(in: store.data); if let sort = smartCollection?.sort { store.data.sort = sort } }
        .onChange(of: store.data.savedFilters) { _, _ in window.validate(in: store.data) }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in filterDate = Date() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in filterDate = Date() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in filterDate = Date(); store.backupIfNeeded(); if contentQueryActive { contentCacheVersion += 1 } }
        .sheet(isPresented: $window.showSmartCollections) { SmartCollectionManager(store: store, initial: window.smartDraft) }
        .onChange(of: store.data.tags) { _, _ in window.validate(in: store.data) }
        .onChange(of: window.selectedTags) { _, _ in window.clearSelectionForFilterChange(); selectionAnchor = nil }
        .onChange(of: window.tagMatch) { _, _ in window.selection.removeAll(); selectionAnchor = nil }
        .onChange(of: store.data.collections) { _, _ in window.validate(in: store.data) }
        .onChange(of: store.data.entries.map(\.id)) { _, _ in window.validate(in: store.data) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.save() }
        .sheet(isPresented: $window.showHealth) { HealthReport(store: store) }
        .sheet(isPresented: $window.showLibraryTransfer) { LibraryTransferPanel(store: store) }
        .onReceive(NotificationCenter.default.publisher(for: .libraryReplaced)) { _ in window.validate(in: store.data) }
        .sheet(isPresented: $window.showURL) { AddURLSheet(store: store, collectionID: collectionID) { window.selection = [$0] } }
        .sheet(isPresented: $window.showCollections) { CollectionManager(store: store) }
        .sheet(isPresented: $window.showTags) { TagManager(store: store) }
        .sheet(isPresented: $window.showSettings) {
            VStack {
                ScrollView { ViewSettings(store: store) }
                Button("Done") { window.showSettings = false }.keyboardShortcut(.defaultAction).padding()
            }.frame(height: 650)
        }
        .alert("Remove from library?", isPresented: Binding(get: { !removeIDs.isEmpty }, set: { if !$0 { removeIDs = [] } })) {
            Button("Cancel", role: .cancel) { removeIDs = [] }
            Button("Remove", role: .destructive) { if store.remove(removeIDs) > 0 { window.validate(in: store.data) }; removeIDs = [] }
        } message: { Text("Original files and folders will remain on disk.") }
        .alert("Switchboard", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
    private var sidebar: some View {
            List(selection: $window.scope) {
                Section("LIBRARY") {
                    sidebarRow("All entries", icon: "square.stack.3d.up", value: "all", count: store.data.entries.count)
                    sidebarRow("Favorites", icon: "star", value: "favorites", count: store.data.entries.filter(\.favorite).count)
                }
                Section("KINDS") {
                    ForEach(EntryKind.allCases) { kind in
                        sidebarRow(kind == .url ? "URLs" : kind.title + "s", icon: kind.icon, value: kind.rawValue,
                                   count: store.data.entries.filter { $0.kind == kind }.count)
                    }
                }
                Section {
                    ForEach(store.data.collections) { collection in
                        sidebarRow(LibraryLogic.collectionPath(collection, in: store.data.collections), icon: collection.symbol,
                                   value: collection.id.uuidString, count: store.data.entries.filter { $0.collectionID == collection.id }.count)
                            .listRowBackground(collection.palette?.color.opacity(0.18))
                    }
                    Button { window.showCollections = true } label: { Label("Manage collections…", systemImage: "folder.badge.gearshape") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                } header: { Text("COLLECTIONS") }
                Section("SMART COLLECTIONS") {
                    ForEach(store.data.savedFilters) { filter in
                        Label(filter.name, systemImage: filter.icon ?? "line.3.horizontal.decrease.circle")
                            .tag(filter.scope).listRowBackground(filter.palette?.color.opacity(0.18))
                    }
                    Menu("Smart collections…") { SmartCollectionMenu(store: store, window: window) }
                }
                Section {
                    ForEach(store.data.tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { tag in
                        Toggle(isOn: Binding(get: { window.selectedTags.contains(tag.id) }, set: { enabled in
                            if enabled { window.selectedTags.insert(tag.id) } else { window.selectedTags.remove(tag.id) }
                        })) {
                            HStack {
                                Label(tag.name, systemImage: tag.symbol)
                                Spacer()
                                Text("\(store.data.entries.filter { $0.tags.contains(tag.name) }.count)")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }.toggleStyle(.checkbox)
                            .listRowBackground(tag.palette?.color.opacity(0.18))
                    }
                    if !window.selectedTags.isEmpty {
                        Picker("Match", selection: $window.tagMatch) {
                            ForEach(TagMatch.allCases) { Text($0.title).tag($0) }
                        }
                        Button("Clear Tag Filters") { window.selectedTags.removeAll() }.buttonStyle(.plain)
                    }
                    Button { window.showTags = true } label: { Label("Manage tags…", systemImage: "tag") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                } header: { Text("TAGS") }
            }
            .listStyle(.sidebar)
            .navigationTitle("Switchboard")
            .navigationSplitViewColumnWidth(min: 185, ideal: 215, max: 300)
            .safeAreaInset(edge: .bottom) {
                if !minimalView {
                    HStack { Image(systemName: "internaldrive"); Text("Stored on this Mac"); Spacer() }
                        .font(.caption).foregroundStyle(.secondary).padding(16)
                }
            }
    }
    private var detailContent: some View {
            VStack(spacing: 0) {
                if !minimalView {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(title).font(.system(size: 27, weight: .semibold))
                            Text("\(entries.count) \(entries.count == 1 ? "entry" : "entries") · Your files, folders, and links in one place")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Picker("Sort by", selection: $store.data.sort) {
                                ForEach(EntrySort.allCases) { Text($0.title).tag($0) }
                            }
                        } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
                        .menuStyle(.borderlessButton).fixedSize()
                    }.padding(24)
                    Divider()
                }
                    if let smartCollection {
                    HStack {
                        Text(smartCollection.criteria.unavailable(in: store.data)
                             ? "A saved condition is unavailable. Edit this smart collection to repair it."
                             : "Entries update automatically as saved conditions change. New entries must match to appear here.")
                        Spacer()
                        Button("Edit…") { window.smartDraft = smartCollection; window.showSmartCollections = true }
                        if hasAdditionalFilters { Button("Clear Additional Filters") { window.query = ""; window.selectedTags = [] } }
                    }.font(.caption).padding(12)
                }
                if contentQueryActive {
                    ContentSearchStatus(model: contentSearch, request: contentRequest, refresh: { contentCacheVersion += 1 }, clear: {
                        Task { await contentSearch.clearCache(); contentCacheVersion += 1 }
                    })
                    Divider()
                }
                if !window.selectedTags.isEmpty {
                    HStack {
                        Label("\(window.selectedTags.count) \(window.selectedTags.count == 1 ? "tag filter" : "tag filters") · \(window.tagMatch.title)", systemImage: "line.3.horizontal.decrease.circle")
                        Spacer()
                        Menu("Tags") { TagFilterMenu(store: store, window: window) }
                            .menuStyle(.borderlessButton).fixedSize()
                        Button("Clear") { window.selectedTags.removeAll() }
                    }.font(.callout).padding(.horizontal, 24).padding(.vertical, 10)
                    Divider()
                }
                if hierarchical && !searching && (currentCollection != nil || (showCollectionNames && !childCollections.isEmpty)) {
                    collectionNavigation
                }
                if entries.isEmpty && !showCollectionNames && !childCollections.isEmpty {
                    ContentUnavailableView {
                        Label("No entries here", systemImage: "folder")
                    } description: {
                        Text("Collection navigation is hidden. Choose a collection from the sidebar or Collections menu.")
                    } actions: {
                        Button("Show Collection Names") { showCollectionNames = true }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty && childCollections.isEmpty {
                    ContentUnavailableView {
                        Label(!searching ? "Your library starts here" : "No matching entries", systemImage: !searching ? "square.stack.3d.up" : "magnifyingglass")
                    } description: {
                        Text(!searching ? "Add files, folders, or URLs. You can also drop them here." : "Try a different search, tag filter, or collection.")
                    } actions: {
                        if let smartCollection {
                            Button("Edit Smart Collection…") { window.smartDraft = smartCollection; window.showSmartCollections = true }
                        } else if !searching {
                            Button("Add Files and Folders…") { store.importFiles(collectionID: collectionID) }
                            Button("Add URL…") { window.showURL = true }
                        } else { Button("Clear Search and Tags") { window.query = ""; window.selectedTags.removeAll() } }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if minimalView && minimalIconBloom { minimalIcons }
                else if store.data.view == .table { table }
                else if store.data.view == .compactList || store.data.view == .comfortableList { list }
                else { cards }
                if !minimalView {
                    Divider()
                    HStack {
                        Text(store.data.view.title)
                        Spacer()
                        if !window.selection.isEmpty { Text("\(window.selection.count) selected") }
                        Text("Drop files, folders, or links to add")
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 9)
                }
            }
    }
    private var detail: some View {
        detailContent
            .background((currentCollection?.palette ?? smartCollection?.palette)?.color.opacity(0.12) ?? Color(nsColor: .controlBackgroundColor))
            .overlay { if dropTarget { RoundedRectangle(cornerRadius: 8).stroke(store.configuration.palette.color, lineWidth: 3).padding(4).allowsHitTesting(false) } }
            .dropDestination(for: URL.self) { urls, _ in
                let valid: [URL] = urls.filter { url in url.isFileURL || LibraryLogic.webURL(url.absoluteString) != nil }
                store.add(valid, collectionID: collectionID); return !valid.isEmpty
            } isTargeted: { dropTarget = $0 }
            .inspector(isPresented: $window.showInspector) {
                if let id = window.selection.first, window.selection.count == 1,
                   let entry = store.data.entries.first(where: { $0.id == id }) {
                    EntryInspector(store: store, entry: entry, remove: { removeIDs = [entry.id] })
                        .id(entry.id)
                } else if window.selection.count > 1 {
                    BulkInspector(store: store, ids: window.selection) { removeIDs = $0 }
                } else {
                    ContentUnavailableView("Entry details", systemImage: "sidebar.right", description: Text("Select one entry to view and edit its details."))
                }
            }
            .inspectorColumnWidth(min: 250, ideal: 285, max: 360)
            .toolbar {
                ToolbarItemGroup {
                    Menu {
                        Button("Files and Folders…") { store.importFiles(collectionID: collectionID) }
                        Button("URL…") { window.showURL = true }
                    } label: { Label("Add entry", systemImage: "plus") }.help("Add to library")
                    Picker("View", selection: $store.data.view) {
                        ForEach(LibraryView.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                    }.pickerStyle(.menu).frame(maxWidth: 170)
                    Menu {
                        Picker("Search In", selection: $contentMode) { ForEach(ContentSearchMode.allCases) { Text($0.title).tag($0) } }
                    } label: { Label("Search mode", systemImage: "doc.text.magnifyingglass") }
                    Menu { SmartCollectionMenu(store: store, window: window) } label: { Label("Smart collections", systemImage: "line.3.horizontal.decrease.circle") }
                    Menu { CollectionFilterMenu(store: store, window: window) } label: { Label("Collections", systemImage: "folder") }
                        .help("Select or manage collections")
                    Menu { TagFilterMenu(store: store, window: window) } label: { Label("Filter by tags", systemImage: "tag") }
                    Menu("Organize Selected", systemImage: "square.stack.3d.up") {
                        BulkActions(store: store, ids: window.selection) { removeIDs = $0 }
                    }.disabled(window.selection.isEmpty).help("Organize selected entries")
                    Button { window.showSettings.toggle() } label: { Label("Configure view", systemImage: "slider.horizontal.3") }
                    Button { window.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                }
            }
            .searchable(text: $window.query, isPresented: $window.searchPresented, prompt: Text(contentMode.searchPrompt))
            .searchSuggestions {
                if searching {
                    ForEach(searchMatches.prefix(12)) { entry in
                        Button {
                            store.open(entry)
                            window.searchPresented = false
                        } label: {
                            Label { VStack(alignment: .leading) { Text(entry.name); Text(entry.location).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) } }
                            icon: { Image(systemName: entry.kind.icon) }
                        }
                    }
                }
            }
    }
    var collectionNavigation: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let currentCollection {
                HStack {
                    Button { window.scope = currentCollection.parentID?.uuidString ?? "all" } label: { Label("Back", systemImage: "chevron.left") }
                    Text(LibraryLogic.collectionPath(currentCollection, in: store.data.collections)).font(.callout).foregroundStyle(.secondary)
                }
            }
            if showCollectionNames && !childCollections.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(childCollections) { collection in
                            Button { window.scope = collection.id.uuidString } label: {
                                Label(collection.name, systemImage: collection.symbol)
                                    .padding(12)
                                    .background(collection.palette?.color.opacity(0.22) ?? Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }.padding(.horizontal, 24).padding(.top, 16)
    }
    func sidebarRow(_ name: String, icon: String, value: String, count: Int) -> some View {
        HStack { Label(name, systemImage: icon); Spacer(); Text("\(count)").font(.caption).foregroundStyle(.tertiary) }.tag(value)
    }
    var cards: some View {
        let thumbnails = store.data.view == .thumbnails
        let width = thumbnails ? store.configuration.resolvedThumbnailSize : store.data.view.cardWidth
        let spacing: CGFloat = thumbnails ? 8 : 16
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: thumbnails ? width : .infinity), spacing: spacing)],
                      alignment: .leading, spacing: spacing) {
                ForEach(entries) { entry in
                    entryInteraction(entry) {
                        if thumbnails {
                            EntryThumbnail(entry: entry, configuration: store.configuration, selected: window.selection.contains(entry.id))
                        } else {
                            EntryTile(entry: entry, configuration: store.configuration, view: store.data.view, selected: window.selection.contains(entry.id), contentMatch: contentMatch(for: entry), query: window.query)
                        }
                    }
                }
            }.padding(thumbnails ? 12 : 24)
        }
    }
    var minimalIcons: some View {
        MinimalIconView(entries: entries, configuration: store.configuration, selection: $window.selection,
                        interactionSuspended: dropTarget, activate: { store.open($0) }) { entry, size in
            entryInteraction(entry) {
                EntryThumbnail(entry: entry, configuration: store.configuration,
                               selected: window.selection.contains(entry.id), displaySize: size)
            }
        }
    }
    func entryInteraction<Content: View>(_ entry: LibraryEntry, @ViewBuilder content: () -> Content) -> some View {
        content()
            .contentShape(Rectangle())
            .entryHoverInfo(entry, collection: collectionName(for: entry), excerpt: contentMatch(for: entry)?.snippet)
            .modifier(EntryClickInteraction(singleClick: singleClick, select: { select(entry.id, modifiers: $0) }, open: { store.open(entry) }))
            .contextMenu { entryMenu(entry) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(entry.name)
            .accessibilityValue(window.selection.contains(entry.id) ? "Selected" : "")
            .accessibilityAction { window.selection = [entry.id]; if singleClick { store.open(entry) } }
    }
    var list: some View {
        List(selection: $window.selection) {
            ForEach(entries) { entry in
                HStack(spacing: 14) {
                    EntryIcon(kind: entry.kind, color: store.configuration.palette.color, size: store.data.view == .compactList ? 30 : 44)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(entry.name).fontWeight(.medium).lineLimit(1); if entry.favorite { Image(systemName: "star.fill").foregroundStyle(.orange).font(.caption) } }
                        EntryDetails(entry: entry, configuration: store.configuration, contentMatch: contentMatch(for: entry), query: window.query)
                    }
                    Spacer(minLength: 0)
                    if !singleClick {
                        Button { store.open(entry) } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.borderless).help("Open entry")
                    }
                }
                .font(store.configuration.font)
                .padding(.vertical, store.data.view == .compactList ? 2 : 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .entryHoverInfo(entry, collection: collectionName(for: entry), excerpt: contentMatch(for: entry)?.snippet)
                .tag(entry.id)
                .simultaneousGesture(TapGesture(count: 1).onEnded { openOnSingleClick(entry) })
                .contextMenu { entryMenu(entry) }
            }
        }.listStyle(.inset)
        .contextMenu(forSelectionType: UUID.self) { ids in
            BulkActions(store: store, ids: ids) { removeIDs = $0 }.disabled(ids.isEmpty)
        } primaryAction: { ids in
            if !singleClick || NSApp.currentEvent?.type == .keyDown {
                for entry in entries where ids.contains(entry.id) { store.open(entry) }
            }
        }
    }
    func collectionName(for entry: LibraryEntry) -> String? {
        store.data.collections.first { $0.id == entry.collectionID }?.name
    }
    func tableCell<Content: View>(_ entry: LibraryEntry, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .entryHoverInfo(entry, collection: collectionName(for: entry), excerpt: contentMatch(for: entry)?.snippet)
            .simultaneousGesture(TapGesture(count: 1).onEnded { openOnSingleClick(entry) })
    }
    var table: some View {
        Table(entries, selection: $window.selection) {
            TableColumn("Name") { entry in
                tableCell(entry) {
                    HStack { Image(systemName: entry.kind.icon).foregroundStyle(store.configuration.palette.color); Text(entry.name); if entry.favorite { Image(systemName: "star.fill").foregroundStyle(.orange) } }
                }
            }.width(min: 150, ideal: 220)
            if contentQueryActive {
                TableColumn("Content match") { entry in
                    tableCell(entry) { ContentSnippet(text: contentMatch(for: entry)?.snippet ?? "", query: window.query) }
                }.width(min: 180, ideal: 260)
            }
            if store.configuration.fields.contains(.kind) {
                TableColumn("Kind") { entry in tableCell(entry) { Text(entry.kind.title) } }.width(min: 60, ideal: 75)
            }
            if store.configuration.fields.contains(.location) {
                TableColumn("Location") { entry in tableCell(entry) { Text(entry.location).foregroundStyle(.secondary) } }.width(min: 150, ideal: 300)
            }
            if store.configuration.fields.contains(.tags) {
                TableColumn("Tags") { entry in tableCell(entry) { Text(entry.tags.joined(separator: ", ")) } }.width(min: 80, ideal: 130)
            }
            if store.configuration.fields.contains(.notes) {
                TableColumn("Notes") { entry in tableCell(entry) { Text(entry.notes).lineLimit(2) } }.width(min: 100, ideal: 200)
            }
            if store.configuration.fields.contains(.added) {
                TableColumn("Date added") { entry in tableCell(entry) { Text(entry.added, style: .date) } }.width(min: 90, ideal: 110)
            }
        }
        .id(store.configuration.fields)
        .font(store.configuration.font)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let entry = entries.first(where: { ids.contains($0.id) }), ids.count == 1 { entryMenu(entry) }
            else { BulkActions(store: store, ids: ids) { removeIDs = $0 }.disabled(ids.isEmpty) }
        } primaryAction: { ids in
            if !singleClick || NSApp.currentEvent?.type == .keyDown {
                for entry in entries where ids.contains(entry.id) { store.open(entry) }
            }
        }
    }
    func openOnSingleClick(_ entry: LibraryEntry) {
        if singleClick, NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty { store.open(entry) }
    }
    func select(_ id: UUID, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        if modifiers.contains(.command) {
            if window.selection.contains(id) { window.selection.remove(id) } else { window.selection.insert(id) }; selectionAnchor = id
        } else if modifiers.contains(.shift),
                  let anchor = selectionAnchor, let start = entries.firstIndex(where: { $0.id == anchor }),
                  let end = entries.firstIndex(where: { $0.id == id }) {
            window.selection = Set(entries[min(start, end)...max(start, end)].map(\.id))
        } else { window.selection = [id]; selectionAnchor = id }
    }
    @ViewBuilder func entryMenu(_ entry: LibraryEntry) -> some View {
        if window.selection.contains(entry.id), window.selection.count > 1 {
            BulkActions(store: store, ids: window.selection) { removeIDs = $0 }
        } else { singleEntryMenu(entry) }
    }
    @ViewBuilder func singleEntryMenu(_ entry: LibraryEntry) -> some View {
        Button("Open") { store.open(entry) }
        if entry.kind != .url { Button("Show in Finder") { store.reveal(entry) } }
        Button("Copy Location") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.location, forType: .string) }
        Button(entry.favorite ? "Remove from Favorites" : "Add to Favorites") { var updated = entry; updated.favorite.toggle(); store.update(updated) }
        Menu("Move to Collection") {
            if entry.collectionID != nil {
                Button("Remove from Collection") { var updated = entry; updated.collectionID = nil; store.update(updated) }
            }
            ForEach(store.data.collections.filter { $0.id != entry.collectionID }) { collection in
                Button(LibraryLogic.collectionPath(collection, in: store.data.collections)) { var updated = entry; updated.collectionID = collection.id; store.update(updated) }
            }
        }
        Divider()
        Button("Remove from Library…", role: .destructive) { removeIDs = [entry.id] }
    }
}

struct EntryIcon: View {
    var kind: EntryKind
    var color: Color
    var size: CGFloat
    var body: some View {
        Image(systemName: kind.icon).font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(color).frame(width: size, height: size)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: size * 0.24))
    }
}
struct EntryDetails: View {
    let entry: LibraryEntry
    let configuration: ViewConfiguration
    var contentMatch: ContentMatch? = nil
    var query = ""
    var body: some View {
        Group {
            if let contentMatch, contentMatch.state == .matched { ContentSnippet(text: contentMatch.snippet, query: query) }
            if configuration.fields.contains(.kind) { Text(entry.kind.title).foregroundStyle(configuration.palette.color) }
            if configuration.fields.contains(.location) { Text(entry.subtitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(entry.location) }
            if configuration.fields.contains(.notes), !entry.notes.isEmpty { Text(entry.notes).foregroundStyle(.secondary).lineLimit(2) }
            if configuration.fields.contains(.tags), !entry.tags.isEmpty {
                Text(entry.tags.map { "#" + $0 }.joined(separator: "  ")).foregroundStyle(configuration.palette.color).lineLimit(1)
            }
            if configuration.fields.contains(.added) { Text(entry.added, style: .date).foregroundStyle(.tertiary) }
        }.font(configuration.font)
    }
}
struct EntryTile: View {
    let entry: LibraryEntry
    let configuration: ViewConfiguration
    let view: LibraryView
    let selected: Bool
    var contentMatch: ContentMatch? = nil
    var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: view == .smallCards ? 6 : 12) {
            HStack(alignment: .top) {
                EntryIcon(kind: entry.kind, color: configuration.palette.color, size: view == .smallCards ? 36 : view == .largeCards ? 60 : 48)
                Spacer()
                if entry.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.orange) }
            }
            Text(entry.name).font(configuration.font.weight(.semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: view == .smallCards ? 4 : 7) { EntryDetails(entry: entry, configuration: configuration, contentMatch: contentMatch, query: query) }
            if view != .smallCards { Spacer(minLength: 0) }
        }
        .padding(view == .smallCards ? 10 : 20)
        .frame(maxWidth: .infinity, minHeight: view == .smallCards ? 0 : view == .largeCards ? 250 : 205, alignment: .topLeading)
        .background(selected ? configuration.palette.color.opacity(0.09) : Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? configuration.palette.color : Color.primary.opacity(0.09), lineWidth: selected ? 2 : 1) }
    }
}

final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
