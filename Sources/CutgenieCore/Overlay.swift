import Foundation
import CoreImage
import ImageIO

// A graphic layer (PNG/still) above or below the main storyline, Final Cut style:
// lane > 0 = above the main picture (higher lanes on top), lane < 0 = below (only visible where the main storyline has no picture).
// Position is in Final Cut units: percent of the frame height from the centre, y up (1 unit = height/100 px).
public struct Keyframe: Codable, Equatable {
    public var t: Double; public var v: [Double]
    public var e: String? = nil       // easing of the move INTO this keyframe: nil/linear, in, out, s (in & out), strong, back, bounce, "bez:x1,y1,x2,y2"
    public init(t: Double, v: [Double], e: String? = nil) { self.t = t; self.v = v; self.e = e }
}
public struct Overlay: Codable, Equatable {
    public var id: String
    public var name: String = ""
    public var asset: String
    public var lane: Int = 1
    public var offset: Double
    public var duration: Double
    public var conform: String = "fit"          // fit | fill | none
    public var position: [Keyframe] = []        // t is seconds from the layer's start; v = [x, y]
    public var scale: [Keyframe] = []           // v = [sx, sy]
    public var opacity: [Keyframe] = []         // v = [0...1]
    public var connectedTo: String?             // main-storyline clip this graphic belongs to (moves with it), Final Cut style
    // Effects panel
    public var rotation: [Keyframe]?            // degrees, counter-clockwise
    public var crop: [Double]?                  // left, right, top, bottom (0...0.49 of the layer)
    public var blend: String?                   // normal | screen | multiply | add | overlay | lighten | darken
    public var fadeIn: Double?                  // seconds
    public var fadeOut: Double?
    public var effects: [LayerEffect]?          // applied in order, on the layer itself (before moving / scaling)
    public var disabled: Bool?                  // switched off (V key): not drawn, stays on the timeline
    public var text: TextSpec?                  // set = text layer: editable words drawn by Cutgenie (asset is empty)
    public var adjust: ColorParams?             // set = adjustment layer: no picture of its own, grades everything below it (opacity = mix)
    public var anchor: [Double]?                // pivot for scale / rotation: source pixels from the image centre (x right, y up)
    public var shape: ShapeSpec?                // set = shape / solid / gradient layer drawn by Cutgenie (asset is empty)
    public var mask: MaskSpec?                  // shape mask: cuts the layer
    public var behaviours: [Behaviour]?         // ongoing motion added on top: wiggle, drift, pulse, spin
    public var buildIn: Build?                  // ready-made entrance animation (Final Cut style Build In)
    public var buildOut: Build?                 // ready-made exit animation
}

/// a behaviour: motion that runs for the whole layer without keyframes (Final Cut / Motion style)
public struct Behaviour: Codable, Equatable, Identifiable {
    public var id: String = UUID().uuidString
    public var type: String                     // wiggle | drift | pulse | spin
    public var on: Bool = true
    public var amount: Double                   // wiggle: px; drift: px per second; pulse: % bigger; spin: unused
    public var speed: Double                    // wiggle / pulse: times per second; spin: degrees per second
    public var angle: Double?                   // drift: direction in degrees (0 = right, 90 = up)
    public init(type: String) {
        self.type = type
        switch type { case "wiggle": amount = 12; speed = 1.5; case "drift": amount = 20; speed = 0; angle = 0
        case "pulse": amount = 5; speed = 1; default: amount = 0; speed = 45 }
    }
    public static let types: [(id: String, name: String)] = [("wiggle", "Wiggle"), ("drift", "Drift"), ("pulse", "Pulse"), ("spin", "Spin")]
    /// smooth wandering value -1...1 (a few sine waves that never quite repeat)
    static func wander(_ t: Double, _ seed: Double) -> Double {
        (sin(t * 1.0 + seed) * 0.5 + sin(t * 2.31 + seed * 1.7) * 0.3 + sin(t * 4.13 + seed * 2.9) * 0.2)
    }
}

