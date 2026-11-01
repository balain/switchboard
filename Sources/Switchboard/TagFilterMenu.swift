import SwiftUI

struct TagFilterMenu: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var window: LibraryWindowState

    var body: some View {
        Picker("Match", selection: $window.tagMatch) {
            ForEach(TagMatch.allCases) { Text($0.title).tag($0) }
        }
        Divider()
        if store.data.tags.isEmpty { Text("No tags yet") }
        ForEach(store.data.tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { tag in
            Toggle(isOn: Binding(get: { window.selectedTags.contains(tag.id) }, set: { enabled in
                if enabled { window.selectedTags.insert(tag.id) } else { window.selectedTags.remove(tag.id) }
            })) { Label(tag.name, systemImage: tag.symbol) }
        }
        Divider()
        Button("Clear Tag Filters") { window.selectedTags.removeAll() }.disabled(window.selectedTags.isEmpty)
        Button("Manage Tags…") { window.showTags = true }
    }
}
