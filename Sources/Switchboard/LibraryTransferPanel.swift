import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LibraryTransferPanel: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var format: TransferFormat = .json
    @State private var policy: DuplicatePolicy = .skip
    @State private var applyRules = false
    @State private var incoming: LibraryData?
    @State private var preview: ImportPreview?
    @State private var message = ""
    @State private var pendingRestore: Data?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import, Export, and Backups").font(.title2.weight(.semibold))
            Text("Portable exports include names, paths, URLs, notes, tags, collections, and smart filters. Bookmarks and display preferences stay local.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Export", selection: $format) { ForEach(TransferFormat.allCases) { Text($0.title).tag($0) } }
                Button("Export…") { export() }
                Button("Import JSON or HTML…") { chooseImport() }
            }
            if let incoming {
                Toggle("Apply organization rules to imported entries", isOn: $applyRules)
                    .disabled(!store.importRulesAvailable)
                    .onChange(of: applyRules) { _, _ in prepare(incoming) }
                Picker("Duplicate addresses", selection: $policy) { ForEach(DuplicatePolicy.allCases) { Text($0.title).tag($0) } }
                    .onChange(of: policy) { _, _ in prepare(incoming) }
            }
            if let preview {
                Text("Preview: \(preview.added) entries added, \(preview.skipped) duplicate references skipped.").font(.headline)
                Text("Existing entries are preserved. Imported local files have no access bookmarks; use the file picker to grant access if needed.").font(.caption)
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(Array(preview.conflicts.enumerated()), id: \.offset) { _, item in Text(item).font(.caption) }
                        ForEach(preview.candidate.entries.filter { entry in !store.data.entries.contains { $0.id == entry.id } }.prefix(50)) { entry in
                            Label(entry.name, systemImage: entry.kind.icon)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 80, maxHeight: 180)
                Button("Import Reviewed Library") {
                    if store.importLibrary(preview) { self.preview = nil; self.incoming = nil; message = "Import completed." }
                }.buttonStyle(.borderedProminent)
            }
            Divider()
            Text("Local Backups").font(.headline)
            Text("Keep one daily snapshot for 30 days, plus manual and pre-import/pre-restore checkpoints. Backups retain local bookmarks. No cloud service is used.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Back Up Now") { if let url = store.backupNow() { message = "Created \(url.lastPathComponent)." } }
                Button("Show Backups in Finder") {
                    do { try FileManager.default.createDirectory(at: store.backups.directory, withIntermediateDirectories: true); NSWorkspace.shared.open(store.backups.directory) }
                    catch { store.error = error.localizedDescription }
                }
                Button("Restore Backup…") { chooseRestore() }
            }
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary) }
            Spacer()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 760, height: 580)
        .alert("Replace library with this backup?", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })) {
            Button("Cancel", role: .cancel) { pendingRestore = nil }
            Button("Restore", role: .destructive) {
                if let bytes = pendingRestore, store.restoreLibrary(bytes) { preview = nil; incoming = nil; message = "Library restored. Undo history was cleared." }
                pendingRestore = nil
            }
        } message: { Text("A checkpoint preserves the current file before replacement. Original files stay in place.") }
        .alert("Library Transfer", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
    private func prepare(_ value: LibraryData) {
        do { preview = try store.prepareImport(value, policy: policy, applyRules: applyRules) }
        catch { store.error = error.localizedDescription; preview = nil }
    }
    private func chooseImport() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json, .html]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let parsed = try LibraryTransfer.parse(LibraryTransfer.read(url), html: url.pathExtension.lowercased() != "json"); incoming = parsed; prepare(parsed) }
        catch { store.error = error.localizedDescription }
    }
    private func chooseRestore() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bytes = try LibraryTransfer.read(url, maximumBytes: LibraryTransfer.maximumImportBytes * 4)
            _ = try JSONDecoder().decode(LibraryBackup.self, from: bytes).validated(); pendingRestore = bytes
        } catch { store.error = error.localizedDescription }
    }
    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Switchboard.\(format.rawValue)"
        panel.allowedContentTypes = [format == .json ? .json : format == .html ? .html : .commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try LibraryTransfer.export(store.data, format: format).write(to: url, options: .atomic); message = "Export completed." }
        catch { store.error = error.localizedDescription }
    }
}
