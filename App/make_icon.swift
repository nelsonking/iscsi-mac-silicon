// Generates the app icon (blue→violet rounded square with a drive + link glyph)
// at every required size using CoreGraphics only. No external assets.
//   swift make_icon.swift <output-dir>
import AppKit

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size

    // macOS icon grid: content inset ~ 10%, corner radius ~ 22.4% of the tile.
    let inset = s * 0.085
    let rect = CGRect(x: inset, y: inset, width: s - inset*2, height: s - inset*2)
    let radius = rect.width * 0.2237
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Background gradient (top-lit blue to violet).
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let colors = [NSColor(srgbRed: 0.16, green: 0.55, blue: 1.0, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.42, green: 0.34, blue: 1.0, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    // Soft top sheen: a white gradient that fades to nothing (no hard edge).
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor.white.withAlphaComponent(0.16).cgColor,
                                    NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.midY), options: [])
    ctx.restoreGState()

    // Drive body (rounded rectangle) centered.
    let dw = rect.width * 0.52, dh = rect.height * 0.34
    let drive = CGRect(x: rect.midX - dw/2, y: rect.midY - dh/2, width: dw, height: dh)
    let dPath = CGPath(roundedRect: drive, cornerWidth: dh*0.28, cornerHeight: dh*0.28, transform: nil)
    ctx.setShadow(offset: CGSize(width: 0, height: -s*0.01), blur: s*0.03, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    ctx.setFillColor(NSColor.white.cgColor); ctx.addPath(dPath); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Activity LED.
    let led = CGRect(x: drive.minX + dw*0.12, y: drive.midY - dh*0.09, width: dh*0.18, height: dh*0.18)
    ctx.setFillColor(NSColor(srgbRed: 0.18, green: 0.8, blue: 0.44, alpha: 1).cgColor); ctx.fillEllipse(in: led)

    // Network arcs (wifi-like) rising from the drive, in blue.
    ctx.setStrokeColor(NSColor(srgbRed: 0.18, green: 0.5, blue: 1.0, alpha: 1).cgColor)
    ctx.setLineCap(.round)
    let cx = drive.midX + dw*0.16, cy = drive.midY
    for (i, r) in [dh*0.55, dh*0.95, dh*1.35].enumerated() {
        ctx.setLineWidth(s * (0.02 - Double(i)*0.001))
        ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .pi*0.12, endAngle: .pi*0.88, clockwise: false)
        ctx.strokePath()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = (outDir as NSString).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let specs: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in specs {
    let rep = drawIcon(size: px)
    let data = rep.representation(using: .png, properties: [:])!
    let file = (iconset as NSString).appendingPathComponent("\(name).png")
    try! data.write(to: URL(fileURLWithPath: file))
}
print("iconset written to \(iconset)")
