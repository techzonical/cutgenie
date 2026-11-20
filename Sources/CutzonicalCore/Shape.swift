import Foundation
import AppKit
import CoreImage

// Shape layers (rectangle, rounded box, circle, line), generators (solid colour, gradient) and shape masks.
// Shapes are drawn by Cutzonical like text layers: the layer's "path" is "shape:<key>", 1 pixel = 1 project pixel.

public struct ShapeSpec: Codable, Equatable {
    public var kind: String = "rect"                 // rect | circle | line | solid | gradient
    public var w: Double = 600                       // size in project pixels (solid / gradient: the frame size)
    public var h: Double = 300
    public var radius: Double?                       // rect: corner radius px
    public var fill: [Double]? = [1, 0.62, 0.1, 1]   // rgba 0...1; nil = no fill
    public var fill2: [Double]?                      // gradient: end colour
    public var angle: Double?                        // gradient: direction in degrees (0 = left to right, 90 = bottom to top)
    public var strokeColor: [Double]?
    public var strokeWidth: Double?                  // px; line: its thickness
    // blur area: hides what is under it (text, a face, a number plate)
    public var style: String?                        // blur | pixelate
    public var amount: Double?                       // blur strength px / pixel block size px
    public var round: Bool?                          // an oval area instead of a rectangle
    public var feather: Double?                      // soft edge px
    public var lock: Bool?                           // keep width : height when resizing
    public init(kind: String, w: Double, h: Double) { self.kind = kind; self.w = w; self.h = h }
    public static let kinds: [(id: String, name: String)] = [
        ("rect", "Rectangle"), ("circle", "Circle"), ("line", "Line"), ("solid", "Solid colour"), ("gradient", "Gradient"), ("blur", "Blur area (hide text)"),
    ]
}

/// a shape that cuts a layer: only the inside (or, inverted, the outside) stays visible
public struct MaskSpec: Codable, Equatable {
    public var kind: String = "rect"                 // rect | circle
    public var x: Double = 0, y: Double = 0          // centre, px from the layer's centre (x right, y up)
    public var w: Double = 400, h: Double = 300
    public var radius: Double?                       // rect corner radius
    public var feather: Double?                      // soft edge px
    public var invert: Bool?
    public init() {}
}

public enum ShapeRender {
    nonisolated(unsafe) static var specs: [String: ShapeSpec] = [:]
    nonisolated(unsafe) static var images: [String: CGImage] = [:]
    static let lock = NSLock()

    public static func key(_ s: ShapeSpec) -> String {
        let d = (try? JSONEncoder().encode(s)) ?? Data()
        var h: UInt64 = 1469598103934665603
        for b in d { h = (h ^ UInt64(b)) &* 1099511628211 }
        let k = "shape:\(String(h, radix: 16))"
        lock.lock(); specs[k] = s; lock.unlock()
        return k
    }
    static func cg(_ c: [Double]?) -> CGColor? {
        guard let c, c.count >= 3 else { return nil }
        return CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c.count > 3 ? c[3] : 1)
    }

    public static func cgImage(_ key: String) -> CGImage? {
        lock.lock(); if let i = images[key] { lock.unlock(); return i }; let spec = specs[key]; lock.unlock()
        guard let s = spec else { return nil }
        let sw = s.kind == "line" ? 0 : max(0, s.strokeWidth ?? 0)
        let pad = ceil(sw / 2 + 2)
        let lineT = max(1, s.strokeWidth ?? 8)
        let w = max(1, s.w), h = s.kind == "line" ? lineT : max(1, s.h)
        let W = Int(ceil(w + pad * 2)), H = Int(ceil(h + pad * 2))
        guard W < 16384, H < 16384, let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let r = CGRect(x: pad, y: pad, width: w, height: h)
        switch s.kind {
        case "solid":
            ctx.setFillColor(cg(s.fill) ?? .black); ctx.fill(r)
        case "gradient":
            let a = (s.angle ?? 0) * .pi / 180, c = CGPoint(x: r.midX, y: r.midY)
            let half = (abs(cos(a)) * w + abs(sin(a)) * h) / 2
            let p0 = CGPoint(x: c.x - cos(a) * half, y: c.y - sin(a) * half), p1 = CGPoint(x: c.x + cos(a) * half, y: c.y + sin(a) * half)
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [cg(s.fill) ?? .black, cg(s.fill2) ?? .white] as CFArray, locations: [0, 1]) {
                ctx.clip(to: r); ctx.drawLinearGradient(g, start: p0, end: p1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        case "line":
            ctx.setFillColor(cg(s.fill) ?? .white)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)); ctx.fillPath()
        default:
            let inner = r.insetBy(dx: sw / 2, dy: sw / 2)
            let path: CGPath = s.kind == "circle" || (s.kind == "blur" && s.round == true) ? CGPath(ellipseIn: inner, transform: nil)
                : { let rr = min(s.radius ?? 0, min(inner.width, inner.height) / 2); return CGPath(roundedRect: inner, cornerWidth: rr, cornerHeight: rr, transform: nil) }()
            // a blur area is drawn as a plain white shape: it is only used as the outline of the part to blur
            if s.kind == "blur" { ctx.setFillColor(.white); ctx.addPath(path); ctx.fillPath() }
            else if let f = cg(s.fill) { ctx.setFillColor(f); ctx.addPath(path); ctx.fillPath() }
            if sw > 0, let sc = cg(s.strokeColor) { ctx.setStrokeColor(sc); ctx.setLineWidth(sw); ctx.addPath(path); ctx.strokePath() }
        }
        guard let img = ctx.makeImage() else { return nil }
        lock.lock(); images[key] = img; if images.count > 200 { images.removeAll(); images[key] = img }; lock.unlock()
        return img
    }
    public static func ciImage(_ key: String) -> CIImage? { cgImage(key).map { CIImage(cgImage: $0, options: [.colorSpace: NSNull()]) } }

    /// keeps the part of `img` inside the mask (outside when inverted), soft edge = feather
    static func applyMask(_ m: MaskSpec, to img: CIImage) -> CIImage {
        let e = img.extent
        let W = Int(ceil(e.width)), H = Int(ceil(e.height))
        guard W > 0, H > 0, W < 16384, H < 16384, let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        let inv = m.invert == true
        ctx.setFillColor(inv ? .white : .black); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let r = CGRect(x: e.width / 2 + m.x - m.w / 2, y: e.height / 2 + m.y - m.h / 2, width: max(1, m.w), height: max(1, m.h))
        let rr = min(m.radius ?? 0, min(r.width, r.height) / 2)
        ctx.setFillColor(inv ? .black : .white)
        ctx.addPath(m.kind == "circle" ? CGPath(ellipseIn: r, transform: nil) : CGPath(roundedRect: r, cornerWidth: rr, cornerHeight: rr, transform: nil))
        ctx.fillPath()
        guard let cgm = ctx.makeImage() else { return img }
        var mask = CIImage(cgImage: cgm, options: [.colorSpace: NSNull()]).transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
        if let f = m.feather, f > 0.3 { mask = mask.clampedToExtent().applyingGaussianBlur(sigma: f / 2).cropped(to: e) }
        return img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
    }
}
