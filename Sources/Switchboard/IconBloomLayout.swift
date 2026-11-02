import Foundation

/// Stable slot coordinates keep magnification from feeding back into pointer tracking.
struct IconBloomLayout {
    let count: Int
    let baseSize: CGFloat
    let maximumScale: CGFloat
    let contentWidth: CGFloat
    let spacing: CGFloat = 10
    private(set) var growth: [Int: CGFloat] = [:]
    private(set) var totalGrowth: CGFloat = 0

    var stride: CGFloat { baseSize + spacing }
    var stripWidth: CGFloat { CGFloat(count) * baseSize + CGFloat(max(0, count - 1)) * spacing }
    var origin: CGFloat { (contentWidth - stripWidth) / 2 }

    init(count: Int, preferredSize: CGFloat, height: CGFloat, viewportWidth: CGFloat,
         pointerX: CGFloat?, reduceMotion: Bool) {
        self.count = max(0, count)
        let height = height.isFinite ? max(0, height) : 0
        let preferred = preferredSize.isFinite ? min(160, max(48, preferredSize)) : 80
        maximumScale = height >= 64 && !reduceMotion ? 1.6 : 1
        baseSize = min(preferred, max(1, height - 16) / maximumScale)
        let strip = CGFloat(self.count) * baseSize + CGFloat(max(0, self.count - 1)) * spacing
        // Five slots bound the growth inside a two-stride radius, even at either edge.
        let padding = 12 + CGFloat(min(5, self.count)) * baseSize * (maximumScale - 1) / 2
        contentWidth = max(max(0, viewportWidth.isFinite ? viewportWidth : 0), strip + 2 * padding)
        guard let pointerX, pointerX.isFinite, self.count > 0, maximumScale > 1 else { return }
        let radius = 2 * stride
        let firstCenter = origin + baseSize / 2
        guard pointerX >= firstCenter - radius,
              pointerX <= firstCenter + CGFloat(self.count - 1) * stride + radius else { return }
        let first = max(0, Int(floor((pointerX - radius - firstCenter) / stride)))
        let last = min(self.count - 1, Int(ceil((pointerX + radius - firstCenter) / stride)))
        guard first <= last else { return }
        for index in first...last {
            let distance = abs(center(at: index) - pointerX)
            guard distance < radius else { continue }
            let falloff = 1 - pow(distance / radius, 2)
            let extra = baseSize * (maximumScale - 1) * falloff * falloff
            growth[index] = extra
            totalGrowth += extra
        }
    }

    func center(at index: Int) -> CGFloat { origin + baseSize / 2 + CGFloat(index) * stride }
    func scale(at index: Int) -> CGFloat { 1 + (growth[index] ?? 0) / baseSize }
    func offset(at index: Int) -> CGFloat {
        growth.reduce(CGFloat.zero) { $0 + ($1.key < index ? $1.value : 0) }
            + (growth[index] ?? 0) / 2 - totalGrowth / 2
    }
    func displayedFrame(at index: Int, height: CGFloat) -> CGRect {
        let size = baseSize * scale(at: index)
        return CGRect(x: center(at: index) + offset(at: index) - size / 2,
                      y: (height - size) / 2, width: size, height: size)
    }
    func index(at point: CGPoint, height: CGFloat) -> Int? {
        var lower = 0
        var upper = count
        while lower < upper {
            let middle = (lower + upper) / 2
            let frame = displayedFrame(at: middle, height: height)
            if point.x < frame.minX { upper = middle }
            else if point.x >= frame.maxX { lower = middle + 1 }
            else { return frame.contains(point) ? middle : nil }
        }
        return nil
    }
}
