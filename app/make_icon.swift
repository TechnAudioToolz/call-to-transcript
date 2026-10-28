// Draws the app icon (a recording sound wave turning into two speakers' lines of text) and writes
// Resources/AppIcon.icns.
//   swift make_icon.swift
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS icon grid: an 824-point rounded square centred on the 1024 canvas, with a soft shadow
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 24
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSGradient(starting: NSColor(red: 0.07, green: 0.24, blue: 0.26, alpha: 1),
           ending: NSColor(red: 0.10, green: 0.52, blue: 0.45, alpha: 1))!.draw(in: tile, angle: -60)

// the page
let page = NSRect(x: 380, y: 230, width: 420, height: 560)
NSGraphicsContext.saveGraphicsState()
let pageShadow = NSShadow()
pageShadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
pageShadow.shadowOffset = NSSize(width: 0, height: -8)
pageShadow.shadowBlurRadius = 20
pageShadow.set()
NSColor(white: 0.97, alpha: 1).setFill()
NSBezierPath(roundedRect: page, xRadius: 36, yRadius: 36).fill()
NSGraphicsContext.restoreGraphicsState()

// lines of text: a speaker name in colour, then its words, for each side of the call
let accents = [NSColor(red: 0.95, green: 0.55, blue: 0.20, alpha: 1), NSColor(red: 0.20, green: 0.50, blue: 0.85, alpha: 1)]
let ink = NSColor(white: 0.62, alpha: 1)
var y: CGFloat = 700
for (p, paragraph) in [[0.45, 0.8, 0.72, 0.55], [0.38, 0.8, 0.66]].enumerated() {
    for (i, width) in paragraph.enumerated() {
        (i == 0 ? accents[p] : ink).setFill()
        NSBezierPath(roundedRect: NSRect(x: 430, y: y, width: 320 * width, height: 30), xRadius: 15, yRadius: 15).fill()
        y -= i == 0 ? 56 : 50
    }
    y -= 30
}

// the sound wave, coming in from the left
let bars: [CGFloat] = [90, 200, 330, 220, 130]
for (i, height) in bars.enumerated() {
    NSColor.white.setFill()
    let x = 165 + CGFloat(i) * 42
    NSBezierPath(roundedRect: NSRect(x: x, y: 510 - height / 2, width: 26, height: height), xRadius: 13, yRadius: 13).fill()
}

// the red recording dot
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: 168, y: 692, width: 132, height: 132)).fill()
NSColor(red: 0.92, green: 0.18, blue: 0.20, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 184, y: 708, width: 100, height: 100)).fill()
NSGraphicsContext.restoreGraphicsState()
image.unlockFocus()

// Write every size iconutil expects, then pack them into an .icns
let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let tiff = image.tiffRepresentation!
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(data: tiff)!.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
