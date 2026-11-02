import SwiftUI
import AppKit
import Combine

@MainActor final class QuickLauncherCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    @Published var query = "" { didSet { refresh(reset: true) } }
    @Published private(set) var results: [LibraryEntry] = []
    @Published var selectedID: UUID?
    @Published var message: String?
    @Published var presentationID = UUID()
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "launcherEnabled"); configureShortcut() } }
    @Published var shortcut: LauncherShortcut {
        didSet { defaults.set(try? JSONEncoder().encode(shortcut), forKey: "launcherShortcut"); configureShortcut() }
    }
    @Published private(set) var shortcutStatus = ""
    private let store: LibraryStore
    private let defaults: UserDefaults
    private let hotKey: LauncherHotKeyBackend
    private var index: LauncherSearch
    private var subscriptions: [AnyCancellable] = []
    private(set) var panel: NSPanel?
    private var previousApp: NSRunningApplication?
    private weak var previousWindow: NSWindow?
    private var started = false
    private var pendingReveal: UUID?
    var openLibrary: (() -> Void)?
    private struct Registration {
        weak var window: NSWindow?
        weak var state: LibraryWindowState?
    }
    private var windows: [UUID: Registration] = [:]

    init(store: LibraryStore, defaults: UserDefaults = .standard, hotKey: LauncherHotKeyBackend? = nil) {
        self.store = store; self.defaults = defaults; self.hotKey = hotKey ?? CarbonLauncherHotKey()
        index = LauncherSearch(entries: store.data.entries)
        enabled = defaults.object(forKey: "launcherEnabled") as? Bool ?? true
        shortcut = defaults.data(forKey: "launcherShortcut").flatMap { try? JSONDecoder().decode(LauncherShortcut.self, from: $0) } ?? LauncherShortcut()
        super.init()
        store.$data.map(\.entries).removeDuplicates().sink { [weak self] entries in
            guard let self else { return }
            self.index = LauncherSearch(entries: entries); self.refresh(reset: false)
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didFinishLaunchingNotification).sink { [weak self] _ in self?.start() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink { [weak self] _ in
            self?.shutdown()
        }.store(in: &subscriptions)
    }
    func start() { guard !started else { return }; started = true; configureShortcut() }
    func shutdown() { hotKey.unregister(); started = false; panel?.orderOut(nil) }
    private func configureShortcut() {
        guard started else { return }
        hotKey.unregister()
        guard enabled else { shortcutStatus = "Global shortcut is disabled. Use File → Quick Launcher…."; return }
        do {
            try hotKey.register(shortcut) { [weak self] in self?.toggle() }
            shortcutStatus = "Registered \(shortcut.title). Press it from another app to verify."
        } catch { shortcutStatus = error.localizedDescription }
    }
    private func refresh(reset: Bool) {
        results = index.results(query: query)
        if reset { selectedID = results.first?.id; message = nil }
        else if let selectedID, !results.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }
    func move(_ step: Int) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selectedID }
        let index = current.map { min(results.count - 1, max(0, $0 + step)) } ?? (step > 0 ? 0 : results.count - 1)
        selectedID = results[index].id
    }
    func toggle() {
        if panel?.isVisible == true { dismiss(); return }
        previousApp = NSWorkspace.shared.frontmostApplication; previousWindow = NSApp.keyWindow
        query = ""; refresh(reset: true); presentationID = UUID()
        let window: NSPanel
        if let panel { window = panel }
        else {
            window = LauncherPanel(contentRect: .zero, styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "Quick Launcher"; window.isReleasedWhenClosed = false
            window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.hidesOnDeactivate = false; window.delegate = self
            window.contentView = NSHostingView(rootView: QuickLauncherView(launcher: self))
            panel = window
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let screen { window.setFrame(Self.panelFrame(in: screen.visibleFrame), display: true) }
        window.makeKeyAndOrderFront(nil)
    }
    nonisolated static func panelFrame(in bounds: CGRect) -> CGRect {
        let width = min(640, max(1, bounds.width - 32)), height = min(460, max(1, bounds.height - 32))
        return CGRect(x: bounds.midX - width / 2, y: min(bounds.maxY - height - 16, bounds.midY - height / 3), width: width, height: height)
    }
    func dismiss(restoreFocus: Bool = true) {
        panel?.orderOut(nil)
        if restoreFocus {
            if previousApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier { previousWindow?.makeKeyAndOrderFront(nil) }
            else { previousApp?.activate(options: []) }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }
    func windowDidResignKey(_ notification: Notification) { if panel?.isVisible == true { dismiss(restoreFocus: false) } }
    private func selectedEntry() -> LibraryEntry? {
        guard let selectedID, let entry = store.data.entries.first(where: { $0.id == selectedID }) else {
            message = "Select an available entry."; return nil
        }
        return entry
    }
    func open() { guard let entry = selectedEntry() else { return }; dismiss(restoreFocus: false); store.open(entry) }
    func revealInFinder() { guard let entry = selectedEntry(), entry.kind != .url else { return }; dismiss(restoreFocus: false); store.reveal(entry) }
    func copyLocation() {
        guard let entry = selectedEntry() else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.location, forType: .string); dismiss()
    }
    func showInSwitchboard() {
        guard let entry = selectedEntry() else { return }
        dismiss(restoreFocus: false)
        if let registration = windows.values.first(where: { $0.window?.isVisible == true || $0.window?.isMiniaturized == true }),
           let window = registration.window, let state = registration.state {
            reveal(entry, in: state); window.deminiaturize(nil); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        } else { pendingReveal = entry.id; openLibrary?() }
    }
    func register(window: NSWindow, state: LibraryWindowState) {
        windows[state.windowID] = Registration(window: window, state: state)
        if let id = pendingReveal, let entry = store.data.entries.first(where: { $0.id == id }) {
            pendingReveal = nil; reveal(entry, in: state)
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        }
    }
    func unregister(_ id: UUID) { windows.removeValue(forKey: id) }
    private func reveal(_ entry: LibraryEntry, in state: LibraryWindowState) { state.reveal(entry) }
    var selectedKind: EntryKind? { store.data.entries.first { $0.id == selectedID }?.kind }
}

private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct QuickLauncherView: View {
    @ObservedObject var launcher: QuickLauncherCoordinator
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 12) {
            TextField("Search your library", text: $launcher.query)
                .textFieldStyle(.roundedBorder).font(.title3).focused($searchFocused)
                .onKeyPress(.downArrow) { launcher.move(1); return .handled }
                .onKeyPress(.upArrow) { launcher.move(-1); return .handled }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.command) { launcher.showInSwitchboard() } else { launcher.open() }
                    return .handled
                }
            ScrollViewReader { proxy in
                List(selection: $launcher.selectedID) {
                    ForEach(launcher.results) { entry in
                        HStack {
                            Image(systemName: entry.kind.icon)
                            VStack(alignment: .leading) {
                                Text(entry.name).lineLimit(1)
                                Text(entry.location).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }.tag(entry.id).id(entry.id)
                            .onTapGesture(count: 2) { launcher.selectedID = entry.id; launcher.open() }
                    }
                }
                .onChange(of: launcher.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
            }
            if launcher.results.isEmpty { Text("No matching entries").foregroundStyle(.secondary) }
            if let message = launcher.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text("↑↓ select · Return open · ⌘Return show · Esc dismiss").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu("Actions") {
                    Button("Open") { launcher.open() }
                    Button("Show in Finder") { launcher.revealInFinder() }.disabled(launcher.selectedKind == .url)
                    Button("Copy Location") { launcher.copyLocation() }
                    Button("Show in Switchboard") { launcher.showInSwitchboard() }
                }.disabled(launcher.selectedID == nil).menuStyle(.borderlessButton).fixedSize()
            }
        }.padding(16)
        .onAppear { searchFocused = true }
        .onChange(of: launcher.presentationID) { _, _ in searchFocused = true }
        .onKeyPress(.escape) { launcher.dismiss(); return .handled }
    }
}

