import SwiftUI
import AppKit
import Combine

struct BulkActions: View {
    @ObservedObject var store: LibraryStore
    let ids: Set<UUID>
    var remove: (Set<UUID>) -> Void
    var body: some View {
        Button("Mark Favorite") { store.applyBulk(.favorite(true), to: ids) }
        Button("Remove Favorite") { store.applyBulk(.favorite(false), to: ids) }
        Menu("Add Tag") {
            ForEach(store.data.tags) { tag in Button(tag.name) { store.applyBulk(.addTag(tag.id), to: ids) } }
        }.disabled(store.data.tags.isEmpty)
        Menu("Remove Tag") {
            ForEach(store.data.tags) { tag in Button(tag.name) { store.applyBulk(.removeTag(tag.id), to: ids) } }
        }.disabled(store.data.tags.isEmpty)
        Menu("Move to Collection") {
            Button("Remove from Collection") { store.applyBulk(.collection(nil), to: ids) }
            ForEach(store.data.collections) { collection in
                Button(LibraryLogic.collectionPath(collection, in: store.data.collections)) { store.applyBulk(.collection(collection.id), to: ids) }
            }
        }
        Divider()
        Button("Remove Selected…", role: .destructive) { remove(ids) }
    }
}

struct BulkInspector: View {
    @ObservedObject var store: LibraryStore
    let ids: Set<UUID>
    var remove: (Set<UUID>) -> Void
    private var entries: [LibraryEntry] { store.data.entries.filter { ids.contains($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(entries.count) selected").font(.title2)
            Text(Set(entries.map(\.favorite)).count > 1 ? "Favorites: mixed" : entries.first?.favorite == true ? "All favorites" : "No favorites")
            Text(Set(entries.map(\.collectionID)).count > 1 ? "Collections: mixed" : "One collection assignment")
                .foregroundStyle(.secondary)
            Text("Tag actions add or remove only the chosen tag. Other tags stay in place.").font(.caption).foregroundStyle(.secondary)
            Menu("Organize Selected") { BulkActions(store: store, ids: ids, remove: remove) }
            Text("Last action changed \(store.lastAffectedCount) entries.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(22)
    }
}

/// Text editors keep their native history; library actions use one history across windows.
@MainActor
final class UndoRouting: ObservableObject {
    @Published private var revision = 0
    private var subscriptions: [AnyCancellable] = []
    init() {
        for name in [NSText.didChangeNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification, NSNotification.Name.NSUndoManagerDidUndoChange,
                     NSNotification.Name.NSUndoManagerDidRedoChange, NSNotification.Name.NSUndoManagerCheckpoint] {
            NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.revision += 1 }
            }.store(in: &subscriptions)
        }
    }
    func manager(fallback: UndoManager) -> UndoManager {
        _ = revision
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, let native = text.undoManager { return native }
        return fallback
    }
}

/// Preserve mouse-down modifiers without a drag recognizer competing with taps.
@MainActor
private final class EntryClickModifiers {
    static let shared = EntryClickModifiers()
    private(set) var flags: NSEvent.ModifierFlags = []
    private var monitor: Any?
    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.flags = event.modifierFlags }
            return event
        }
    }
}

@MainActor
final class CommandResponderState: ObservableObject {
    @Published private(set) var editingText = false
    @Published private(set) var hasModalSheet = false
    private var keyWindowObserver: NSKeyValueObservation?
    private var mainWindowObserver: NSKeyValueObservation?
    private var firstResponderObserver: NSKeyValueObservation?
    private var sheetObserver: NSKeyValueObservation?
    private var mainSheetObserver: NSKeyValueObservation?
    private var subscriptions: [AnyCancellable] = []

    init() {
        guard let app = NSApp else { return }
        keyWindowObserver = app.observe(\.keyWindow, options: [.initial, .new]) { [weak self] app, _ in
            MainActor.assumeIsolated {
                self?.bind(keyWindow: app.keyWindow, mainWindow: app.mainWindow)
            }
        }
        mainWindowObserver = app.observe(\.mainWindow, options: [.initial, .new]) { [weak self] app, _ in
            MainActor.assumeIsolated {
                self?.bind(keyWindow: app.keyWindow, mainWindow: app.mainWindow)
            }
        }
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willBeginSheetNotification,
            NSWindow.didEndSheetNotification,
            NSText.didBeginEditingNotification,
            NSText.didEndEditingNotification,
            NSText.didChangeNotification,
            NSControl.textDidBeginEditingNotification,
            NSControl.textDidEndEditingNotification
        ]
        for name in names {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self?.bind(keyWindow: NSApp?.keyWindow, mainWindow: NSApp?.mainWindow)
                    }
                } else {
                    Task { @MainActor [weak self] in
                        self?.bind(keyWindow: NSApp?.keyWindow, mainWindow: NSApp?.mainWindow)
                    }
                }
            }.store(in: &subscriptions)
        }
    }

    func bind(keyWindow: NSWindow?, mainWindow: NSWindow?) {
        firstResponderObserver = nil
        sheetObserver = nil
        mainSheetObserver = nil
        update(keyWindow: keyWindow, mainWindow: mainWindow)
        if let keyWindow {
            firstResponderObserver = keyWindow.observe(\.firstResponder, options: [.new]) { [weak self, weak keyWindow, weak mainWindow] _, _ in
                MainActor.assumeIsolated {
                    self?.update(keyWindow: keyWindow, mainWindow: mainWindow)
                }
            }
            sheetObserver = keyWindow.observe(\.attachedSheet, options: [.new]) { [weak self, weak keyWindow, weak mainWindow] _, _ in
                MainActor.assumeIsolated {
                    self?.update(keyWindow: keyWindow, mainWindow: mainWindow)
                }
            }
        }
        if let mainWindow, mainWindow !== keyWindow {
            mainSheetObserver = mainWindow.observe(\.attachedSheet, options: [.new]) { [weak self, weak keyWindow, weak mainWindow] _, _ in
                MainActor.assumeIsolated {
                    self?.update(keyWindow: keyWindow, mainWindow: mainWindow)
                }
            }
        }
    }

    func update(keyWindow: NSWindow?, mainWindow: NSWindow?) {
        let nextEditing = keyWindow?.firstResponder is NSText
        let nextModal = keyWindow?.sheetParent != nil || keyWindow?.attachedSheet != nil || mainWindow?.attachedSheet != nil
        if editingText != nextEditing { editingText = nextEditing }
        if hasModalSheet != nextModal { hasModalSheet = nextModal }
    }
}

struct EntryClickInteraction: ViewModifier {
    let singleClick: Bool
    let select: (NSEvent.ModifierFlags) -> Void
    let open: () -> Void
    private let pointer = EntryClickModifiers.shared
    func body(content: Content) -> some View {
        content
            .gesture(TapGesture(count: singleClick ? 1 : 2).onEnded {
                let modifiers = pointer.flags
                select(modifiers)
                if modifiers.intersection([.command, .shift]).isEmpty { open() }
            })
            .simultaneousGesture(TapGesture().onEnded { if !singleClick { select(pointer.flags) } })
    }
}

/// Preserve native selection and double-click handling in the default mode.
struct EntryOpenInteraction: ViewModifier {
    let singleClick: Bool
    let open: () -> Void
    private let pointer = EntryClickModifiers.shared
    func body(content: Content) -> some View {
        if singleClick {
            content.simultaneousGesture(TapGesture().onEnded {
                if pointer.flags.intersection([.command, .shift, .control]).isEmpty { open() }
            })
        } else {
            content
        }
    }
}