/// a Build In / Build Out animation, worked out while drawing (keyframes stay free for your own moves)
public struct Build: Codable, Equatable {
    public var type: String                     // fade | slide | scale | blur | typewriter | words
    public var dur: Double = 0.5                // seconds
    public var dir: String?                     // slide: left | right | up | down (the side it comes from / goes to)
    public var amount: Double?                  // slide: distance px; scale: start size 0...1; blur: radius px
    public init(type: String, dur: Double = 0.5) { self.type = type; self.dur = dur }
    public static let types: [(id: String, name: String)] = [
        ("fade", "Fade"), ("slide", "Slide"), ("scale", "Scale"), ("blur", "Blur"), ("typewriter", "Typewriter (letters)"), ("words", "Word by word"),
    ]
    public var textOnly: Bool { type == "typewriter" || type == "words" }
}

/// Picture-in-picture for video clips on V2+: position (Final Cut units), scale, rotation, opacity, crop (l, r, t, b).
public struct ClipXf: Codable, Equatable {
    public var position: [Double]?
    public var scale: Double?
    public var rotation: Double?
    public var opacity: Double?
    public var crop: [Double]?
    public var shadow: [Double]?       // opacity 0...1, softness px, distance px (down right)
    /// keyframes per property, t from the clip's start: "position" [x, y], "scale" [s], "rotation" [deg], "opacity" [0...1],
    /// "crop" [l, r, t, b], "shadow" [opacity, softness, distance]. A property with keyframes ignores its fixed value.
    public var keys: [String: [Keyframe]]?
    public init() {}
    public static let props = ["position", "scale", "rotation", "opacity", "crop", "shadow"]
    /// the fixed (not animated) value of a property
    public func value(_ p: String) -> [Double] {
        switch p {
        case "position": return position ?? [0, 0]
        case "scale": return [scale ?? 1]
        case "rotation": return [rotation ?? 0]
        case "opacity": return [opacity ?? 1]
        case "crop": return crop ?? [0, 0, 0, 0]
        case "shadow": return shadow ?? [0, 30, 12]
        default: return [0]
        }
    }
    public mutating func setValue(_ p: String, _ v: [Double]) {
        switch p {
        case "position": position = v
        case "scale": scale = v[0]
        case "rotation": rotation = v[0]
        case "opacity": opacity = v[0]
        case "crop": crop = v
        case "shadow": shadow = v
        default: break
        }
    }
    /// value at time t (seconds from the clip's start): keyframes if the property has any, else the fixed value
    public func value(_ p: String, at t: Double) -> [Double] {
        if let k = keys?[p], !k.isEmpty { return KF.at(k, t, value(p)) }
        return value(p)
    }
    /// all properties resolved at time t (what the renderer draws)
    public func at(_ t: Double) -> ClipXf {
        guard let ks = keys, !ks.isEmpty else { return self }
        var x = self; x.keys = nil
        for p in Self.props where !(ks[p] ?? []).isEmpty { x.setValue(p, value(p, at: t)) }
        return x
    }
    public var isIdentity: Bool {
        (position ?? [0, 0]).allSatisfy { abs($0) < 0.0001 } && abs((scale ?? 1) - 1) < 0.0001 && abs(rotation ?? 0) < 0.001
            && (opacity ?? 1) > 0.999 && (crop ?? [0, 0, 0, 0]).allSatisfy { $0 < 0.0001 } && (shadow?.first ?? 0) < 0.001 && (keys ?? [:]).values.allSatisfy { $0.isEmpty }
    }
}

/// One effect in a layer's stack. p holds its numbers (colours as r, g, b 0...1).
public struct LayerEffect: Codable, Equatable, Identifiable {
    public var id: String
    public var type: String                     // shadow | glow | stroke | blur | color | tint | corners
    public var on: Bool = true
    public var p: [String: Double] = [:]
    public init(id: String, type: String, p: [String: Double]) { self.id = id; self.type = type; self.p = p }
    public static let catalog: [(type: String, name: String, defaults: [String: Double])] = [
        ("shadow", "Drop Shadow", ["distance": 12, "angle": 315, "softness": 14, "opacity": 0.6, "r": 0, "g": 0, "b": 0]),
        ("glow", "Outer Glow", ["radius": 18, "intensity": 0.8, "r": 1, "g": 1, "b": 1]),
        ("stroke", "Stroke", ["width": 4, "r": 1, "g": 1, "b": 1, "opacity": 1]),
        ("corners", "Round Corners", ["radius": 24]),
        ("blur", "Gaussian Blur", ["amount": 6]),
        ("color", "Color Adjust", ["brightness": 0, "contrast": 1, "saturation": 1]),
        ("tint", "Tint", ["amount": 0.5, "r": 0.2, "g": 0.6, "b": 1]),
    ]
}

