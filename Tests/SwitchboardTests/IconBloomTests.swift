import XCTest
import AppKit
import SwiftUI
@testable import Switchboard

final class IconBloomTests: XCTestCase {
    private func layout(count: Int = 20, height: CGFloat = 220, pointer: CGFloat? = nil,
                        reduceMotion: Bool = false) -> IconBloomLayout {
        IconBloomLayout(count: count, preferredSize: 80, height: height, viewportWidth: 900,
                        pointerX: pointer, reduceMotion: reduceMotion)
    }

    func testNearestIconAndNeighborFalloff() {
        let resting = layout()
        let bloom = layout(pointer: resting.center(at: 8))
        XCTAssertEqual(bloom.scale(at: 8), 1.6, accuracy: 0.0001)
        XCTAssertGreaterThan(bloom.scale(at: 7), 1)
        XCTAssertEqual(bloom.scale(at: 7), bloom.scale(at: 9), accuracy: 0.0001)
        XCTAssertEqual(bloom.scale(at: 6), 1)
        XCTAssertEqual(bloom.scale(at: 10), 1)
        XCTAssertEqual(bloom.center(at: 8) + bloom.offset(at: 8), resting.center(at: 8), accuracy: 0.0001)
        XCTAssertLessThanOrEqual(bloom.growth.count, 5)
    }

    func testNoOverlapOrEdgeClippingAcrossPointerPositions() {
        for count in [1, 2, 3, 20] {
            let resting = layout(count: count)
            for step in 0...100 {
                let x = resting.contentWidth * CGFloat(step) / 100
                let bloom = layout(count: count, pointer: x)
                var previous: CGRect?
                for index in 0..<count {
                    let frame = bloom.displayedFrame(at: index, height: 220)
                    XCTAssertGreaterThanOrEqual(frame.minX, 0)
                    XCTAssertLessThanOrEqual(frame.maxX, bloom.contentWidth)
                    XCTAssertGreaterThanOrEqual(frame.minY, 0)
                    XCTAssertLessThanOrEqual(frame.maxY, 220)
                    if let previous { XCTAssertEqual(frame.minX - previous.maxX, bloom.spacing, accuracy: 0.0001) }
                    XCTAssertEqual(bloom.index(at: CGPoint(x: frame.midX, y: frame.midY), height: 220), index)
                    previous = frame
                }
                XCTAssertEqual(bloom.contentWidth, resting.contentWidth)
            }
        }
    }

    func testSmallHeightsAndThumbnailSizesFit() {
        for height: CGFloat in [24, 48, 63, 64, 80, 320.0 / 3.0, 200] {
            for size: CGFloat in [48, 80, 160] {
                let resting = IconBloomLayout(count: 3, preferredSize: size, height: height,
                                              viewportWidth: 900, pointerX: nil, reduceMotion: false)
                let bloom = IconBloomLayout(count: 3, preferredSize: size, height: height,
                                            viewportWidth: 900, pointerX: resting.center(at: 1), reduceMotion: false)
                let frame = bloom.displayedFrame(at: 1, height: height)
                XCTAssertGreaterThanOrEqual(frame.minY, 0)
                XCTAssertLessThanOrEqual(frame.maxY, height)
                if height < 64 { XCTAssertEqual(bloom.maximumScale, 1) }
            }
        }
    }

    func testReduceMotionAndPointerExitRestoreStaticGeometry() {
        let resting = layout()
        for bloom in [layout(pointer: nil), layout(pointer: resting.center(at: 5), reduceMotion: true)] {
            XCTAssertTrue(bloom.growth.isEmpty)
            for index in 0..<bloom.count {
                XCTAssertEqual(bloom.scale(at: index), 1)
                XCTAssertEqual(bloom.offset(at: index), 0)
            }
        }
    }

    func testHitTestingRejectsPaddingGapsAndVerticalSpace() {
        let resting = layout()
        let bloom = layout(pointer: resting.center(at: 0))
        let frame = bloom.displayedFrame(at: 0, height: 220)
        XCTAssertNil(bloom.index(at: CGPoint(x: 0, y: 110), height: 220))
        XCTAssertNil(bloom.index(at: CGPoint(x: frame.midX, y: 0), height: 220))
        XCTAssertNil(bloom.index(at: CGPoint(x: frame.maxX + 2, y: 110), height: 220))
        XCTAssertNil(layout(count: 0).index(at: .zero, height: 220))
        XCTAssertTrue(layout(pointer: .nan).growth.isEmpty)
        XCTAssertTrue(layout(pointer: .infinity).growth.isEmpty)
    }

    func testThousandEntryGeometryHasBoundedInfluence() {
        let resting = layout(count: 1_000)
        measure {
            for index in 0..<1_000 {
                let bloom = layout(count: 1_000, pointer: resting.center(at: index))
                XCTAssertLessThanOrEqual(bloom.growth.count, 5)
                let frame = bloom.displayedFrame(at: index, height: 220)
                XCTAssertEqual(bloom.index(at: CGPoint(x: frame.midX, y: frame.midY), height: 220), index)
            }
        }
    }

    @MainActor func testNativeTrackingConvertsWindowCoordinatesWithoutInterceptingClicks() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tracker = IconBloomTracking.TrackingView(frame: CGRect(x: 20, y: 30, width: 400, height: 200))
        var reported: CGPoint?
        tracker.onPoint = { reported = $0 }
        window.contentView?.addSubview(tracker)
        defer { tracker.stopMonitoring() }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: 170, y: 130),
                                                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        tracker.mouseMoved(with: event)
        XCTAssertEqual(reported, CGPoint(x: 150, y: 100))
        XCTAssertNil(tracker.hitTest(CGPoint(x: 150, y: 100)))
        tracker.mouseExited(with: event)
        XCTAssertNil(reported)
    }

    @MainActor func testThousandEntryStripOnlyCreatesVisibleTiles() {
        let entries = (0..<1_000).map {
            LibraryEntry(name: "Folder \($0)", location: "/tmp/bloom-fixture/\($0)", kind: .folder)
        }
        var created = 0
        let strip = MinimalIconView(entries: entries, configuration: ViewConfiguration(), selection: .constant([]),
                                    interactionSuspended: false, activate: { _ in }) { _, _ in
            CountingBloomTile { created += 1 }
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 220),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: strip)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        XCTAssertGreaterThan(created, 0)
        XCTAssertLessThan(created, 50, "Offscreen entries should not start thumbnail work.")
    }
}

private struct CountingBloomTile: NSViewRepresentable {
    let onCreate: () -> Void
    func makeNSView(context: Context) -> NSView { onCreate(); return NSView() }
    func updateNSView(_ view: NSView, context: Context) { }
}
