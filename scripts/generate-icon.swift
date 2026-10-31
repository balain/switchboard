// Render Switchboard's vector icon with AppKit; no external dependencies.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let iconset = resources.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func rounded(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}
func render(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    // Inset macOS rounded tile, with enough transparent space for a soft shadow.
    let tile = rounded(NSRect(x: 64, y: 64, width: 896, height: 896), radius: 198)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x123858).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0x122C4C), color(0x146B91), color(0x29A8B4)])!.draw(in: tile, angle: 58)
    color(0xFFFFFF, alpha: 0.18).setStroke(); tile.lineWidth = 3; tile.stroke()

    // A routing track joins three content tiles: file, folder, and URL.
    let track = NSBezierPath()
    track.move(to: NSPoint(x: 350, y: 676))
    track.line(to: NSPoint(x: 512, y: 676))
    track.curve(to: NSPoint(x: 568, y: 620), controlPoint1: NSPoint(x: 550, y: 676), controlPoint2: NSPoint(x: 568, y: 658))
    track.line(to: NSPoint(x: 568, y: 404))
    track.curve(to: NSPoint(x: 624, y: 348), controlPoint1: NSPoint(x: 568, y: 366), controlPoint2: NSPoint(x: 586, y: 348))
    track.line(to: NSPoint(x: 704, y: 348))
    track.move(to: NSPoint(x: 420, y: 348))
    track.line(to: NSPoint(x: 512, y: 348))
    track.curve(to: NSPoint(x: 568, y: 404), controlPoint1: NSPoint(x: 550, y: 348), controlPoint2: NSPoint(x: 568, y: 366))
    track.lineWidth = 38; track.lineCapStyle = .round
    color(0xA9F5E4).setStroke(); track.stroke()

    func contentTile(x: CGFloat, y: CGFloat, symbol: String, tint: UInt32) {
        let rect = NSRect(x: x, y: y, width: 270, height: 248)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color(0x05213E, alpha: 0.28)
        shadow.shadowBlurRadius = 18; shadow.shadowOffset = NSSize(width: 0, height: -9); shadow.set()
        color(0xF4FAFF).setFill(); rounded(rect, radius: 53).fill()
        NSGraphicsContext.restoreGraphicsState()
        let configuration = NSImage.SymbolConfiguration(pointSize: 111, weight: .medium)
            .applying(.init(paletteColors: [color(tint)]))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!.withSymbolConfiguration(configuration)!
        let ratio = min(136 / image.size.width, 122 / image.size.height)
        let width = image.size.width * ratio, height = image.size.height * ratio
        image.draw(in: NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height))
    }
    contentTile(x: 182, y: 552, symbol: "folder.fill", tint: 0x167FAD)
    contentTile(x: 182, y: 224, symbol: "doc.fill", tint: 0x237B96)
    contentTile(x: 574, y: 224, symbol: "link", tint: 0x137F88)

    // The small junction reads as a switch even at Dock sizes.
    let junction = rounded(NSRect(x: 540, y: 474, width: 56, height: 56), radius: 28)
    color(0xB5FFDF).setFill(); junction.fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(size: points * scale).write(to: iconset.appendingPathComponent(filename))
    }
}
try render(size: 1024).write(to: resources.appendingPathComponent("AppIcon.png"))
print("Rendered Resources/AppIcon.png and AppIcon.iconset")

// ICNS stores a big-endian header followed by tagged PNG representations.
func bigEndian(_ value: Int) -> Data {
    var number = UInt32(value).bigEndian
    return withUnsafeBytes(of: &number) { Data($0) }
}
let representations = [
    ("icp4", "icon_16x16.png"), ("ic11", "icon_16x16@2x.png"),
    ("icp5", "icon_32x32.png"), ("ic12", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"), ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"), ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png")
]
var payload = Data()
for (tag, filename) in representations {
    let png = try Data(contentsOf: iconset.appendingPathComponent(filename))
    payload.append(Data(tag.utf8)); payload.append(bigEndian(png.count + 8)); payload.append(png)
}
var icns = Data("icns".utf8)
icns.append(bigEndian(payload.count + 8)); icns.append(payload)
try icns.write(to: resources.appendingPathComponent("AppIcon.icns"))
print("Packaged Resources/AppIcon.icns")
