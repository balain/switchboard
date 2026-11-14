import SwiftUI

struct ContentSnippet: View {
    let text: String
    let query: String
    private var highlighted: AttributedString {
        var value = AttributedString(text)
        if let range = value.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            value[range].backgroundColor = Color.yellow.opacity(0.35)
            value[range].foregroundColor = .primary
        }
        return value
    }
    var body: some View { Text(highlighted).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
}

struct ContentSearchStatus: View {
    @ObservedObject var model: ContentSearchModel
    let request: ContentSearchRequest
    var refresh: () -> Void
    var clear: () -> Void
    private var current: [ContentMatch] { model.request == request ? Array(model.matches.values) : [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if model.running { ProgressView().controlSize(.small) }
                Text("\(current.count)/\(request.entries.count) references checked · \(current.filter { $0.state == .skipped || $0.state == .unavailable }.count) not searched")
                Spacer()
                Button("Refresh") { refresh() }
                Button("Clear Cache") { clear() }
            }
            Text("Local text and searchable PDFs only. Files over 1 MB (text), 8 MB or 200 pages (PDF), unsupported types, and unavailable/cloud files are skipped. OCR and web content are not searched.")
                .foregroundStyle(.secondary)
            let skipped = current.filter { $0.state == .skipped || $0.state == .unavailable }
            if !skipped.isEmpty {
                DisclosureGroup("Coverage details") {
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(skipped.sorted { $0.id.uuidString < $1.id.uuidString }, id: \.id) { result in
                                Text("\(request.entries.first { $0.id == result.id }?.name ?? "Entry"): \(result.reason)")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100)
                }
            }
            if !model.message.isEmpty { Text(model.message).foregroundStyle(.secondary) }
        }.font(.caption).padding(12)
    }
}


struct SearchScopeControls: View {
    @Binding var mode: ContentSearchMode
    @Binding var query: String
    let scope: String
    let tagCount: Int
    let smart: Bool
    @State private var showHelp = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Search In", selection: $mode) {
                    ForEach(ContentSearchMode.allCases) { Text($0.title).tag($0) }
                }.fixedSize()
                Text("Within \(scope)" + (tagCount > 0 ? " · \(tagCount) tag filters" : ""))
                    .lineLimit(1).help("Search combines with the current collection, saved conditions, and tag filters.")
                Spacer()
                if !query.isEmpty { Button("Clear Query") { query = "" } }
                Button { showHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .help("Search syntax").accessibilityLabel("Search syntax")
                    .popover(isPresented: $showHelp) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Search syntax").font(.headline)
                            Text("kind:file  tag:Reading  ext:pdf  favorite:true")
                            Text("name:Report  location:Projects  notes:review")
                            Text("Quote values containing spaces: tag:\"To Read\". Exclude a condition with a minus: -tag:Archive.")
                            Text("Conditions all apply together. Remaining text is a phrase searched in the selected mode. Unknown prefixes are literal text.")
                            Text("Document contents searches local text and PDFs. Metadata and contents matches either source. Saved conditions and tag filters still apply.")
                        }.padding(18).frame(width: 380)
                    }
            }
            if let error = SearchQuery(query).error { Text(error).foregroundStyle(.red) }
            else if smart { Text("Saved conditions AND current query AND tag filters").foregroundStyle(.secondary) }
        }.font(.caption).padding(.horizontal, 20).padding(.vertical, 8)
    }
}
