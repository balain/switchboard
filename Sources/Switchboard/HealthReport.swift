import SwiftUI
import AppKit

struct HealthReport: View {
    @ObservedObject var store: LibraryStore
    @StateObject private var scan = HealthScanModel()
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<UUID> = []
    @State private var filter = "All"
    @State private var removing = false
    private var findings: [HealthFinding] {
        scan.findings.filter { filter == "All" || (filter == "Duplicates" ? !$0.duplicates.isEmpty : $0.check.status != .healthy) }
            .sorted { $0.entry.name.localizedStandardCompare($1.entry.name) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Library Health").font(.title2.weight(.semibold)); Spacer(); Text("\(scan.completed)/\(scan.total)").monospacedDigit() }
            Text("Local scans do not change your library or request web pages. Web checks contact saved URLs only when explicitly requested.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Check Local References") { selection = []; scan.scan(store.data.entries, includeWeb: false) }
                Button("Check Web Links") { selection = []; scan.scan(store.data.entries, includeWeb: true) }
                Button("Cancel Scan") { scan.cancel(); scan.message = "Scan cancelled." }.disabled(!scan.running)
                Picker("Show", selection: $filter) { ForEach(["All", "Needs attention", "Duplicates"], id: \.self) { Text($0).tag($0) } }
            }
            if scan.running { ProgressView(value: Double(scan.completed), total: Double(max(1, scan.total))) }
            List(selection: $selection) {
                ForEach(findings) { finding in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(finding.entry.name).font(.headline); Spacer(); Text(finding.check.status.title).foregroundStyle(finding.check.status == .healthy ? .secondary : .primary) }
                        Text(finding.entry.location).lineLimit(1).truncationMode(.middle)
                        Text(finding.check.detail).foregroundStyle(.secondary)
                        if !finding.duplicates.isEmpty { Text("Same reference as \(finding.duplicates.count) other entries. Review metadata and choose which references to keep.").foregroundStyle(.orange) }
                        Text("Tags: \(finding.entry.tags.joined(separator: ", ")) · Notes: \(finding.entry.notes)").lineLimit(3)
                        Text("Checked \(finding.checked.formatted(date: .omitted, time: .shortened))").foregroundStyle(.tertiary)
                    }.font(.caption).padding(.vertical, 5).tag(finding.id)
                }
            }
            Text(scan.message).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Locate Replacement…") { repair() }.disabled(selection.count != 1 || scan.running)
                Button("Remove Selected References…", role: .destructive) { removing = true }.disabled(selection.isEmpty || scan.running)
                Spacer(); Button("Done") { scan.cancel(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 860, height: 600)
        .onChange(of: store.data.entries) { _, value in scan.discardStale(in: value); selection.formIntersection(Set(scan.findings.map(\.id))) }
        .onDisappear { scan.cancel() }
        .alert("Remove these library references?", isPresented: $removing) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                let valid = Set(scan.findings.filter { finding in selection.contains(finding.id) && store.data.entries.contains(finding.entry) }.map(\.id))
                if valid != selection { scan.message = "Some findings changed. Re-scan before removing them." }
                _ = store.remove(valid); selection = []
            }
        } message: { Text("Original files are kept. One Undo restores the removed references and metadata.") }
        .alert("Library Health", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }
    private func repair() {
        guard let finding = scan.findings.first(where: { selection.contains($0.id) }), finding.entry.kind != .url else {
            scan.message = "Use entry details to edit a web address."; return
        }
        let panel = NSOpenPanel(); panel.canChooseFiles = finding.entry.kind == .file; panel.canChooseDirectories = finding.entry.kind == .folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var replacement = finding.entry; replacement.location = url.standardizedFileURL.path
            replacement.bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            if store.applyEntryChanges(expected: [finding.entry], updated: [replacement], title: "Repair Reference") > 0 { scan.message = "Reference repaired. Re-scan to verify." }
        } catch { store.error = error.localizedDescription }
    }
}
