import AppKit
import CoreImage

// Draws the lower third into a transparent image the size of the frame.
// Colours follow look A "HUD scan" from the TechZonical style kit
// (accent #3DD9C5, panel rgba(7,26,36,.78), sub #8fb7b9). System fonts for now.
public enum LowerThirdImage {
    public static func make(_ lt: LowerThird, width: Int, height: Int) -> CIImage? {
        let s = CGFloat(width) / 1920
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        defer { NSGraphicsContext.restoreGraphicsState() }

        let teal = NSColor(srgbRed: 0.239, green: 0.851, blue: 0.773, alpha: 1)
        let panel = NSColor(srgbRed: 7/255, green: 26/255, blue: 36/255, alpha: 0.82)
        let sub = NSColor(srgbRed: 0.56, green: 0.72, blue: 0.73, alpha: 1)

        let x = 96*s, y = 120*s, w = 820*s, h = 170*s, cut = 26*s
        // cut-corner panel (origin bottom-left in AppKit)
        let p = NSBezierPath()
        p.move(to: NSPoint(x: x, y: y))
        p.line(to: NSPoint(x: x+w, y: y))
        p.line(to: NSPoint(x: x+w, y: y+h-cut))
        p.line(to: NSPoint(x: x+w-cut, y: y+h))
        p.line(to: NSPoint(x: x, y: y+h))
        p.close()
        panel.setFill(); p.fill()
        teal.setFill()
        NSBezierPath(rect: NSRect(x: x, y: y, width: 8*s, height: h)).fill()

        // tag chip
        let tagAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 26*s, weight: .bold),
            .foregroundColor: NSColor(srgbRed: 0.02, green: 0.08, blue: 0.1, alpha: 1),
            .kern: 2*s]
        let tagStr = NSAttributedString(string: lt.tag.uppercased(), attributes: tagAttrs)
        let tsz = tagStr.size()
        let chip = NSRect(x: x+36*s, y: y+h-24*s-(tsz.height+12*s), width: tsz.width+28*s, height: tsz.height+12*s)
        teal.setFill(); NSBezierPath(rect: chip).fill()
        tagStr.draw(at: NSPoint(x: chip.minX+14*s, y: chip.minY+6*s))

        // title + sub line
        let titleStr = NSAttributedString(string: lt.title, attributes: [
            .font: NSFont.systemFont(ofSize: 54*s, weight: .bold), .foregroundColor: NSColor.white])
        titleStr.draw(at: NSPoint(x: x+36*s, y: y+46*s))
        let subStr = NSAttributedString(string: lt.sub, attributes: [
            .font: NSFont.systemFont(ofSize: 28*s, weight: .medium), .foregroundColor: sub])
        subStr.draw(at: NSPoint(x: x+36*s, y: y+10*s))

        gc.flushGraphics()
        guard let cg = rep.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }
}
