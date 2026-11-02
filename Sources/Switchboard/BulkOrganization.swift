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

struct EntryClickInteraction: ViewModifier {
    let singleClick: Bool
    let select: (NSEvent.ModifierFlags) -> Void
    let open: () -> Void
    @State private var modifiers: NSEvent.ModifierFlags = []
    @State private var tracking = false
    func body(content: Content) -> some View {
        content
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
                if !tracking {
                    modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
                    tracking = true
                }
            }.onEnded { _ in tracking = false })
            .gesture(TapGesture(count: singleClick ? 1 : 2).onEnded {
                select(modifiers)
                if modifiers.intersection([.command, .shift]).isEmpty { open() }
            })
            .simultaneousGesture(TapGesture().onEnded { if !singleClick { select(modifiers) } })
    }
}
