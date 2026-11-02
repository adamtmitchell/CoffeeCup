// Draws the CoffeeCup app icon and writes Resources/AppIcon.icns.
// Usage: swift tools/make-icon.swift
//
// The cup is drawn from scratch with bezier paths (styled after the menu bar
// glyph) because Apple's SF Symbols licence doesn't allow symbols in app icons.

import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // Draw on a 1024 grid regardless of output size.
    let s = CGFloat(size) / 1024
    ctx.scaleBy(x: s, y: s)

    // Background tile: macOS icon grid (824pt tile centred in 1024), with a soft drop shadow.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                            xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.35)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    color(0x4E342E).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x8D6E63), ending: color(0x3E2723))!.draw(in: tile, angle: -90)

    let cream = color(0xFFF6E9)
    ctx.translateBy(x: 7, y: -45) // optically centre the cup + handle

    // Steam
    cream.withAlphaComponent(0.75).setStroke()
    for x: CGFloat in [400, 490, 580] {
        let p = NSBezierPath()
        p.lineWidth = 28
        p.lineCapStyle = .round
        p.move(to: NSPoint(x: x, y: 665))
        p.curve(to: NSPoint(x: x, y: 800),
                controlPoint1: NSPoint(x: x - 45, y: 715),
                controlPoint2: NSPoint(x: x + 45, y: 750))
        p.stroke()
    }

    // Handle (drawn first so the cup body covers its inner half)
    cream.setStroke()
    let handle = NSBezierPath(ovalIn: NSRect(x: 612, y: 440, width: 136, height: 136))
    handle.lineWidth = 38
    handle.stroke()

    // Cup body
    cream.setFill()
    let cup = NSBezierPath()
    cup.move(to: NSPoint(x: 295, y: 625))
    cup.line(to: NSPoint(x: 685, y: 625))
    cup.curve(to: NSPoint(x: 590, y: 395),
              controlPoint1: NSPoint(x: 685, y: 480), controlPoint2: NSPoint(x: 655, y: 400))
    cup.line(to: NSPoint(x: 390, y: 395))
    cup.curve(to: NSPoint(x: 295, y: 625),
              controlPoint1: NSPoint(x: 325, y: 400), controlPoint2: NSPoint(x: 295, y: 480))
    cup.close()
    cup.fill()

    // Saucer
    cream.setFill()
    NSBezierPath(roundedRect: NSRect(x: 240, y: 325, width: 500, height: 48), xRadius: 24, yRadius: 24).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = drawIcon(size: base * scale).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
try drawIcon(size: 1024).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("Resources/AppIcon.png"))

let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
