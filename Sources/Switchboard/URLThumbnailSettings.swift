import SwiftUI

struct URLThumbnailSettings: View {
    @ObservedObject private var thumbnails = URLThumbnailStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("URL thumbnails · shared settings").font(.headline)
            Toggle("Load thumbnails for URLs", isOn: $thumbnails.enabled)
            Text("When enabled, visible URL tiles contact websites to load preview images or icons. Requests do not use stored cookies or credentials.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper("Concurrent loads: \(thumbnails.workers)", value: $thumbnails.workers, in: 1...12)
            Text("Parallel background loads share a local cache. Cached images expire after 7 days; the disk cache is limited to 100 MB.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Clear URL Thumbnail Cache") { thumbnails.clearCache() }
            if let message = thumbnails.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
