import SwiftUI
import AppKit

private struct IconStripOffset: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct MinimalIconView<Tile: View>: View {
    let entries: [LibraryEntry]
    let configuration: ViewConfiguration
    @Binding var selection: Set<UUID>
    let interactionSuspended: Bool
    let activate: (LibraryEntry) -> Void
    @ViewBuilder let tile: (LibraryEntry, CGFloat) -> Tile
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var keyboardFocused: Bool
    @GestureState private var dragging = false
    @State private var pointerX: CGFloat?
    @State private var hovered: UUID?
    @State private var keyboardEntry: UUID?
    @State private var menuTracking = false
    @State private var contentOffset: CGFloat = 0
    @Namespace private var viewportSpace

    var body: some View {
        GeometryReader { geometry in
            let layout = IconBloomLayout(count: entries.count, preferredSize: configuration.resolvedThumbnailSize,
                                         height: geometry.size.height, viewportWidth: geometry.size.width,
                                         pointerX: pointerX, reduceMotion: reduceMotion)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: layout.spacing) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            tile(entry, layout.baseSize)
                                .frame(width: layout.baseSize, height: layout.baseSize)
                                .overlay {
                                    if hovered == entry.id || (keyboardFocused && keyboardEntry == entry.id) {
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(configuration.palette.color, lineWidth: 2)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .scaleEffect(layout.scale(at: index))
                                .offset(x: layout.offset(at: index))
                                .zIndex(Double(layout.scale(at: index)))
                                .id(entry.id)
                        }
                    }
                    .frame(width: layout.contentWidth, height: geometry.size.height)
                    .contentShape(Rectangle())
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(key: IconStripOffset.self,
                                                   value: content.frame(in: .named(viewportSpace)).minX)
                        }
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: layout.growth)
                }
                .coordinateSpace(name: viewportSpace)
                .background {
                    IconBloomTracking { point in
                        guard let point, !menuTracking, !interactionSuspended, !dragging else { resetHover(); return }
                        let bandHeight = min(geometry.size.height, layout.baseSize * layout.maximumScale + 16)
                        guard abs(point.y - geometry.size.height / 2) <= bandHeight / 2 else { resetHover(); return }
                        let contentPoint = CGPoint(x: point.x - contentOffset, y: point.y)
                        pointerX = contentPoint.x
                        let target = IconBloomLayout(count: entries.count, preferredSize: configuration.resolvedThumbnailSize,
                                                     height: geometry.size.height, viewportWidth: geometry.size.width,
                                                     pointerX: contentPoint.x, reduceMotion: reduceMotion)
                        hovered = target.index(at: contentPoint, height: geometry.size.height).map { entries[$0].id }
                    }
                }
                .onPreferenceChange(IconStripOffset.self) { offset in contentOffset = offset; resetHover() }
                .onChange(of: geometry.size) { _, _ in resetHover() }
                .focusable()
                .focusEffectDisabled()
                .focused($keyboardFocused)
                .simultaneousGesture(TapGesture().onEnded { keyboardFocused = true })
                .simultaneousGesture(DragGesture(minimumDistance: 4).updating($dragging) { _, value, _ in value = true })
                .onMoveCommand { direction in
                    let step: Int
                    switch direction {
                    case .left, .up: step = -1
                    case .right, .down: step = 1
                    default: return
                    }
                    resetHover()
                    guard !entries.isEmpty else { return }
                    let current = entries.firstIndex { $0.id == keyboardEntry }
                        ?? entries.firstIndex { selection.contains($0.id) }
                    let index = current.map { min(entries.count - 1, max(0, $0 + step)) }
                        ?? (step > 0 ? 0 : entries.count - 1)
                    keyboardEntry = entries[index].id
                    selection = [entries[index].id]
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                        proxy.scrollTo(entries[index].id, anchor: .center)
                    }
                }
                .onKeyPress(.return) {
                    guard let entry = entries.first(where: { selection.contains($0.id) }) else { return .ignored }
                    activate(entry)
                    return .handled
                }
            }
        }
        .onChange(of: entries) { _, _ in resetHover(); keyboardEntry = nil }
        .onChange(of: selection) { _, value in
            if let keyboardEntry, !value.contains(keyboardEntry) { self.keyboardEntry = nil }
        }
        .onChange(of: configuration) { _, _ in resetHover() }
        .onChange(of: interactionSuspended) { _, _ in resetHover() }
        .onChange(of: dragging) { _, _ in resetHover() }
        .onChange(of: reduceMotion) { _, _ in resetHover() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            menuTracking = true; resetHover()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            menuTracking = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in resetHover() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in resetHover() }
        .onDisappear { resetHover() }
    }

    private func resetHover() { pointerX = nil; hovered = nil }
}
