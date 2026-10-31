import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import QuickLookThumbnailing

enum FilePreviewLoader {
    static let maximumTextBytes = 16_384

    static func fileURL(for entry: LibraryEntry) -> URL? {
        guard entry.kind == .file else { return nil }
        if let bookmark = entry.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale), url.isFileURL { return url }
        }
        return entry.url
    }

    static func textExcerpt(at url: URL) -> String? {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        let extensions: Set<String> = ["md", "markdown", "txt", "log", "json", "yaml", "yml", "toml", "csv", "tsv"]
        guard extensions.contains(url.pathExtension.lowercased()) || UTType(filenameExtension: url.pathExtension)?.conforms(to: .text) == true,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data: Data
        do { data = try handle.read(upToCount: maximumTextBytes) ?? Data() }
        catch { return nil }
        if data.isEmpty { return "This file is empty." }
        let text: String
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            guard let decoded = String(data: data, encoding: .utf16) else { return nil }
            text = decoded
        } else {
            // A bounded read may end partway through a UTF-8 character.
            let prefix = data.prefix(while: { $0 != 0 })
            guard prefix.count == data.count else { return nil }
            text = String(decoding: data, as: UTF8.self)
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false).prefix(14).joined(separator: "\n")
    }
}

final class FileThumbnailRequest: @unchecked Sendable {
    // Immutable request; Quick Look supports cancelling an in-flight request.
    let request: QLThumbnailGenerator.Request
    init(url: URL, size: CGSize = CGSize(width: 368, height: 220), scale: CGFloat) {
        request = .init(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
    }
    func image() async -> CGImage? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                    continuation.resume(returning: representation?.cgImage)
                }
                if Task.isCancelled { QLThumbnailGenerator.shared.cancel(request) }
            }
        } onCancel: {
            QLThumbnailGenerator.shared.cancel(self.request)
        }
    }
}

struct FileHoverPreview: View {
    let entry: LibraryEntry
    let height: CGFloat
    @Environment(\.displayScale) private var scale
    @State private var text: String?
    @State private var image: CGImage?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Content preview").font(.caption).foregroundStyle(.secondary)
            Group {
                if let text {
                    Text(text).font(.system(size: 11, design: .monospaced))
                        .lineLimit(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(10)
                } else if let image {
                    Image(decorative: image, scale: scale).resizable().scaledToFit().padding(6)
                } else if loading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Label("Preview unavailable", systemImage: "doc.questionmark")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .clipped()
        }
        .task(id: entry) {
            text = nil; image = nil; loading = true
            defer { loading = false }
            guard let url = FilePreviewLoader.fileURL(for: entry) else { return }
            let excerpt = await Task.detached(priority: .utility) { FilePreviewLoader.textExcerpt(at: url) }.value
            guard !Task.isCancelled else { return }
            if let excerpt { text = excerpt; return }
            let thumbnail = await FileThumbnailRequest(url: url, scale: scale).image()
            guard !Task.isCancelled else { return }
            image = thumbnail
        }
    }
}