public enum KF {
    /// keyframes cut in two at time d (split clip): each half keeps the value at the cut, the second half's times start at 0
    public static func split(_ k: [Keyframe]?, at d: Double) -> ([Keyframe]?, [Keyframe]?) {
        guard let k, !k.isEmpty else { return (k, k) }
        let mid = at(k, d, k[0].v)
        let a = k.filter { $0.t < d } + [Keyframe(t: d, v: mid)]
        let b = [Keyframe(t: 0, v: mid)] + k.filter { $0.t > d }.map { Keyframe(t: $0.t - d, v: $0.v, e: $0.e) }
        return (a, b)
    }
    public static func at(_ k: [Keyframe], _ t: Double, _ def: [Double]) -> [Double] {
        guard let f = k.first else { return def }
        if k.count == 1 || t <= f.t { return f.v }
        guard let l = k.last, t < l.t else { return k.last!.v }
        for (a, b) in zip(k, k.dropFirst()) where t >= a.t && t <= b.t {
            var u = b.t > a.t ? (t - a.t) / (b.t - a.t) : 1
            u = Ease.apply(b.e ?? a.e, u)
            return zip(a.v, b.v).map { $0 + ($1 - $0) * u }
        }
        return l.v
    }
}

final class OverlayImages: @unchecked Sendable {
    nonisolated(unsafe) static var cache: [String: CIImage] = [:]
    nonisolated(unsafe) static var baked: [String: CIImage] = [:]      // layer + its still effects, drawn once (GPU) and reused every frame
    nonisolated(unsafe) static var bakeHits = 0, bakeMisses = 0
    static let lock = NSLock()
    static let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    static func image(_ path: String) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[path] { return c }
        if path.hasPrefix("shape:") { let i = ShapeRender.ciImage(path); if let i { cache[path] = i }; return i }
        if path.hasPrefix("text:") { let i = TextRender.ciImage(path); if let i { cache[path] = i }; return i }
        guard let i = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.colorSpace: NSNull()]) else { return nil }
        cache[path] = i; return i
    }
    nonisolated(unsafe) static var bounds: [String: CGRect] = [:]
    /// box around the visible (non-transparent) pixels of a graphic, in its own pixel coordinates (y up); worked out once
    static func visibleBounds(_ path: String) -> CGRect? {
        lock.lock(); if let b = bounds[path] { lock.unlock(); return b }; lock.unlock()
        guard let src = NSImageLoader.cgImage(path) else { return nil }
        let w = src.width, h = src.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue), let data = ctx.data else { return nil }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in stride(from: 0, to: h, by: 2) { for x in stride(from: 0, to: w, by: 2) where px[y * w + x] > 8 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
        // bitmap memory runs top row first; Core Image counts y from the bottom, so flip
        let r = maxX < 0 ? CGRect(x: 0, y: 0, width: w, height: h) : CGRect(x: minX, y: h - maxY - 2, width: maxX - minX + 2, height: maxY - minY + 2)
        lock.lock(); bounds[path] = r; lock.unlock()
        return r
    }
    /// the layer with crop + its effect stack applied. Effects never change over time, so this is rendered ONCE per look
    /// and every frame reuses the finished pixels (moving / scaling / fading it costs almost nothing).
    static func baked(_ path: String, _ o: Overlay) -> CIImage? {
        guard let src = image(path) else { return nil }
        let fx = (o.effects ?? []).filter { $0.on && !LayerFX.isNeutral($0) }
        let crop = o.crop ?? [0, 0, 0, 0]
        if fx.isEmpty && crop.allSatisfy({ $0 <= 0.0001 }) && o.mask == nil { return src }          // nothing to bake: use the file as is
        let key = path + "|" + crop.map { String(format: "%.4f", $0) }.joined(separator: ",") + "|" +
            ((o.mask).flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? "") + "|" + fx.map { $0.type + $0.p.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.4f", $0.value))" }.joined(separator: ",") }.joined(separator: ";")
        lock.lock()
        if let b = baked[key] { bakeHits += 1; lock.unlock(); return b }
        lock.unlock()
        var img = src
        if let m = o.mask { img = ShapeRender.applyMask(m, to: img) }
        if crop.contains(where: { $0 > 0.0001 }) {
            let e = img.extent
            img = img.cropped(to: CGRect(x: e.minX + e.width * crop[0], y: e.minY + e.height * crop[3],
                                         width: e.width * max(0.02, 1 - crop[0] - crop[1]), height: e.height * max(0.02, 1 - crop[2] - crop[3])))
        }
        for f in fx { img = LayerFX.apply(f, img) }
        let ext = img.extent.integral
        guard ext.width > 0, ext.height > 0, ext.width < 16384, ext.height < 16384,
              let cg = ctx.createCGImage(img, from: ext, format: .RGBA8, colorSpace: nil) else { return img }
        let out = CIImage(cgImage: cg, options: [.colorSpace: NSNull()]).transformed(by: CGAffineTransform(translationX: ext.minX, y: ext.minY))
        lock.lock(); bakeMisses += 1
        if baked.count > 96 { baked.removeAll() }       // keep memory bounded
        baked[key] = out; lock.unlock()
        return out
    }
}

