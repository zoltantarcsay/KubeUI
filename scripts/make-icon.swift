// Renders the app icon (a folder holding a pod cube) into the asset catalog.
// Usage: swift scripts/make-icon.swift KubeUI/Assets.xcassets/AppIcon.appiconset
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func render(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    // macOS icon grid: 824pt squircle centred on a 1024 canvas, with a soft drop shadow.
    let plate = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    color(0x2A5FD8).setFill()
    plate.fill()
    ctx.restoreGState()
    NSGradient(starting: color(0x5B9BFF), ending: color(0x1C46B8))!.draw(in: plate, angle: -90)

    // Folder back with tab.
    let back = NSBezierPath()
    back.move(to: NSPoint(x: 236, y: 300))
    back.line(to: NSPoint(x: 236, y: 690))
    back.curve(to: NSPoint(x: 266, y: 720), controlPoint1: NSPoint(x: 236, y: 707), controlPoint2: NSPoint(x: 249, y: 720))
    back.line(to: NSPoint(x: 430, y: 720))
    back.curve(to: NSPoint(x: 462, y: 700), controlPoint1: NSPoint(x: 444, y: 720), controlPoint2: NSPoint(x: 454, y: 712))
    back.line(to: NSPoint(x: 484, y: 668))
    back.line(to: NSPoint(x: 758, y: 668))
    back.curve(to: NSPoint(x: 788, y: 638), controlPoint1: NSPoint(x: 775, y: 668), controlPoint2: NSPoint(x: 788, y: 655))
    back.line(to: NSPoint(x: 788, y: 300))
    back.close()
    NSGradient(starting: color(0xCFE0FF), ending: color(0xA9C6FA))!.draw(in: back, angle: -90)

    // Folder front.
    let front = NSBezierPath(roundedRect: NSRect(x: 220, y: 268, width: 584, height: 382), xRadius: 34, yRadius: 34)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: NSColor.black.withAlphaComponent(0.22).cgColor)
    color(0xF4F8FF).setFill()
    front.fill()
    ctx.restoreGState()
    NSGradient(starting: color(0xFFFFFF), ending: color(0xE3EDFF))!.draw(in: front, angle: -90)

    // Isometric pod cube on the folder.
    let c = NSPoint(x: 512, y: 452), r: CGFloat = 118
    let top = NSPoint(x: c.x, y: c.y + r), bottom = NSPoint(x: c.x, y: c.y - r)
    let ul = NSPoint(x: c.x - r * 0.866, y: c.y + r / 2), ur = NSPoint(x: c.x + r * 0.866, y: c.y + r / 2)
    let ll = NSPoint(x: c.x - r * 0.866, y: c.y - r / 2), lr = NSPoint(x: c.x + r * 0.866, y: c.y - r / 2)
    func face(_ points: [NSPoint], _ fill: NSColor) {
        let p = NSBezierPath()
        p.move(to: points[0])
        points.dropFirst().forEach { p.line(to: $0) }
        p.close()
        p.lineJoinStyle = .round
        fill.setFill()
        p.fill()
        color(0xFFFFFF, 0.9).setStroke()
        p.lineWidth = 7
        p.stroke()
    }
    face([top, ur, c, ul], color(0x6E9BFF))
    face([ul, c, bottom, ll], color(0x326CE5))
    face([c, ur, lr, bottom], color(0x2050B8))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(size: points * scale).representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: outDir.appendingPathComponent("Contents.json"))
