import SwiftUI
import AppKit

extension View {
    func entryHoverInfo(_ entry: LibraryEntry, collection: String?, excerpt: String? = nil) -> some View {
        onHover { hovering in
            if hovering {
                EntryHoverPanel.shared.show(entry, collection: collection, excerpt: excerpt)
            } else {
                EntryHoverPanel.shared.hide(entry.id)
            }
        }
        .onDisappear { EntryHoverPanel.shared.hide(entry.id) }
    }
}

/// A passive panel leaves mouse events and keyboard focus with the library.
@MainActor
private final class EntryHoverPanel: NSObject {
    static let shared = EntryHoverPanel()
    private var panel: NSPanel?
    private var entryID: UUID?
    private var pending: Task<Void, Never>?
    private var interactionMonitor: Any?
    private var menuIsTracking = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(dismiss),
                                               name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidBeginTracking),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidEndTracking),
                                               name: NSMenu.didEndTrackingNotification, object: nil)
        interactionMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel
        ]) { [weak self] event in
            MainActor.assumeIsolated { self?.dismiss() }
            return event
        }
    }

    func show(_ entry: LibraryEntry, collection: String?, excerpt: String?) {
        guard !menuIsTracking, NSEvent.pressedMouseButtons == 0 else { return }
        pending?.cancel()
        if entryID == entry.id, panel?.isVisible == true { return }
        panel?.orderOut(nil)
        panel?.contentView = nil
        entryID = entry.id
        pending = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(450)) }
            catch { return }
            guard !Task.isCancelled, NSApp.isActive, !self.menuIsTracking,
                  NSEvent.pressedMouseButtons == 0, self.entryID == entry.id else { return }
            self.present(entry, collection: collection, excerpt: excerpt)
        }
    }

    func hide(_ id: UUID) {
        guard entryID == id else { return }
        pending?.cancel()
        // Keep the panel steady while crossing between cells of the same row.
        pending = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(80)) }
            catch { return }
            self.dismiss()
        }
    }

    @objc private func dismiss() {
        pending?.cancel()
        panel?.orderOut(nil)
        panel?.contentView = nil
        entryID = nil
    }

    @objc private func menuDidBeginTracking() {
        menuIsTracking = true
        dismiss()
    }

    @objc private func menuDidEndTracking() {
        menuIsTracking = false
    }

    private func present(_ entry: LibraryEntry, collection: String?, excerpt: String?) {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let previewHeight = min(200, max(80, bounds.height - 420))
        let content = NSHostingView(rootView: EntryHoverDetails(entry: entry, collection: collection, previewHeight: previewHeight, excerpt: excerpt)
            .frame(width: entry.kind == .file ? 400 : 320)
            .frame(maxHeight: bounds.height))
        let size = content.fittingSize
        let window = panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .popUpMenu
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = true
        window.appearance = NSApp.keyWindow?.effectiveAppearance ?? NSApp.effectiveAppearance
        window.contentView = content
        let x = min(max(point.x + 16, bounds.minX), bounds.maxX - size.width)
        let y = min(max(point.y - size.height - 16, bounds.minY), bounds.maxY - size.height)
        window.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        panel = window
        window.orderFront(nil)
    }
}

private struct EntryHoverDetails: View {
    let entry: LibraryEntry
    let collection: String?
    let previewHeight: CGFloat
    var excerpt: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Label(entry.name, systemImage: entry.kind.icon).font(.headline).lineLimit(3)
                Spacer(minLength: 0)
                if entry.favorite { Image(systemName: "star.fill").foregroundStyle(.orange) }
            }
            Text(entry.kind.title).font(.caption).foregroundStyle(.secondary)
            if let excerpt, !excerpt.isEmpty { detail("Content match", excerpt, lines: 4) }
            if entry.kind == .file { FileHoverPreview(entry: entry, height: previewHeight) }
            Divider()
            detail(entry.kind == .url ? "URL" : "Location", entry.location, lines: entry.kind == .file ? 3 : 5)
            if let collection { detail("Collection", collection, lines: 2) }
            if !entry.tags.isEmpty { detail("Tags", entry.tags.joined(separator: ", "), lines: entry.kind == .file ? 2 : 3) }
            if !entry.notes.isEmpty { detail("Notes", entry.notes, lines: entry.kind == .file ? 3 : 6) }
            detail("Date added", entry.added.formatted(date: .abbreviated, time: .shortened), lines: 1)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12)) }
    }

    private func detail(_ title: String, _ value: String, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).lineLimit(lines).fixedSize(horizontal: false, vertical: true)
        }
    }
}
