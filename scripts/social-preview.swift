// GitHub social preview (1280×640): icon, name, tagline and a slice of the app.
// Usage: swift scripts/social-preview.swift docs/images/icon.png docs/images/hero-dark.jpg docs/images/social-preview.png
import AppKit

let a = CommandLine.arguments
let icon = NSImage(contentsOfFile: a[1])!
let hero = NSImage(contentsOfFile: a[2])!
let out = URL(fileURLWithPath: a[3])

let W = 1280, H = 640
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

NSGradient(colors: [NSColor(srgbRed: 0.56, green: 0.49, blue: 1.0, alpha: 1),
                    NSColor(srgbRed: 0.17, green: 0.08, blue: 0.54, alpha: 1)])!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -50)

// App window slice on the right (the framed hero minus its padding), with a shadow.
let heroRep = hero.representations.first!
let hw = CGFloat(heroRep.pixelsWide), hh = CGFloat(heroRep.pixelsHigh)
let inset = hw * 150 / 3180                         // frame-screenshot padding, scaled
let windowRect = NSRect(x: inset, y: inset, width: hw - inset * 2, height: hh - inset * 2)
let target = NSRect(x: 650, y: -30, width: 860, height: 900 * windowRect.height / windowRect.width)
NSGraphicsContext.saveGraphicsState()
let sh = NSShadow()
sh.shadowColor = NSColor.black.withAlphaComponent(0.45)
sh.shadowBlurRadius = 40
sh.shadowOffset = NSSize(width: 0, height: -14)
sh.set()
NSBezierPath(roundedRect: target, xRadius: 14, yRadius: 14).addClip()
hero.draw(in: target, from: NSRect(x: windowRect.minX * hero.size.width / hw, y: windowRect.minY * hero.size.height / hh,
                                    width: windowRect.width * hero.size.width / hw, height: windowRect.height * hero.size.height / hh),
          operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

// Icon, name, tagline.
icon.draw(in: NSRect(x: 80, y: 360, width: 150, height: 150))
func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ alpha: CGFloat, _ y: CGFloat) {
    (s as NSString).draw(at: NSPoint(x: 86, y: y), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
    ])
}
text("Wisp", 84, .bold, 1, 250)
text("A native API client for macOS.", 30, .medium, 0.95, 205)
text("Keychain credentials · GraphQL · OpenAPI import", 22, .regular, 0.78, 160)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
