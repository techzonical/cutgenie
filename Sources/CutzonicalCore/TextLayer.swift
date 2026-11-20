import Foundation
import CoreText
import CoreGraphics
import CoreImage
import AppKit

/// A piece of styled text inside a text layer (Final Cut keeps titles as runs too: "GAMING LAPTOP" bold teal, then
/// "THAT FITS YOUR BAG" in white...). Sizes are in project pixels (a 1080p frame is 1080 high).
public struct TextRun: Codable, Equatable {
    public var text: String
    public var font: String = "Helvetica Neue"
    public var size: Double = 72
    public var bold: Bool?
    public var italic: Bool?
    public var color: [Double] = [1, 1, 1, 1]          // r g b a, 0...1
    public var tracking: Double?                        // extra space between letters, px
    public var strokeColor: [Double]?
    public var strokeWidth: Double?                     // px
    public var shadowColor: [Double]?
    public var shadowDistance: Double?                  // px
    public var shadowAngle: Double?                     // degrees, Final Cut style (315 = down right)
    public var shadowBlur: Double?
    public init(text: String) { self.text = text }
}

/// A text layer (Overlay.text): editable words drawn by Cutzonical. The layer's position / scale / opacity / effects work
/// like any graphic; the picture is the text, centred on the layer's position.
public struct TextSpec: Codable, Equatable {
    public var runs: [TextRun]
    public var align: String = "center"                 // left | center | right
    public var lineSpacing: Double?                     // extra px between lines
    public var width: Double?                           // wrap width in px (nil = no wrapping)
    public init(runs: [TextRun]) { self.runs = runs }
    public var plain: String { runs.map(\.text).joined() }
}

public enum TextRender {
    nonisolated(unsafe) static var specs: [String: TextSpec] = [:]
    nonisolated(unsafe) static var images: [String: CGImage] = [:]
    static let lock = NSLock()

    /// a stable name for this look of the text (used as the layer's "path" in the image caches)
    public static func key(_ s: TextSpec) -> String {
        let d = (try? JSONEncoder().encode(s)) ?? Data()
        var h: UInt64 = 1469598103934665603
        for b in d { h = (h ^ UInt64(b)) &* 1099511628211 }
        let k = "text:\(String(h, radix: 16))"
        lock.lock(); specs[k] = s; lock.unlock()
        return k
    }

    static func color(_ c: [Double]?) -> NSColor? {
        guard let c, c.count >= 3 else { return nil }
        return NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c.count > 3 ? c[3] : 1)
    }

    static func font(_ r: TextRun) -> NSFont {
        var f = NSFont(name: r.font, size: r.size) ?? NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: r.font]), size: r.size)
            ?? NSFont.systemFont(ofSize: r.size)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if r.bold == true { traits.insert(.bold) }
        if r.italic == true { traits.insert(.italic) }
        if !traits.isEmpty {
            let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(traits))
            f = NSFont(descriptor: d, size: r.size) ?? f
        }
        return f
    }

    /// the same text with only the first part visible (fraction 0...1 of the letters, or of the words); hidden letters keep their
    /// place so the layout does not move while it types on
    public static func reveal(_ s: TextSpec, _ f: Double, words: Bool) -> TextSpec {
        let all = Array(s.plain)
        var n = Int((Double(all.count) * f).rounded(.down))
        if words {
            let starts = all.indices.filter { $0 == 0 || (all[$0 - 1].isWhitespace && !all[$0].isWhitespace) }
            let k = Int((Double(starts.count) * f).rounded(.down))
            n = k >= starts.count ? all.count : starts[k]
        }
        var out = s; out.runs = []
        var i = 0
        for r in s.runs {
            let c = Array(r.text), cut = max(0, min(c.count, n - i)); i += c.count
            if cut > 0 { var a = r; a.text = String(c[..<cut]); out.runs.append(a) }
            if cut < c.count {
                var b = r; b.text = String(c[cut...])
                b.color = [b.color[0], b.color[1], b.color[2], 0]
                if let sc = b.strokeColor, sc.count >= 3 { b.strokeColor = [sc[0], sc[1], sc[2], 0] }
                out.runs.append(b)
            }
        }
        return out
    }

    public static func attributed(_ s: TextSpec) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let ps = NSMutableParagraphStyle()
        ps.alignment = s.align == "left" ? .left : s.align == "right" ? .right : .center
        ps.lineSpacing = s.lineSpacing ?? 0
        for r in s.runs {
            var a: [NSAttributedString.Key: Any] = [.font: font(r), .foregroundColor: color(r.color) ?? .white, .paragraphStyle: ps]
            if let t = r.tracking, t != 0 { a[.kern] = t }
            if let w = r.strokeWidth, w > 0, let c = color(r.strokeColor) {
                a[.strokeColor] = c; a[.strokeWidth] = -100 * w / max(1, r.size)     // negative = fill and outline
            }
            out.append(NSAttributedString(string: r.text, attributes: a))
        }
        return out
    }

    /// the text drawn on a transparent picture, 1 pixel = 1 project pixel; padded for shadows and outlines
    public static func cgImage(_ key: String) -> CGImage? {
        lock.lock(); if let i = images[key] { lock.unlock(); return i }; let spec = specs[key]; lock.unlock()
        guard let s = spec else { return nil }
        let str = attributed(s)
        let fs = CTFramesetterCreateWithAttributedString(str)
        let maxW = s.width.map { CGFloat($0) } ?? CGFloat.greatestFiniteMagnitude
        var fit = CFRange()
        let size = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: str.length), nil, CGSize(width: maxW, height: .greatestFiniteMagnitude), &fit)
        let shadow = s.runs.compactMap { r -> CGFloat? in guard r.shadowColor != nil else { return nil }; return CGFloat((r.shadowDistance ?? 0) + (r.shadowBlur ?? 0) * 2) }.max() ?? 0
        let stroke = CGFloat(s.runs.compactMap(\.strokeWidth).max() ?? 0)
        let pad = ceil(max(4, shadow + stroke + 2))
        let tw = ceil(max(1, s.width.map { CGFloat($0) } ?? size.width)), th = ceil(max(1, size.height))
        // Final Cut centres a title a little above the middle of its text block: extra room on top moves the words down to match
        let top = ceil(CGFloat(s.runs.map(\.size).max() ?? 0) * 0.95)
        let W = Int(tw + pad * 2), H = Int(th + pad * 2 + top)
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let r = s.runs.first(where: { $0.shadowColor != nil }), let c = color(r.shadowColor) {
            let a = (r.shadowAngle ?? 315) * .pi / 180, d = r.shadowDistance ?? 0
            ctx.setShadow(offset: CGSize(width: cos(a) * d, height: sin(a) * d), blur: CGFloat(r.shadowBlur ?? 0), color: c.cgColor)
        }
        let path = CGPath(rect: CGRect(x: pad, y: pad, width: tw, height: th), transform: nil)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: str.length), path, nil)
        CTFrameDraw(frame, ctx)
        guard let img = ctx.makeImage() else { return nil }
        lock.lock(); images[key] = img; if images.count > 400 { images.removeAll() ; images[key] = img }; lock.unlock()
        return img
    }

    public static func ciImage(_ key: String) -> CIImage? { cgImage(key).map { CIImage(cgImage: $0, options: [.colorSpace: NSNull()]) } }
}
