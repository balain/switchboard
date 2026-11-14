import SwiftUI
import AppKit

struct VivaldiSyncSettings: View {
    @ObservedObject var sync: VivaldiSyncCoordinator
    @State private var confirmDisconnect = false
    @State private var confirmPair = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Vivaldi Bookmark Sync").font(.title2.bold())
            Text("Sync titles, HTTP/HTTPS URLs, and folder placement through the companion Vivaldi extension. In Vivaldi, choose all bookmarks or any combination of bookmarks and folders. The Vivaldi Bookmarks collection contains this connection’s items; notes, tags, favorites, and local files stay in Switchboard.")
                .font(.callout).foregroundStyle(.secondary)
            if sync.message.contains("\n") {
                ScrollView { Text(sync.message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 140)
            } else { Text(sync.message).textSelection(.enabled) }
            if let date = sync.lastSync { Text("Last completed sync: \(date.formatted())").font(.caption).foregroundStyle(.secondary) }
            HStack {
                if sync.enabled { Button("Pause") { sync.pause() } }
                else { Button("Enable / Resume") { sync.start() }.buttonStyle(.borderedProminent) }
                Button("New Pairing…") { confirmPair = true }
                Button("Disconnect…") { confirmDisconnect = true }
                Button("Show Companion Extension") {
                    if let url = Bundle.main.resourceURL?.appendingPathComponent("VivaldiExtension"), FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    else { syncDirectory() }
                }
            }
            if !sync.pairingCode.isEmpty {
                GroupBox("Pair with Vivaldi") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Load the companion folder using Load unpacked at vivaldi://extensions, open its Options, then paste this pairing code and select a scope. Keep the code private; it grants bookmark access to this connection.").font(.caption)
                        HStack { Text("Pairing code ready").foregroundStyle(.secondary); Spacer(); Button("Copy Pairing Code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(sync.pairingCode, forType: .string) } }
                    }.padding(6)
                }
            }
            if sync.deletions > 0 {
                GroupBox("Deletion review") {
                    HStack { Text("This snapshot removes \(sync.deletions) synced bookmarks or folders. Recovery checkpoints retain the previous library; the extension keeps browser snapshots."); Button("Approve This Snapshot") { sync.approveDeletions() } }.padding(6)
                }
            }
            if !sync.conflicts.isEmpty {
                Text("Conflicting changes").font(.headline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(sync.conflicts) { conflict in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(conflict.title).font(.headline)
                                Text("Switchboard: \(describe(conflict.local))\nVivaldi: \(describe(conflict.browser))").font(.caption).textSelection(.enabled)
                                HStack {
                                    Button("Keep Switchboard") { sync.resolve(conflict, keepLocal: true) }
                                    Button("Keep Vivaldi") { sync.resolve(conflict, keepLocal: false) }
                                }
                            }
                            Divider()
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Text("Changes sync while both apps run, after bookmark events and periodically, about once a minute. A large deletion pauses for review. Disconnect keeps both copies. Changing the selected scope requires a new pairing. Library restore pauses sync until a fresh pairing. Only this Mac’s loopback connection is used.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 760, height: 620)
        .alert("Disconnect Vivaldi?", isPresented: $confirmDisconnect) {
            Button("Cancel", role: .cancel) { }; Button("Disconnect") { sync.disconnect() }
        } message: { Text("Existing items stay in both applications. The old pairing code will stop working.") }
        .alert("Create a new pairing?", isPresented: $confirmPair) {
            Button("Cancel", role: .cancel) { }; Button("Create Pairing") { sync.pairAgain() }
        } message: { Text("This invalidates the previous code. The next browser connection creates a new collection and reviews its scope independently. Existing collections stay in the library.") }
    }
    private func describe(_ node: VivaldiNode?) -> String {
        guard let node else { return "Deleted" }
        return "\(node.title) · \(node.url ?? "Folder") · parent \(node.parent ?? "sync root")"
    }
    private func syncDirectory() {
        // Development fallback is relative to the package, never a developer-specific path.
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Extensions/Vivaldi")
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}
