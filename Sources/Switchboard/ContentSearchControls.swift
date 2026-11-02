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
