import SwiftUI
import AppKit

/// A passive tracking view supplies viewport coordinates without intercepting tile gestures.
struct IconBloomTracking: NSViewRepresentable {
    let onPoint: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onPoint = onPoint
        return view
    }
    func updateNSView(_ view: TrackingView, context: Context) { view.onPoint = onPoint }
    static func dismantleNSView(_ view: TrackingView, coordinator: ()) { view.stopMonitoring() }

    final class TrackingView: NSView {
        var onPoint: ((CGPoint?) -> Void)?
        private var area: NSTrackingArea?
        private var monitor: Any?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited, .mouseMoved],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            self.area = area
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .scrollWheel, .leftMouseDragged]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window else { return }
                    if event.type == .mouseMoved { self.report(event) }
                    else { self.onPoint?(nil) }
                }
                return event
            }
        }
        override func mouseEntered(with event: NSEvent) { report(event) }
        override func mouseMoved(with event: NSEvent) { report(event) }
        override func mouseExited(with event: NSEvent) { onPoint?(nil) }

        private func report(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            onPoint?(visibleRect.contains(point) ? point : nil)
        }
        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
