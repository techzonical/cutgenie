import SwiftUI
import CutzonicalCore

// On-screen handles in the viewer for the selected graphic layer or V2+ video clip:
// drag inside the box = move, drag a corner = scale (shapes: corners / sides change width and height) (around the anchor), drag the round handle on top = rotate.
// Edits are live and become one undo step when you let go.
struct TransformHandles: View {
    @ObservedObject var editor: Editor
    @ObservedObject var live: LiveState
    @ObservedObject var dragState: DragState
    @State private var drag: (mode: String, pos: [Double], scale: [Double], rot: Double, start: CGPoint)? = nil
    @State private var editing: String? = nil          // text layer being typed into on the picture
    @State private var typed = ""
    @State private var original = ""
    @State private var pending: DispatchWorkItem?
    @FocusState private var typing: Bool
    @AppStorage("guides.centre") var gCentre = false
    @AppStorage("guides.thirds") var gThirds = false
    @AppStorage("guides.safe") var gSafe = false

    enum Target { case layer(Overlay, String), clip(Clip) }
    var target: Target? {
        guard editor.selection.count <= 1, let id = editor.selection.first ?? editor.selectedOverlay else { return nil }
        let t = live.playhead
        if let o = editor.liveLayer(id), t >= o.offset, t < o.offset + o.duration, let p = editor.layerPath(o) { return .layer(o, p) }
        if let c = editor.liveUpperClip(id), t >= c.offset, t < c.offset + c.duration { return .clip(c) }
        return nil
    }
    nonisolated(unsafe) static var mouse: ((Int, CGPoint, CGSize) -> Void)?
    @State private var startPt = CGPoint.zero
    @State private var sizeStart: (w: Double, h: Double, hx: Int)? = nil
    /// the shape of the target when it is a shape layer (its width / height can be changed on the picture)
    func shapeOf(_ tg: Target?) -> ShapeSpec? { if case .layer(let o, _)? = tg { return o.shape }; return nil }
    /// side handles: middle of each edge (bottom, right, top, left in frame order)
    static func mids(_ b: [CGPoint]) -> [CGPoint] { (0..<4).map { i in let a = b[i], c = b[(i + 1) % 4]; return CGPoint(x: (a.x + c.x) / 2, y: (a.y + c.y) / 2) } }
    /// which size handle is under the pointer: 0-3 corners, 4-7 sides
    func sizeHandle(_ pt: CGPoint, _ box: [CGPoint], _ sh: ShapeSpec) -> Int? {
        if let i = box.indices.first(where: { hypot(pt.x - box[$0].x, pt.y - box[$0].y) <= 11 }) { return i }
        let m = Self.mids(box)
        return m.indices.first(where: { hypot(pt.x - m[$0].x, pt.y - m[$0].y) <= 10 && !(sh.kind == "line" && $0 % 2 == 0) }).map { $0 + 4 }
    }
    /// mouse from the picture view: 0 down, 1 drag, 2 up (view points, top-left origin)
    func mouse(_ phase: Int, _ pt: CGPoint, _ size: CGSize) {
        let sx = size.width / W, sy = size.height / H
        let v: (CGPoint) -> CGPoint = { CGPoint(x: $0.x * sx, y: (H - $0.y) * sy) }
        switch phase {
        case 0:
            startPt = pt
            if editing != nil { finishTyping(); return }           // a click outside the typing box ends typing
            if NSApp.currentEvent?.clickCount == 2 {
                // double-click on words: type straight into them
                let hit = candidates().first { c in geometry(c).map { Self.inside(pt, $0.box.map(v)) } ?? false }
                if let hit, case .layer(let o, _) = hit, let tx = o.text {
                    select(hit); editing = o.id; original = tx.plain; typed = tx.plain; drag = nil
                    DispatchQueue.main.async { typing = true }
                    return
                }
            }
            var mode = "none"
            var tg = target
            if let t0 = tg, let geo = geometry(t0) {
                let h = handles(geo, v)
                if hypot(pt.x - h.rot.x, pt.y - h.rot.y) <= 12 { mode = "rotate" }
                else if let sh = shapeOf(t0), let hx = sizeHandle(pt, h.box, sh) { mode = "size"; sizeStart = (sh.w, sh.h, hx) }
                else if h.box.contains(where: { hypot(pt.x - $0.x, pt.y - $0.y) <= 11 }) { mode = "scale" }
                else if Self.inside(pt, h.box) { mode = "move" }
            }
            if mode == "none" {          // click in the picture: select the top-most thing under the pointer (or nothing)
                tg = candidates().first { c in geometry(c).map { Self.inside(pt, $0.box.map(v)) } ?? false }
                select(tg)
                if tg != nil { mode = "move" }
            }
            if let t1 = tg, mode != "none" { let (p, sc, r) = values(t1); drag = (mode, p, sc, r, pt) } else { drag = ("none", [], [], 0, pt) }
        case 1:
            guard let dg = drag, dg.mode != "none", let tg = target, let geo = geometry(tg) else { return }
            guard hypot(pt.x - dg.start.x, pt.y - dg.start.y) >= 2 else { return }      // a plain click only selects
            let pivot = v(geo.pivot), u = H / 100
            switch dg.mode {
            case "move":
                NSCursor.closedHand.set()
                let nx = dg.pos[0] + (pt.x - dg.start.x) / sx / u, ny = dg.pos[1] - (pt.y - dg.start.y) / sy / u
                apply(tg) { pos, _, _ in pos = [nx, ny] }
            case "size":
                guard let ss = sizeStart, case .layer(let o, _) = tg, let sh0 = o.shape else { return }
                let b = geo.box.map(v), c = CGPoint(x: b.map(\.x).reduce(0, +) / 4, y: b.map(\.y).reduce(0, +) / 4)
                func unit(_ a: CGPoint, _ z: CGPoint) -> CGPoint { let l = max(0.001, hypot(z.x - a.x, z.y - a.y)); return CGPoint(x: (z.x - a.x) / l, y: (z.y - a.y) / l) }
                let ux = unit(b[0], b[1]), uy = unit(b[0], b[3])
                let d0 = CGPoint(x: dg.start.x - c.x, y: dg.start.y - c.y), d1 = CGPoint(x: pt.x - c.x, y: pt.y - c.y)
                func ratio(_ u: CGPoint) -> Double { let a = abs(d0.x * u.x + d0.y * u.y); return a < 3 ? 1 : max(0.01, abs(d1.x * u.x + d1.y * u.y) / a) }
                let corner = ss.hx < 4, side = ss.hx - 4
                var kx = corner || side % 2 == 1 ? ratio(ux) : 1, ky = sh0.kind != "line" && (corner || side % 2 == 0) ? ratio(uy) : 1
                if sh0.lock == true || NSEvent.modifierFlags.contains(.shift) {
                    let k = corner ? (kx + ky) / 2 : (side % 2 == 1 ? kx : ky); kx = k; ky = sh0.kind == "line" ? 1 : k
                }
                let nw = max(2, (ss.w * kx).rounded()), nh = max(2, (ss.h * ky).rounded())
                editor.liveLayers([o.id]) { l in if var s = l.shape { s.w = nw; s.h = nh; l.shape = s } }
            case "scale":
                let k = max(0.01, hypot(pt.x - pivot.x, pt.y - pivot.y) / max(1, hypot(dg.start.x - pivot.x, dg.start.y - pivot.y)))
                apply(tg) { _, sc, _ in sc = dg.scale.map { $0 * k } }
            default:
                let a0 = atan2(-(dg.start.y - pivot.y), dg.start.x - pivot.x), a1 = atan2(-(pt.y - pivot.y), pt.x - pivot.x)
                var r = dg.rot + (a1 - a0) * 180 / .pi
                if NSEvent.modifierFlags.contains(.shift) { r = (r / 15).rounded() * 15 }
                apply(tg) { _, _, rot in rot = r }
            }
        case 3:
            hoverCursor(pt, v)
        default:
            if let dg = drag, dg.mode != "none" { editor.commitLive() }
            drag = nil; sizeStart = nil
            hoverCursor(pt, v)
        }
    }
    /// pointer shape over the picture: a corner = resize arrows, the round handle = rotate, inside the box = move hand,
    /// over another graphic = pointing hand (click selects it), elsewhere = the normal arrow
    func hoverCursor(_ pt: CGPoint, _ v: (CGPoint) -> CGPoint) {
        guard editing == nil else { return }
        if let tg = target, let geo = geometry(tg) {
            let h = handles(geo, v)
            if hypot(pt.x - h.rot.x, pt.y - h.rot.y) <= 12 { Self.rotateCursor.set(); return }
            if let sh = shapeOf(tg), let hx = sizeHandle(pt, h.box, sh), hx >= 4 {
                // a side: left-right or up-down arrows, whichever way that side faces on screen
                let m = Self.mids(h.box)[hx - 4], across = abs(m.x - h.pivot.x) > abs(m.y - h.pivot.y)
                if #available(macOS 15.0, *) { NSCursor.frameResize(position: across ? .right : .top, directions: .all).set() }
                else { (across ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set() }
                return
            }
            if let c = h.box.first(where: { hypot(pt.x - $0.x, pt.y - $0.y) <= 11 }) {
                // which way the corner points from the middle (view y goes down): ↖↘ or ↗↙
                let downRight = (c.x - h.pivot.x) * (c.y - h.pivot.y) > 0
                if #available(macOS 15.0, *) {
                    NSCursor.frameResize(position: downRight ? .bottomRight : .topRight, directions: .all).set()
                } else { NSCursor.crosshair.set() }
                return
            }
            if Self.inside(pt, h.box) { NSCursor.openHand.set(); return }
        }
        if candidates().contains(where: { c in geometry(c).map { Self.inside(pt, $0.box.map(v)) } ?? false }) { NSCursor.pointingHand.set(); return }
        NSCursor.arrow.set()
    }
    /// a round arrow, drawn once (macOS has no rotate pointer)
    static let rotateCursor: NSCursor = {
        let img = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { r in
            let p = NSBezierPath(); p.appendArc(withCenter: NSPoint(x: 10, y: 10), radius: 6.5, startAngle: 40, endAngle: 330)
            p.lineWidth = 3.5; NSColor.white.setStroke(); p.stroke()
            p.lineWidth = 1.6; NSColor.black.setStroke(); p.stroke()
            let tip = NSBezierPath(); tip.move(to: NSPoint(x: 15.6, y: 4.6)); tip.line(to: NSPoint(x: 19, y: 9)); tip.line(to: NSPoint(x: 12.4, y: 9.4)); tip.close()
            NSColor.black.setFill(); tip.fill(); NSColor.white.setStroke(); tip.lineWidth = 0.8; tip.stroke()
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: 10, y: 10))
    }()
    /// the text with the words typed so far; styled parts are kept when the line structure still matches
    func respec(_ t: TextSpec, _ text: String) -> TextSpec {
        var t = t
        let textRuns = t.runs.indices.filter { !t.runs[$0].text.allSatisfy { $0.isNewline } }
        let pieces = text.components(separatedBy: "\n")
        if t.runs.count == 1 { t.runs[0].text = text }
        else if textRuns.count == pieces.count {
            for (k, i) in textRuns.enumerated() { t.runs[i].text = pieces[k] + (t.runs[i].text.hasSuffix("\n") ? "\n" : "") }
        } else {
            var r = t.runs[textRuns.first ?? 0]; r.text = text; t.runs = [r]
        }
        return t
    }
    func pushTyped(_ text: String) {
        guard let id = editing, let o = editor.project.overlays?.first(where: { $0.id == id }), let tx = o.text else { return }
        let n = respec(tx, text)
        editor.liveLayers([id]) { l in l.text = n }          // live: the picture follows the typing
    }
    func finishTyping(cancel: Bool = false) {
        pending?.cancel(); pending = nil
        guard editing != nil else { return }
        if cancel { pushTyped(original) } else { pushTyped(typed) }
        editor.commitLive()                                    // one undo step for the whole edit
        editing = nil; typing = false
    }
    var W: Double { Double(editor.project.settings.width) }
    var H: Double { Double(editor.project.settings.height) }

    /// box corners (frame coords, y up) and pivot for the target
    func geometry(_ tg: Target) -> (box: [CGPoint], pivot: CGPoint)? {
        switch tg {
        case .layer(let o, let p):
            guard let g = OverlayRender.geometry(o, path: p, t: live.playhead, width: W, height: H) else { return nil }
            return (g.box, g.pivot)
        case .clip(let c):
            let x = (c.xf ?? ClipXf()).at(live.playhead - c.offset), cr = x.crop ?? [0, 0, 0, 0], u = H / 100, pos = x.position ?? [0, 0]
            var tr = CGAffineTransform(translationX: -W / 2, y: -H / 2).concatenating(CGAffineTransform(scaleX: x.scale ?? 1, y: x.scale ?? 1))
            if let r = x.rotation { tr = tr.concatenating(CGAffineTransform(rotationAngle: r * .pi / 180)) }
            tr = tr.concatenating(CGAffineTransform(translationX: W / 2 + pos[0] * u, y: H / 2 + pos[1] * u))
            let r = CGRect(x: W * cr[0], y: H * cr[3], width: W * (1 - cr[0] - cr[1]), height: H * (1 - cr[2] - cr[3]))
            let box = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map { $0.applying(tr) }
            return (box, CGPoint(x: W / 2 + pos[0] * u, y: H / 2 + pos[1] * u))
        }
    }
    /// "· zoom 108 %" for a V1 clip with zoom keyframes (the zoom is separate from position / scale)
    func zoomNote(_ tg: Target) -> String {
        if case .clip(let c) = tg, let z = c.zoom, !z.isEmpty { return String(format: "  ·  zoom %.0f %%", KF.at(z, live.playhead - c.offset, [1])[0] * 100) }
        return ""
    }
    /// current position (FCP units), scale, rotation of the target
    func values(_ tg: Target) -> ([Double], [Double], Double) {
        switch tg {
        case .layer(let o, _):
            let t = live.playhead
            return (editor.layerValue(o, "position", at: t), editor.layerValue(o, "scale", at: t), editor.layerValue(o, "rotation", at: t)[0])
        case .clip(let c):
            let x = (c.xf ?? ClipXf()).at(live.playhead - c.offset); return (x.position ?? [0, 0], [x.scale ?? 1, x.scale ?? 1], x.rotation ?? 0)
        }
    }

    /// everything selectable at the playhead, top-most first (higher track wins; hidden / locked tracks skipped)
    func candidates() -> [Target] {
        let t = live.playhead, off = Set((editor.project.hiddenTracks ?? []) + (editor.project.unsynced ?? []))
        var out: [(Int, Target)] = []
        for o in editor.project.overlays ?? [] where t >= o.offset && t < o.offset + o.duration && !off.contains("V\(o.lane + 1)") {
            if let p = editor.layerPath(o) { out.append((o.lane * 2 + 1, .layer(o, p))) }      // a layer is above the video on its track
        }
        for c in editor.project.upperClips ?? [] where t >= c.offset && t < c.offset + c.duration && !off.contains("V\((c.lane ?? 1) + 1)") {
            out.append(((c.lane ?? 1) * 2, .clip(c)))
        }
        return out.sorted { $0.0 > $1.0 }.map { $0.1 }
    }
    static func inside(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
        var c = false, j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
            j = i
        }
        return c
    }
    func id(_ tg: Target) -> String { switch tg { case .layer(let o, _): return o.id; case .clip(let c): return c.id } }
    func select(_ tg: Target?) {
        guard let tg else { editor.selection = []; editor.selectedOverlay = nil; return }
        editor.selection = [id(tg)]
        if case .layer(let o, _) = tg { editor.selectedOverlay = o.id; editor.selectedClip = nil } else { editor.selectedClip = id(tg); editor.selectedOverlay = nil }
        if editor.inspectorTab != "clip" { editor.inspectorTab = "clip" }       // show its Effects
    }

    var body: some View {
        GeometryReader { g in
            let sx = g.size.width / W, sy = g.size.height / H
            let v: (CGPoint) -> CGPoint = { CGPoint(x: $0.x * sx, y: (H - $0.y) * sy) }     // frame (y up) -> view (y down)
            ZStack(alignment: .topLeading) {
                // reference guides: centre lines (always while dragging), thirds, title / action safe areas
                let frameW = g.size.width, frameH = g.size.height
                if gCentre || (drag != nil && drag?.mode != "none") {
                    Path { p in p.move(to: CGPoint(x: frameW / 2, y: 0)); p.addLine(to: CGPoint(x: frameW / 2, y: frameH))
                        p.move(to: CGPoint(x: 0, y: frameH / 2)); p.addLine(to: CGPoint(x: frameW, y: frameH / 2)) }
                        .stroke(Color.cyan.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
                if gThirds {
                    Path { p in for k in [1.0, 2.0] { p.move(to: CGPoint(x: frameW * k / 3, y: 0)); p.addLine(to: CGPoint(x: frameW * k / 3, y: frameH))
                        p.move(to: CGPoint(x: 0, y: frameH * k / 3)); p.addLine(to: CGPoint(x: frameW, y: frameH * k / 3)) } }
                        .stroke(Color.white.opacity(0.35), lineWidth: 0.7)
                }
                if gSafe {
                    Rectangle().stroke(Color.white.opacity(0.4), lineWidth: 0.7).frame(width: frameW * 0.93, height: frameH * 0.93).position(x: frameW / 2, y: frameH / 2)
                    Rectangle().stroke(Color.yellow.opacity(0.4), style: StrokeStyle(lineWidth: 0.7, dash: [4, 3])).frame(width: frameW * 0.9, height: frameH * 0.9).position(x: frameW / 2, y: frameH / 2)
                }
                if let tg = target, let geo = geometry(tg) {
                    let h = handles(geo, v)
                    // live numbers beside the box: where it is and how big (project pixels from the centre, like the inspector)
                    let (vp, vs, vr) = values(tg), uu = H / 100
                    let minY = h.box.map(\.y).min() ?? 0, midX = h.box.map(\.x).reduce(0, +) / 4
                    Text(String(format: "X %.0f  Y %.0f  ·  %.0f %%", vp[0] * uu, vp[1] * uu, (vs.first ?? 1) * 100) + (abs(vr) > 0.05 ? String(format: "  ·  %.1f°", vr) : "") + zoomNote(tg))
                        .font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.black)
                        .padding(.horizontal, 5).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 3).fill(Color.yellow))
                        .fixedSize()
                        .position(x: min(max(70, midX), frameW - 70), y: max(10, minY - 34))
                    // line from the frame centre to the box's pivot, so the offset is easy to judge
                    Path { p in p.move(to: CGPoint(x: frameW / 2, y: frameH / 2)); p.addLine(to: h.pivot) }
                        .stroke(Color.yellow.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    Path { p in p.addLines(h.box); p.closeSubpath() }.stroke(Color.yellow, lineWidth: 1)
                    Path { p in p.move(to: h.topMid); p.addLine(to: h.rot) }.stroke(Color.yellow, lineWidth: 1)
                    ForEach(0..<4, id: \.self) { i in
                        Rectangle().fill(Color.white).frame(width: 8, height: 8).overlay(Rectangle().stroke(Color.black.opacity(0.6), lineWidth: 1)).position(h.box[i])
                    }
                    Circle().fill(Color.white).frame(width: 10, height: 10).overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1)).position(h.rot)
                    if let sh = shapeOf(tg) {
                        // shapes: side handles change width / height (corners change both)
                        let m = Self.mids(h.box)
                        ForEach(0..<4, id: \.self) { i in
                            if !(sh.kind == "line" && i % 2 == 0) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 7, height: 7).overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.6), lineWidth: 1)).position(m[i])
                            }
                        }
                        Text(String(format: "%.0f × %.0f px", sh.w, sh.kind == "line" ? (sh.strokeWidth ?? 8) : sh.h) + (sh.lock == true ? "  🔒" : ""))
                            .font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.black)
                            .padding(.horizontal, 5).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.9)))
                            .fixedSize()
                            .position(x: min(max(50, midX), frameW - 50), y: min(frameH - 10, (h.box.map(\.y).max() ?? 0) + 16))
                    }
                    Path { p in p.move(to: CGPoint(x: h.pivot.x - 6, y: h.pivot.y)); p.addLine(to: CGPoint(x: h.pivot.x + 6, y: h.pivot.y))
                        p.move(to: CGPoint(x: h.pivot.x, y: h.pivot.y - 6)); p.addLine(to: CGPoint(x: h.pivot.x, y: h.pivot.y + 6)) }
                        .stroke(Color.yellow, lineWidth: 1)
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            .allowsHitTesting(false)
            .overlay(alignment: .topLeading) {
                if let id = editing, let o = editor.liveLayer(id), let p = editor.layerPath(o),
                   let geo = OverlayRender.geometry(o, path: p, t: live.playhead, width: W, height: H) {
                    let b = geo.box.map(v)
                    let minX = b.map(\.x).min() ?? 0, maxX = b.map(\.x).max() ?? 0, minY = b.map(\.y).min() ?? 0, maxY = b.map(\.y).max() ?? 0
                    let r0 = o.text?.runs.first
                    let sc = editor.layerValue(o, "scale", at: live.playhead).first ?? 1
                    TextField("", text: $typed, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: max(10, CGFloat(r0?.size ?? 40) * sy * sc * 0.9), weight: r0?.bold == true ? .bold : .semibold))
                        .multilineTextAlignment(o.text?.align == "left" ? .leading : o.text?.align == "right" ? .trailing : .center)
                        .foregroundStyle(.white)
                        .focused($typing)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .frame(width: max(120, maxX - minX + 24), alignment: .center)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.72)))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Brand.accent, lineWidth: 1.5))
                        .position(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
                        .onChange(of: typed) { _, t in
                            pending?.cancel()
                            let w = DispatchWorkItem { pushTyped(t) }; pending = w
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
                        }
                        .onSubmit { finishTyping() }
                        .onExitCommand { finishTyping(cancel: true) }
                        .onChange(of: editor.selection) { _, _ in if editing != nil && editor.selection != [id] { finishTyping() } }
                    Text("Return to finish · Esc to cancel · ⌥Return for a new line")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.black.opacity(0.6)))
                        .position(x: (minX + maxX) / 2, y: min(g.size.height - 10, maxY + 26))
                        .allowsHitTesting(false)
                }
            }
            .onAppear { TransformHandles.mouse = { phase, pt, size in mouse(phase, pt, size) } }
        }
    }

    /// handle positions in view coordinates
    func handles(_ geo: (box: [CGPoint], pivot: CGPoint), _ v: (CGPoint) -> CGPoint) -> (box: [CGPoint], pivot: CGPoint, topMid: CGPoint, rot: CGPoint) {
        let box = geo.box.map(v), pivot = v(geo.pivot)
        let topMid = CGPoint(x: (box[2].x + box[3].x) / 2, y: (box[2].y + box[3].y) / 2)
        let away = CGPoint(x: topMid.x - (box[0].x + box[1].x) / 2, y: topMid.y - (box[0].y + box[1].y) / 2)
        let len = max(1, hypot(away.x, away.y))
        return (box, pivot, topMid, CGPoint(x: topMid.x + away.x / len * 26, y: topMid.y + away.y / len * 26))
    }

    /// change position / scale / rotation of the target (keyframe-aware for layers)
    func apply(_ tg: Target, _ f: (inout [Double], inout [Double], inout Double) -> Void) {
        var (p, s, r) = values(tg)
        let (p0, s0, r0) = (p, s, r)
        f(&p, &s, &r)
        switch tg {
        case .layer(let o, _):
            if p != p0 { editor.setLayerValue([o.id], "position", p, at: live.playhead) }
            if s != s0 { editor.setLayerValue([o.id], "scale", s, at: live.playhead) }
            if r != r0 { editor.setLayerValue([o.id], "rotation", [r], at: live.playhead) }
        case .clip(let c):
            if p != p0 { editor.setClipXf([c.id], "position", p, at: live.playhead) }
            if s != s0 { editor.setClipXf([c.id], "scale", [s[0]], at: live.playhead) }
            if r != r0 { editor.setClipXf([c.id], "rotation", [r], at: live.playhead) }
        }
    }
}
