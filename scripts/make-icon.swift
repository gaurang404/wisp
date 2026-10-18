// Renders the Wisp app icon into an .iconset directory: swift scripts/make-icon.swift <out.iconset> [preview.png]
// A glowing "wisp" — a request in flight with a flowing, tapered tail — on an indigo squircle.
import AppKit

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func gradient(_ stops: [(UInt32, CGFloat)], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: stops.map { color($0.0, $0.1) } as CFArray, locations: locations)!
}

/// Superellipse (n = 5) — close to Apple's continuous-corner icon shape.
func squircle(_ r: CGRect) -> CGPath {
    let p = CGMutablePath(), n: CGFloat = 5
    for i in 0...720 {
        let t = CGFloat(i) * .pi / 360, c = cos(t), s = sin(t)
        let pt = CGPoint(x: r.midX + r.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n),
                         y: r.midY + r.height / 2 * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n))
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}

func cubic(_ p: [CGPoint], _ t: CGFloat) -> CGPoint {
    let u = 1 - t
    return CGPoint(x: u*u*u*p[0].x + 3*u*u*t*p[1].x + 3*u*t*t*p[2].x + t*t*t*p[3].x,
                   y: u*u*u*p[0].y + 3*u*u*t*p[1].y + 3*u*t*t*p[2].y + t*t*t*p[3].y)
}

/// Ribbon along a cubic Bézier, hair-thin at the start and up to `width` wide near the end.
func ribbon(_ p: [CGPoint], width: CGFloat) -> CGPath {
    var left: [CGPoint] = [], right: [CGPoint] = []
    for i in 0...160 {
        let t = CGFloat(i) / 160
        let a = cubic(p, max(0, t - 0.001)), b = cubic(p, min(1, t + 0.001)), c = cubic(p, t)
        let len = max(0.0001, hypot(b.x - a.x, b.y - a.y))
        let nx = -(b.y - a.y) / len, ny = (b.x - a.x) / len
        // Grow toward the head, then round off the last stretch so the end tucks under the glowing core.
        let cap = t > 0.86 ? sqrt(max(0, 1 - pow((t - 0.86) / 0.14, 2))) : 1
        let w = width / 2 * pow(t, 1.35) * max(cap, 0.35)
        left.append(CGPoint(x: c.x + nx * w, y: c.y + ny * w))
        right.append(CGPoint(x: c.x - nx * w, y: c.y - ny * w))
    }
    let path = CGMutablePath()
    path.addLines(between: left + right.reversed())
    path.closeSubpath()
    return path
}

func renderMaster() -> CGImage {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let shape = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))
    let glow: UInt32 = 0x9EE8FF
    let head = CGPoint(x: 650, y: 650)

    // Drop shadow (macOS icon grid style)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape); ctx.setFillColor(color(0x2A128A)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.drawLinearGradient(gradient([(0x8E7CFF, 1), (0x2A128A, 1)], [0, 1]),
                           start: CGPoint(x: 200, y: 960), end: CGPoint(x: 820, y: 64),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let light = gradient([(0xFFFFFF, 0.22), (0xFFFFFF, 0)], [0, 1])
    ctx.drawRadialGradient(light, startCenter: CGPoint(x: 300, y: 860), startRadius: 0,
                           endCenter: CGPoint(x: 300, y: 860), endRadius: 620, options: [])
    let ambient = gradient([(glow, 0.35), (glow, 0)], [0, 1])
    ctx.drawRadialGradient(ambient, startCenter: head, startRadius: 0, endCenter: head, endRadius: 420, options: [])

    // Tail: two faint side strands, then the main one on top.
    let strands: [([CGPoint], CGFloat, CGFloat)] = [
        ([CGPoint(x: 420, y: 176), CGPoint(x: 600, y: 230), CGPoint(x: 560, y: 560), head], 74, 0.5),
        ([CGPoint(x: 196, y: 470), CGPoint(x: 380, y: 430), CGPoint(x: 470, y: 690), head], 74, 0.55),
        ([CGPoint(x: 214, y: 268), CGPoint(x: 430, y: 214), CGPoint(x: 470, y: 600), head], 156, 1.0),
    ]
    for (pts, width, alpha) in strands {
        ctx.saveGState()
        ctx.addPath(ribbon(pts, width: width)); ctx.clip()
        let g = gradient([(0xFFFFFF, 0), (glow, 0.7 * alpha), (0xFFFFFF, alpha)], [0, 0.55, 1])
        ctx.drawLinearGradient(g, start: pts[0], end: head, options: [])
        ctx.restoreGState()
    }

    // Halo + bright core
    ctx.drawRadialGradient(gradient([(glow, 0.9), (glow, 0)], [0, 1]),
                           startCenter: head, startRadius: 50, endCenter: head, endRadius: 190, options: [])
    ctx.drawRadialGradient(gradient([(0xFFFFFF, 1), (0xFFFFFF, 1), (glow, 1)], [0, 0.55, 1]),
                           startCenter: CGPoint(x: head.x - 14, y: head.y + 14), startRadius: 0,
                           endCenter: head, endRadius: 62, options: [])

    // Sparkles
    for (p, r, a) in [(CGPoint(x: 312, y: 742), CGFloat(11), CGFloat(0.7)),
                      (CGPoint(x: 790, y: 380), 8, 0.55), (CGPoint(x: 400, y: 840), 6, 0.4)] {
        ctx.setFillColor(color(0xFFFFFF, a))
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }
    ctx.restoreGState()

    // Hairline edge
    ctx.addPath(shape); ctx.setStrokeColor(color(0xFFFFFF, 0.12)); ctx.setLineWidth(3); ctx.strokePath()
    return ctx.makeImage()!
}

func png(_ image: CGImage, size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let master = renderMaster()
for base in [16, 32, 128, 256, 512] {
    try! png(master, size: base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! png(master, size: base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if args.count > 2 { try! png(master, size: 1024).write(to: URL(fileURLWithPath: args[2])) }