struct LauncherSettings: View {
    @ObservedObject var launcher: QuickLauncherCoordinator
    var body: some View {
        Form {
            Toggle("Enable global shortcut", isOn: $launcher.enabled)
            Picker("Physical key", selection: $launcher.shortcut.keyCode) {
                ForEach(LauncherShortcut.keys, id: \.1) { Text($0.0).tag($0.1) }
            }
            Toggle("Control", isOn: $launcher.shortcut.control)
            Toggle("Option", isOn: $launcher.shortcut.option)
            Toggle("Command", isOn: $launcher.shortcut.command)
            Toggle("Shift", isOn: $launcher.shortcut.shift)
            Text("Letter keys use US physical key positions. Choose a combination with Control or Command.")
                .font(.caption).foregroundStyle(.secondary)
            Text(launcher.shortcutStatus).font(.callout)
            Button("Test Quick Launcher") { launcher.toggle() }
        }.padding(24).frame(width: 440)
    }
}

struct LauncherWindowBridge: View {
    let launcher: QuickLauncherCoordinator
    let state: LibraryWindowState
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        LauncherWindowAttachment(launcher: launcher, state: state)
            .onAppear { let action = openWindow; launcher.openLibrary = { action(id: "library") }; launcher.start() }
    }
}

private struct LauncherWindowAttachment: NSViewRepresentable {
    let launcher: QuickLauncherCoordinator
    let state: LibraryWindowState
    func makeNSView(context: Context) -> RegistrationView {
        let view = RegistrationView(); view.launcher = launcher; view.state = state; return view
    }
    func updateNSView(_ view: RegistrationView, context: Context) { }
    static func dismantleNSView(_ view: RegistrationView, coordinator: ()) {
        if let id = view.state?.windowID { view.launcher?.unregister(id) }
    }
    final class RegistrationView: NSView {
        weak var launcher: QuickLauncherCoordinator?
        weak var state: LibraryWindowState?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, let state { launcher?.register(window: window, state: state) }
        }
    }
}