/// The effects themselves (all Core Image, on the GPU).
enum LayerFX {
    static func isNeutral(_ f: LayerEffect) -> Bool {
        let p = f.p
        switch f.type {
        case "blur": return (p["amount"] ?? 0) < 0.05
        case "color": return abs(p["brightness"] ?? 0) < 0.001 && abs((p["contrast"] ?? 1) - 1) < 0.001 && abs((p["saturation"] ?? 1) - 1) < 0.001
        case "tint": return (p["amount"] ?? 0) < 0.001
        case "shadow": return (p["opacity"] ?? 0) < 0.001
        case "glow": return (p["intensity"] ?? 0) < 0.001 || (p["radius"] ?? 0) < 0.1
        case "stroke": return (p["width"] ?? 0) < 0.1 || (p["opacity"] ?? 0) < 0.001
        case "corners": return (p["radius"] ?? 0) < 0.5
        default: return true
        }
    }
    static func colored(_ img: CIImage, _ r: Double, _ g: Double, _ b: Double, _ a: Double) -> CIImage {
        // the layer's shape (alpha) filled with one colour
        img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(a)),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(r)), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(g)),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(b)), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    }
    static func apply(_ f: LayerEffect, _ img: CIImage) -> CIImage {
        let p = f.p
        func v(_ k: String, _ d: Double) -> Double { p[k] ?? d }
        switch f.type {
        case "blur":
            return img.applyingGaussianBlur(sigma: v("amount", 6))
        case "color":
            return img.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: v("brightness", 0), kCIInputContrastKey: v("contrast", 1), kCIInputSaturationKey: v("saturation", 1)])
        case "tint":
            return img.applyingFilter("CIColorMonochrome", parameters: [kCIInputColorKey: CIColor(red: v("r", 0.2), green: v("g", 0.6), blue: v("b", 1)), kCIInputIntensityKey: v("amount", 0.5)])
        case "shadow":
            let a = v("angle", 315) * .pi / 180, d = v("distance", 12)
            let sh = colored(img, v("r", 0), v("g", 0), v("b", 0), v("opacity", 0.6)).applyingGaussianBlur(sigma: v("softness", 14) / 2)
                .transformed(by: CGAffineTransform(translationX: cos(a) * d, y: sin(a) * d))
            return img.composited(over: sh)
        case "glow":
            var gl = colored(img, v("r", 1), v("g", 1), v("b", 1), 1).applyingGaussianBlur(sigma: v("radius", 18) / 2)
            gl = gl.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(min(3, v("intensity", 0.8) * 1.6)))])
            return img.composited(over: gl)
        case "stroke":
            let st = colored(img, v("r", 1), v("g", 1), v("b", 1), v("opacity", 1)).applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: v("width", 4)])
            return img.composited(over: st)
        case "corners":
            let e = img.extent
            let mask = CIImage(color: .white).cropped(to: e).applyingFilter("CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: e), kCIInputRadiusKey: min(v("radius", 24), min(e.width, e.height) / 2), kCIInputColorKey: CIColor.white])
            return img.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        default: return img
        }
    }
}

