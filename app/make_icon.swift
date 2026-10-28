// Makes the app icon from Resources/AppIcon-source.jpg (the artwork: a rounded blue tile on white) and writes
// Resources/AppIcon.png and Resources/AppIcon.icns.
//   swift make_icon.swift
// The tile is found by where the white ends, cut out with rounded corners, and placed on the macOS icon grid
// (an 824-point rounded square centred on a 1024 canvas, with a soft shadow).
import AppKit

let source = NSImage(contentsOfFile: "Resources/AppIcon-source.jpg")!
let bitmap = NSBitmapImageRep(data: source.tiffRepresentation!)!
let w = bitmap.pixelsWide, h = bitmap.pixelsHigh

// the tile: the first and last clearly coloured pixels along the middle row and column
func coloured(_ x: Int, _ y: Int) -> Bool {
    let c = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    return c.blueComponent - c.redComponent > 0.25
}
let midY = h / 2, midX = w / 2
let left = (0..<w).first { coloured($0, midY) }!, right = (0..<w).last { coloured($0, midY) }!
let top = (0..<h).first { coloured(midX, $0) }!, bottom = (0..<h).last { coloured(midX, $0) }!
// bitmap rows run top-down; NSImage drawing runs bottom-up
let tileInSource = NSRect(x: left, y: h - 1 - bottom, width: right - left + 1, height: bottom - top + 1)
print("Tile in the artwork: \(tileInSource)")

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 24
shadow.set()
NSColor(red: 0.05, green: 0.25, blue: 0.5, alpha: 1).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
shape.addClip()
// a little inside the edge, so none of the artwork's own corners or white shows
source.draw(in: tile, from: tileInSource.insetBy(dx: 6, dy: 6), operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
image.unlockFocus()

let tiff = image.tiffRepresentation!
try! NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))

// Write every size iconutil expects, then pack them into an .icns
let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSImage(data: tiff)!.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
print("Wrote Resources/AppIcon.png and Resources/AppIcon.icns")
