import SwiftUI

struct CollectionFilterMenu: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var window: LibraryWindowState

    var body: some View {
        Picker("Collection", selection: $window.scope) {
            Label("All Entries", systemImage: "square.stack.3d.up").tag("all")
            ForEach(store.data.collections) { collection in
                Label(LibraryLogic.collectionPath(collection, in: store.data.collections), systemImage: collection.symbol)
                    .tag(collection.id.uuidString)
            }
        }.pickerStyle(.inline)
        Divider()
        Button("Manage Collections…") { window.showCollections = true }
    }
}
