// Frames raw window captures for the README: rounded window, soft shadow, brand gradient background.
// Usage: swift scripts/frame-screenshot.swift <window.png> [sheet.png|-] <out.jpg> [light]
import AppKit

let args = CommandLine.arguments
guard args.count >= 4, let window = NSImage(contentsOfFile: args[1]) else {
    print("usage: frame-screenshot <window.png> [sheet.png|-] <out.jpg> [light]")
    exit(1)
}
let sheet = args[2] == "-" ? nil : NSImage(contentsOfFile: args[2])
let outURL = URL(fileURLWithPath: args[3])
let light = args.count > 4 && args[4] == "light"

// Work in pixels (captures are @2x).
func pixels(_ img: NSImage) -> NSSize {
    let rep = img.representations.first!
    return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
}
let win = pixels(window)
let pad: CGFloat = 150
let canvas = NSSize(width: win.width + pad * 2, height: win.height + pad * 2)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width), pixelsHigh: Int(canvas.height),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background: the app icon's violet, softened for light screenshots.
let colors = light
    ? [NSColor(srgbRed: 0.80, green: 0.76, blue: 1.0, alpha: 1), NSColor(srgbRed: 0.60, green: 0.52, blue: 0.98, alpha: 1)]
    : [NSColor(srgbRed: 0.56, green: 0.49, blue: 1.0, alpha: 1), NSColor(srgbRed: 0.17, green: 0.08, blue: 0.54, alpha: 1)]
NSGradient(colors: colors)!.draw(in: NSRect(origin: .zero, size: canvas), angle: -55)

// Window: rounded corners + shadow.
let frame = NSRect(x: pad, y: pad, width: win.width, height: win.height)
let radius: CGFloat = 22
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
shadow.shadowBlurRadius = 70
shadow.shadowOffset = NSSize(width: 0, height: -24)
shadow.set()
NSColor.black.setFill()
NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).addClip()
window.draw(in: frame)
// Sheet: centered, hanging from just below the toolbar (where macOS attaches it).
if let sheet {
    let s = pixels(sheet)
    let toolbar: CGFloat = 104
    let sheetFrame = NSRect(x: frame.midX - s.width / 2, y: frame.maxY - toolbar - s.height, width: s.width, height: s.height)
    NSColor.black.withAlphaComponent(0.18).setFill()
    frame.fill(using: .sourceOver)
    NSGraphicsContext.saveGraphicsState()
    let ss = NSShadow()
    ss.shadowColor = NSColor.black.withAlphaComponent(0.5)
    ss.shadowBlurRadius = 40
    ss.shadowOffset = NSSize(width: 0, height: -12)
    ss.set()
    NSBezierPath(roundedRect: sheetFrame, xRadius: 18, yRadius: 18).addClip()
    sheet.draw(in: sheetFrame)
    NSGraphicsContext.restoreGraphicsState()
}
NSGraphicsContext.restoreGraphicsState()
// Hairline edge like a real macOS window.
NSColor.white.withAlphaComponent(light ? 0.0 : 0.12).setStroke()
let edge = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
edge.lineWidth = 1
edge.stroke()
NSGraphicsContext.restoreGraphicsState()

// Downscale to 2400 px wide and save as high-quality JPEG (keeps the repo light).
let target: CGFloat = 2400
let scale = target / canvas.width
let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(target), pixelsHigh: Int(canvas.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
NSGraphicsContext.current?.imageInterpolation = .high
let full = NSImage(size: canvas)
full.addRepresentation(rep)
full.draw(in: NSRect(x: 0, y: 0, width: target, height: canvas.height * scale))
NSGraphicsContext.restoreGraphicsState()
try! out.representation(using: .jpeg, properties: [.compressionFactor: 0.88])!.write(to: outURL)
