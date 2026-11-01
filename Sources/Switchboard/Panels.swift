import SwiftUI
import AppKit

struct ViewSettings: View {
    @ObservedObject var store: LibraryStore
    private func binding<T>(_ path: WritableKeyPath<ViewConfiguration, T>) -> Binding<T> {
        Binding(get: { store.configuration[keyPath: path] }, set: { value in
            var configuration = store.configuration; configuration[keyPath: path] = value; store.configuration = configuration
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure \(store.data.view.title.lowercased())").font(.headline)
            Text("Settings are saved separately for each view.").font(.caption).foregroundStyle(.secondary)
            Divider()
            if store.data.view == .thumbnails {
                Text("Previews and icons only. Names and details appear on hover.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Thumbnail size")
                    Slider(value: Binding(get: { Double(store.configuration.resolvedThumbnailSize) }, set: { value in
                        var configuration = store.configuration
                        configuration.thumbnailSize = value
                        store.configuration = configuration
                    }), in: 48...160, step: 8)
                    Text("\(Int(store.configuration.resolvedThumbnailSize)) pt").monospacedDigit().frame(width: 48)
                }
            } else {
                Text("Visible fields").font(.subheadline.weight(.semibold))
                Text("Name is always shown.").font(.caption).foregroundStyle(.secondary)
                ForEach(EntryField.allCases) { field in
                    Toggle(field.title, isOn: Binding(get: { store.configuration.fields.contains(field) }, set: { enabled in
                        var configuration = store.configuration
                        if enabled { configuration.fields.insert(field) } else { configuration.fields.remove(field) }
                        store.configuration = configuration
                    }))
                }
            }
            Divider()
            Picker("Palette", selection: binding(\.palette)) {
                ForEach(Palette.allCases) { palette in Text(palette.rawValue.capitalized).tag(palette) }
            }
            if store.data.view != .thumbnails {
                Picker("Font", selection: binding(\.fontName)) {
                    Text("System").tag("System")
                    ForEach(NSFontManager.shared.availableFontFamilies.sorted(), id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Text("Font size")
                    Slider(value: binding(\.fontSize), in: 10...24, step: 1)
                    Text("\(Int(store.configuration.fontSize)) pt").monospacedDigit().frame(width: 42)
                }
            }
            Picker("Appearance", selection: $store.data.appearance) {
                Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
            }.onChange(of: store.data.appearance) { _, _ in store.save() }
            Divider()
            Button("Reset This View") { store.configuration = ViewConfiguration() }
        }.padding(22).frame(width: 340)
    }
}

struct EntryInspector: View {
    @ObservedObject var store: LibraryStore
    let entry: LibraryEntry
    var remove: () -> Void
    @State private var name = ""
    @State private var notes = ""
    @State private var tags = ""
    @State private var location = ""
    @State private var collectionID: UUID?
    @State private var favorite = false
    @State private var validation: String?
    @State private var loaded = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    EntryIcon(kind: entry.kind, color: store.configuration.palette.color, size: 54)
                    Spacer()
                    Button { favorite.toggle(); save() } label: {
                        Image(systemName: favorite ? "star.fill" : "star").foregroundStyle(favorite ? .orange : .secondary)
                    }.buttonStyle(.plain).help("Toggle favorite")
                }
                Text(entry.kind.title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Display name").font(.caption).foregroundStyle(.secondary)
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder).onSubmit { save() }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.kind == .url ? "URL" : "Location").font(.caption).foregroundStyle(.secondary)
                    if entry.kind == .url { TextField("https://…", text: $location).textFieldStyle(.roundedBorder).onSubmit { save() } }
                    else { Text(entry.location).font(.callout).textSelection(.enabled).foregroundStyle(.secondary) }
                }
                Picker("Collection", selection: $collectionID) {
                    Text("None").tag(nil as UUID?)
                    ForEach(store.data.collections) { Text(LibraryLogic.collectionPath($0, in: store.data.collections)).tag(Optional($0.id)) }
                }.onChange(of: collectionID) { _, _ in if loaded { save() } }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tags").font(.caption).foregroundStyle(.secondary)
                    TextField("design, work, reading", text: $tags).textFieldStyle(.roundedBorder).onSubmit { save() }
                    if !store.data.tags.isEmpty {
                        Menu("Choose Tags") {
                            ForEach(store.data.tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { tag in
                                Toggle(tag.name, isOn: Binding(get: {
                                    tags.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(tag.name) == .orderedSame }
                                }, set: { enabled in
                                    var names = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                    names.removeAll { $0.caseInsensitiveCompare(tag.name) == .orderedSame }
                                    if enabled { names.append(tag.name) }
                                    tags = names.joined(separator: ", ")
                                    save()
                                }))
                            }
                        }
                    }
                    Text("Separate tags with commas.").font(.caption2).foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $notes).font(.body).frame(height: 130).padding(4)
                        .overlay { RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25)) }
                }
                if let validation { Text(validation).font(.caption).foregroundStyle(.red) }
                Button("Save Details") { save() }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Divider()
                LabeledContent("Added", value: entry.added.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                Button { store.open(entry) } label: { Label("Open \(entry.kind == .url ? "URL" : entry.kind.title)", systemImage: "arrow.up.right") }
                if entry.kind != .url { Button { store.reveal(entry) } label: { Label("Show in Finder", systemImage: "folder") } }
                Button(role: .destructive, action: remove) { Label("Remove from Library…", systemImage: "trash") }
                Text("Display names and collections organize your library. Original files stay in place.").font(.caption).foregroundStyle(.tertiary)
            }.padding(22)
        }
        .onChange(of: entry.tags) { _, value in tags = value.joined(separator: ", ") }
        .onChange(of: entry.collectionID) { _, value in collectionID = value }
        .onAppear {
            name = entry.name; notes = entry.notes; tags = entry.tags.joined(separator: ", ")
            location = entry.location; collectionID = entry.collectionID; favorite = entry.favorite; loaded = true
        }
    }
    func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { validation = "Enter a display name."; return }
        var updated = store.data.entries.first(where: { $0.id == entry.id }) ?? entry
        if entry.kind == .url {
            guard let url = LibraryLogic.webURL(location) else { validation = "Enter a valid HTTP or HTTPS URL."; return }
            updated.location = url.absoluteString
        }
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.notes = notes
        var seen = Set<String>()
        updated.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        updated.collectionID = collectionID; updated.favorite = favorite
        validation = nil; store.update(updated)
    }
}