/// Graphic layers as the renderer sees them; edits while a slider is dragged update this live (no timeline rebuild).
final class OverlayStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snaps: [OverlayRender.Snap]
    init(_ s: [OverlayRender.Snap]) { snaps = s }
    func all() -> [OverlayRender.Snap] { lock.lock(); defer { lock.unlock() }; return snaps }
    func update(_ o: Overlay) { lock.lock(); if let i = snaps.firstIndex(where: { $0.o.id == o.id }) { snaps[i].o = o; if let t = o.text { snaps[i].path = TextRender.key(t) }; if let sh = o.shape { snaps[i].path = ShapeRender.key(sh) } }; lock.unlock() }
    func replaceAll(_ s: [OverlayRender.Snap]) { lock.lock(); snaps = s; lock.unlock() }
}

enum NSImageLoader {
    static func cgImage(_ path: String) -> CGImage? {
        if path.hasPrefix("text:") { return TextRender.cgImage(path) }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

/// Where a layer sits in the frame (used by the renderer and by the on-screen handles in the viewer). Frame coords, y up.
public struct LayerGeometry {
    public var transform: CGAffineTransform     // source pixels -> frame pixels
    public var box: [CGPoint]                   // corners of the visible graphic (frame coords, y up): bl, br, tr, tl
    public var pivot: CGPoint                   // anchor point in the frame
    public var fit: Double                      // size factor at 100 % scale
}

public enum OverlayRender {
    struct Snap { var o: Overlay; var path: String }
    /// the project's frame height: a "none" (actual pixels) layer keeps its size relative to the frame at any playback resolution
    nonisolated(unsafe) public static var projectHeight: Double = 0
    public static func geometry(_ o: Overlay, path: String, t: Double, width W: Double, height H: Double) -> LayerGeometry? {
        guard let src = OverlayImages.image(path) else { return nil }
        let local = t - o.offset
        let iw = src.extent.width, ih = src.extent.height
        var fit: CGFloat = 1
        switch o.conform { case "fill": fit = max(W / iw, H / ih); case "none": fit = projectHeight > 0 ? H / projectHeight : 1; default: fit = min(W / iw, H / ih) }
        let sc = KF.at(o.scale, local, [1, 1]), p = KF.at(o.position, local, [0, 0])
        let rot = KF.at(o.rotation ?? [], local, [0])[0]
        let a = o.anchor ?? [0, 0], u = H / 100
        let pivotSrc = CGPoint(x: src.extent.midX + a[0], y: src.extent.midY + a[1])
        var tr = CGAffineTransform(translationX: -pivotSrc.x, y: -pivotSrc.y)
        tr = tr.concatenating(CGAffineTransform(scaleX: fit * sc[0], y: fit * (sc.count > 1 ? sc[1] : sc[0])))
        if abs(rot) > 0.001 { tr = tr.concatenating(CGAffineTransform(rotationAngle: rot * .pi / 180)) }
        let pivotFrame = CGPoint(x: W / 2 + p[0] * u + a[0] * fit, y: H / 2 + (p.count > 1 ? p[1] : 0) * u + a[1] * fit)
        tr = tr.concatenating(CGAffineTransform(translationX: pivotFrame.x, y: pivotFrame.y))
        var vb = OverlayImages.visibleBounds(path) ?? src.extent
        if let c = o.crop {
            let e = src.extent
            vb = vb.intersection(CGRect(x: e.minX + e.width * c[0], y: e.minY + e.height * c[3], width: e.width * (1 - c[0] - c[1]), height: e.height * (1 - c[2] - c[3])))
        }
        let box = [CGPoint(x: vb.minX, y: vb.minY), CGPoint(x: vb.maxX, y: vb.minY), CGPoint(x: vb.maxX, y: vb.maxY), CGPoint(x: vb.minX, y: vb.maxY)].map { $0.applying(tr) }
        return LayerGeometry(transform: tr, box: box, pivot: pivotFrame, fit: fit)
    }
    /// offset from the image centre to the centre of its visible pixels (source px) - for "anchor on the graphic"
    public static func visibleCentreOffset(path: String) -> [Double]? {
        guard let src = OverlayImages.image(path), let b = OverlayImages.visibleBounds(path) else { return nil }
        return [b.midX - src.extent.midX, b.midY - src.extent.midY]
    }
    /// draws the layer at timeline time t onto `base` (with its blend mode)
    static func draw(_ s: Snap, t: Double, frame: CGRect, over base: CIImage) -> CIImage {
        let local = t - s.o.offset
        guard local >= 0, local < s.o.duration else { return base }
        // build in / out: progress 0 (hidden) ... 1 (fully in)
        var bop = 1.0, bdx = 0.0, bdy = 0.0, bsc = 1.0, bblur = 0.0, reveal = 1.0
        for (b, p) in [(s.o.buildIn, s.o.buildIn.map { local < $0.dur ? Ease.apply("out", max(0, local / max(0.01, $0.dur))) : 1 }),
                       (s.o.buildOut, s.o.buildOut.map { b in let r = s.o.duration - local; return r < b.dur ? Ease.apply("out", max(0, r / max(0.01, b.dur))) : 1 })] {
            guard let b, let p, p < 1 else { continue }
            let q = 1 - p
            switch b.type {
            case "slide":
                let d = (b.amount ?? 300) * q
                switch b.dir ?? "left" { case "right": bdx += d; case "up": bdy += d; case "down": bdy -= d; default: bdx -= d }
                bop *= min(1, p * 2)
            case "scale": let f = b.amount ?? 0; bsc *= f + (1 - f) * p; bop *= p
            case "blur": bblur = max(bblur, (b.amount ?? 30) * q); bop *= p
            case "typewriter", "words": if s.o.text != nil { reveal = min(reveal, p) } else { bop *= p }
            default: bop *= p
            }
        }
        var bdeg = 0.0
        for b in s.o.behaviours ?? [] where b.on {
            switch b.type {
            case "wiggle": let w = local * b.speed * 2 * .pi / 3; bdx += b.amount * Behaviour.wander(w, 0.3); bdy += b.amount * Behaviour.wander(w, 5.1)
            case "drift": let a = (b.angle ?? 0) * .pi / 180; bdx += cos(a) * b.amount * local; bdy += sin(a) * b.amount * local
            case "pulse": bsc *= 1 + b.amount / 100 * (0.5 - 0.5 * cos(local * b.speed * 2 * .pi))
            case "spin": bdeg += b.speed * local
            default: break
            }
        }
        var path = s.path
        if reveal < 1, let t = s.o.text { path = TextRender.key(TextRender.reveal(t, reveal, words: (s.o.buildIn?.textOnly == true && local < (s.o.buildIn?.dur ?? 0) ? s.o.buildIn : s.o.buildOut)?.type == "words")) }
        guard var img = OverlayImages.baked(path, s.o) else { return base }
        var op = KF.at(s.o.opacity, local, [1])[0] * bop
        if let fi = s.o.fadeIn, fi > 0.001, local < fi { op *= local / fi }
        if let fo = s.o.fadeOut, fo > 0.001, local > s.o.duration - fo { op *= max(0, (s.o.duration - local) / fo) }
        guard op > 0.001, let g = geometry(s.o, path: s.path, t: t, width: frame.width, height: frame.height) else { return base }
        var tr = g.transform
        if abs(bdeg) > 0.0001 { tr = tr.concatenating(CGAffineTransform(translationX: -g.pivot.x, y: -g.pivot.y)).concatenating(CGAffineTransform(rotationAngle: bdeg * .pi / 180)).concatenating(CGAffineTransform(translationX: g.pivot.x, y: g.pivot.y)) }
        if bsc != 1 { tr = tr.concatenating(CGAffineTransform(translationX: -g.pivot.x, y: -g.pivot.y)).concatenating(CGAffineTransform(scaleX: bsc, y: bsc)).concatenating(CGAffineTransform(translationX: g.pivot.x, y: g.pivot.y)) }
        if bdx != 0 || bdy != 0 { tr = tr.concatenating(CGAffineTransform(translationX: bdx * g.fit, y: bdy * g.fit)) }
        if bblur > 0.3 { img = img.clampedToExtent().applyingGaussianBlur(sigma: bblur / 2).cropped(to: img.extent.insetBy(dx: -bblur * 2, dy: -bblur * 2)) }
        img = img.transformed(by: tr)
        if op < 0.999 { img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: op)]) }
        if let sh = s.o.shape, sh.kind == "blur" {
            // blur area: what is underneath, blurred or pixelated, shown only inside the shape (soft edge = feather)
            let amt = max(1, sh.amount ?? 30)
            let hidden: CIImage = sh.style == "pixelate"
                ? base.clampedToExtent().applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: amt, kCIInputCenterKey: CIVector(x: 0, y: 0)]).cropped(to: base.extent)
                : base.clampedToExtent().applyingGaussianBlur(sigma: amt / 2).cropped(to: base.extent)
            var mask = img
            if let f = sh.feather, f > 0.3 { mask = mask.clampedToExtent().applyingGaussianBlur(sigma: f / 2).cropped(to: mask.extent.insetBy(dx: -f * 2, dy: -f * 2)) }
            return hidden.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: mask]).cropped(to: base.extent)
        }
        let modes = ["screen": "CIScreenBlendMode", "multiply": "CIMultiplyBlendMode", "add": "CIAdditionCompositing",
                     "overlay": "CIOverlayBlendMode", "lighten": "CILightenBlendMode", "darken": "CIDarkenBlendMode"]
        if let b = s.o.blend, let f = modes[b] { return img.applyingFilter(f, parameters: [kCIInputBackgroundImageKey: base]).cropped(to: base.extent) }
        return img.composited(over: base)
    }
}

