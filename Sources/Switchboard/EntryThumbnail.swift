import SwiftUI
import AppKit

struct EntryThumbnail: View {
    let entry: LibraryEntry
    let configuration: ViewConfiguration
    let selected: Bool
    var displaySize: CGFloat? = nil
    private var tileSize: CGFloat { displaySize ?? configuration.resolvedThumbnailSize }
    @Environment(\.displayScale) private var scale
    @State private var image: CGImage?
    @State private var fileIcon: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: scale).resizable().scaledToFit()
            } else if let fileIcon {
                Image(nsImage: fileIcon).resizable().scaledToFit()
            } else {
                Image(systemName: entry.kind == .folder ? "folder.fill" : entry.kind.icon)
                    .resizable().scaledToFit().foregroundStyle(configuration.palette.color)
                    .padding(tileSize * 0.16)
            }
        }
        .padding(6)
        .frame(width: tileSize, height: tileSize)
        .background(selected ? configuration.palette.color.opacity(0.15) : Color(nsColor: .textBackgroundColor).opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? configuration.palette.color : Color.primary.opacity(0.08),
                                                          lineWidth: selected ? 2 : 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.name)
        .task(id: entry) {
            image = nil; fileIcon = nil
            guard let url = FilePreviewLoader.fileURL(for: entry) else { return }
            fileIcon = NSWorkspace.shared.icon(forFile: url.path)
            // Generate for the largest supported tile so resizing reuses the loaded image.
            let preview = await FileThumbnailRequest(url: url, size: CGSize(width: 160, height: 160), scale: scale).image()
            guard !Task.isCancelled else { return }
            image = preview
        }
    }
}
