import AppKit
// Regenerate: swift tools/make_icon.swift App/Assets.xcassets/AppIcon.appiconset/AppIcon.png

// CarLyrics icon: night-drive gradient, three lyric lines; the current (middle) one is lit
// karaoke-style. Drawn from shapes — SF Symbols aren't licensed for app icons.
let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
func rgb(_ hex: Int, _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: a)
}
// Background: deep navy (bottom) to violet (top).
NSGradient(colors: [rgb(0x0B1030), rgb(0x2A1660), rgb(0x5B2A86)])!.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: 90)
// Soft glow behind the lit line.
NSGradient(colors: [rgb(0xFF6FA8, 0.38), rgb(0xFF6FA8, 0)])!
    .draw(fromCenter: NSPoint(x: 512, y: 512), radius: 0, toCenter: NSPoint(x: 512, y: 512), radius: 440, options: [])

func bar(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: h / 2, yRadius: h / 2)
}
// Past line (top) and next line (bottom), dim.
rgb(0xFFFFFF, 0.28).setFill()
bar(196, 676, 520, 64).fill()
bar(196, 284, 420, 64).fill()
// Current line: white, with the sung part filled pink → amber.
let current = bar(196, 462, 632, 100)
rgb(0xFFFFFF).setFill()
current.fill()
NSGraphicsContext.current!.saveGraphicsState()
current.addClip()
NSGradient(colors: [rgb(0xFF5F9E), rgb(0xFFB45E)])!.draw(in: NSRect(x: 196, y: 462, width: 400, height: 100), angle: 0)
NSGraphicsContext.current!.restoreGraphicsState()

// Eighth note beside the past line: tilted head, stem, curled flag.
rgb(0xFFFFFF, 0.92).setFill()
let head = NSBezierPath(ovalIn: NSRect(x: -52, y: -38, width: 104, height: 76))
var tilt = AffineTransform(translationByX: 790, byY: 676)
tilt.rotate(byDegrees: 22)
head.transform(using: tilt)
head.fill()
bar(822, 690, 24, 210).fill()
let flag = NSBezierPath()
flag.move(to: NSPoint(x: 834, y: 900))
flag.curve(to: NSPoint(x: 900, y: 760), controlPoint1: NSPoint(x: 850, y: 840), controlPoint2: NSPoint(x: 930, y: 830))
flag.curve(to: NSPoint(x: 834, y: 840), controlPoint1: NSPoint(x: 890, y: 800), controlPoint2: NSPoint(x: 860, y: 810))
flag.close()
flag.fill()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