/// Keyframe easing curves (u = 0...1 progress between two keyframes)
public enum Ease {
    public static let presets: [(id: String, name: String)] = [
        ("linear", "Linear"), ("in", "Ease In"), ("out", "Ease Out"), ("s", "Ease In & Out"),
        ("strong", "Strong (fast start, soft stop)"), ("back", "Overshoot"), ("bounce", "Bounce"), ("bez:0.25,0.1,0.25,1", "Custom Bezier"),
    ]
    public static func apply(_ e: String?, _ u: Double) -> Double {
        guard let e, e != "linear" else { return u }
        switch e {
        case "in": return u * u * u
        case "out": let v = 1 - u; return 1 - v * v * v
        case "s": return u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
        case "strong": return u >= 1 ? 1 : 1 - pow(2, -10 * u)
        case "back": let c1 = 1.70158, c3 = c1 + 1; return 1 + c3 * pow(u - 1, 3) + c1 * pow(u - 1, 2)
        case "bounce":
            let n = 7.5625, d = 2.75
            if u < 1 / d { return n * u * u }
            if u < 2 / d { let x = u - 1.5 / d; return n * x * x + 0.75 }
            if u < 2.5 / d { let x = u - 2.25 / d; return n * x * x + 0.9375 }
            let x = u - 2.625 / d; return n * x * x + 0.984375
        default:
            if e.hasPrefix("bez:") {
                let v = e.dropFirst(4).split(separator: ",").compactMap { Double($0) }
                if v.count == 4 { return bezier(v[0], v[1], v[2], v[3], u) }
            }
            return u
        }
    }
    /// CSS-style cubic Bezier (0,0) (x1,y1) (x2,y2) (1,1): y for a given x
    public static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        func bx(_ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t }
        func by(_ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<30 { t = (lo + hi) / 2; if bx(t) < x { lo = t } else { hi = t } }
        return by(t)
    }
}