struct AddURLSheet: View {
    @ObservedObject var store: LibraryStore
    let collectionID: UUID?
    var added: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var location = ""
    @State private var clipboardURL: URL?
    @State private var clipboardTitle: String?
    @State private var checkingClipboard = false
    @State private var clipboardMessage: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add a URL").font(.title2.weight(.semibold))
            Text("Keep a useful link alongside your files and folders.").foregroundStyle(.secondary)
            if let clipboardURL {
                VStack(alignment: .leading, spacing: 10) {
                    if checkingClipboard {
                        HStack { ProgressView().controlSize(.small); Text("Checking URL from clipboard…") }
                    } else {
                        Text(clipboardTitle ?? "URL from clipboard").font(.headline).lineLimit(3)
                    }
                    Text(clipboardURL.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    if let clipboardMessage { Text(clipboardMessage).font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button(clipboardTitle == nil ? "Use Clipboard URL" : "Use Clipboard Details") {
                            location = clipboardURL.absoluteString
                            if let clipboardTitle { name = clipboardTitle }
                            self.clipboardURL = nil
                        }.disabled(checkingClipboard)
                        Button("Dismiss") { self.clipboardURL = nil }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            TextField("URL — example.com", text: $location).textFieldStyle(.roundedBorder)
            TextField("Display name (optional)", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add URL") {
                    if let id = store.addURL(name: name, location: location, collectionID: collectionID) { added(id); dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(LibraryLogic.webURL(location) == nil)
            }
        }.padding(28).frame(width: 430)
        .task {
            let pasteboard = NSPasteboard.general
            guard let text = pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string),
                  let url = URLTitleFetcher.clipboardURL(text) else { return }
            clipboardURL = url
            checkingClipboard = true
            defer { checkingClipboard = false }
            do {
                let title = try await URLTitleFetcher.title(for: url)
                guard !Task.isCancelled, clipboardURL != nil else { return }
                clipboardTitle = title
                if title == nil { clipboardMessage = "This page has no HTML title. You can use the URL and enter a name." }
            } catch {
                guard !Task.isCancelled, clipboardURL != nil else { return }
                clipboardMessage = "Couldn’t retrieve a page title. You can still use the URL and enter a name."
            }
        }
    }
}
