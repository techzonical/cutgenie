// Draws the Cutgenie app icon (timeline clips, a cut, two sparks) into an .iconset, then iconutil makes AppIcon.icns.
import AppKit
// ICON_STYLE=amber (default: amber tile, dark clips) | dark (dark tile, amber clips)
let style = ProcessInfo.processInfo.environment["ICON_STYLE"] ?? "amber"
func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.translateBy(x: 0, y: s); ctx.scaleBy(x: 1, y: -1)        // top-left origin, like the SwiftUI mark
    let m = s * 0.1, t = s - 2 * m                                 // macOS icon grid: tile inset from the edge
    let tile = CGPath(roundedRect: CGRect(x: m, y: m, width: t, height: t), cornerWidth: t * 0.225, cornerHeight: t * 0.225, transform: nil)
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    if style != "clear" { ctx.addPath(tile); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath() }; ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(tile); ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: (style == "light" ? [NSColor(red: 1, green: 0.96, blue: 0.9, alpha: 1).cgColor, NSColor(red: 0.98, green: 0.91, blue: 0.82, alpha: 1).cgColor]
        : style == "amber" ? [NSColor(red: 1, green: 0.76, blue: 0.38, alpha: 1).cgColor, NSColor(red: 0.91, green: 0.56, blue: 0.16, alpha: 1).cgColor]
        : style == "clear" ? [NSColor.clear.cgColor, NSColor.clear.cgColor]
        : [NSColor(red: 0.16, green: 0.13, blue: 0.10, alpha: 1).cgColor, NSColor(red: 0.07, green: 0.06, blue: 0.045, alpha: 1).cgColor]) as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: m, y: m), end: CGPoint(x: m + t, y: m + t), options: [])
    ctx.restoreGState()
    // Cutgenie: three timeline clips, a cut through them, and two sparks (AI) beside the cut. 110-unit grid inside the tile.
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: m + x / 110 * t, y: m + y / 110 * t) }
    func U(_ v: CGFloat) -> CGFloat { v / 110 * t }
    let dark = style == "dark"
    let clip = dark ? NSColor(red: 0.969, green: 0.69, blue: 0.29, alpha: 1) : NSColor(red: 0.12, green: 0.08, blue: 0.04, alpha: 1)
    let cutCol = dark ? NSColor.white : NSColor(red: 1, green: 0.89, blue: 0.71, alpha: 1)
    for (x, y, w) in [(14.0, 27.0, 48.0), (30, 47, 64), (14, 67, 60)] as [(CGFloat, CGFloat, CGFloat)] {
        ctx.addPath(CGPath(roundedRect: CGRect(origin: P(x, y), size: CGSize(width: U(w), height: U(15))), cornerWidth: U(7.5), cornerHeight: U(7.5), transform: nil))
        ctx.setFillColor(clip.cgColor); ctx.fillPath()
    }
    ctx.setStrokeColor(cutCol.cgColor); ctx.setLineWidth(U(8)); ctx.setLineCap(.round)
    ctx.move(to: P(64, 12)); ctx.addLine(to: P(48, 96)); ctx.strokePath()
    // a glint: soft glow behind, then a slim four-point star (taller than wide), then a bright core
    func spark(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ w: CGFloat) {
        let c = P(cx, cy), rv = U(r), rh = U(r * 0.78), k = U(w)
        let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor(white: 1, alpha: 0.55).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: rv * 0.9, options: [])
        ctx.beginPath(); ctx.move(to: CGPoint(x: c.x, y: c.y - rv))
        ctx.addQuadCurve(to: CGPoint(x: c.x + rh, y: c.y), control: CGPoint(x: c.x + k, y: c.y - k))
        ctx.addQuadCurve(to: CGPoint(x: c.x, y: c.y + rv), control: CGPoint(x: c.x + k, y: c.y + k))
        ctx.addQuadCurve(to: CGPoint(x: c.x - rh, y: c.y), control: CGPoint(x: c.x - k, y: c.y + k))
        ctx.addQuadCurve(to: CGPoint(x: c.x, y: c.y - rv), control: CGPoint(x: c.x - k, y: c.y - k))
        ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
        // warm bright core, so it reads as light rather than a flat shape
        let core = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor(red: 1, green: 0.97, blue: 0.86, alpha: 1).cgColor, NSColor(red: 1, green: 0.97, blue: 0.86, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(core, startCenter: c, startRadius: 0, endCenter: c, endRadius: rh * 0.35, options: [])
    }
    spark(80, 30, 12, 0.8)      // the spark (bottom tip stays clear of the middle clip), above the middle clip, right of the cut
    spark(93, 13, 5, 0.3)       // and its small twinkle
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for (n, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: dir.appendingPathComponent("icon_\(n).png"))
}
