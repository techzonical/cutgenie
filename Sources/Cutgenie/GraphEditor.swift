import SwiftUI
import CutgenieCore

// Graph editor (After Effects style): every animated property of the selected clip or graphic as a curve over time.
// Drag a keyframe to move it in time / value (⇧ = only one direction), drag the round bezier handles to shape the ease,
// double-click a curve to add a keyframe, Delete removes the selected ones. Edits are live; letting go is one undo step.

struct GraphEditor: View {
    @ObservedObject var editor: Editor
    @ObservedObject var live: LiveState
    @ObservedObject var dragState: DragState
    @State private var hidden: Set<String> = []          // channels switched off
    @State private var focusCh: String? = nil            // the channel whose numbers show on the left axis
    @State private var sel: Set<Int> = []                // selected keyframe indexes (of the focused channel's array)
    @State private var drag: Drag? = nil
    @State private var showAll = false                   // also list properties without keyframes
    @State private var zoom = 1.0                        // 1 = the whole clip; 4 = a quarter of it
    @State private var viewStart = 0.0                   // clip time at the left edge when zoomed
    @State private var pinch0 = 1.0
    @FocusState private var focused: Bool

    enum Kind { case xf, zoom, motion, layer }
    struct Chan: Identifiable {
        let id: String, name: String, prop: String, idx: Int, kind: Kind, k: Double, unit: String, color: Color, def: [Double], digits: Int
        var group: String { "\(kind)-\(prop)" }          // channels sharing one keyframe list (Position X and Y)
    }
    struct Drag { var mode: String; var ch: String; var i: Int; var start: CGPoint; var keys: [Keyframe]; var axis: Int = -1; var range: (Double, Double) }

    // MARK: target and channels
    enum Target { case clip(Clip), layer(Overlay) }
    var target: Target? {
        guard let id = editor.primarySelection ?? editor.selection.first ?? editor.selectedOverlay else { return nil }
        if let o = editor.liveLayer(id) { return .layer(o) }
        if let c = editor.liveUpperClip(id) { return .clip(c) }
        return nil
    }
    var tid: String { switch target { case .clip(let c): return c.id; case .layer(let o): return o.id; case nil: return "" } }
    var offset: Double { switch target { case .clip(let c): return c.offset; case .layer(let o): return o.offset; case nil: return 0 } }
    var duration: Double { switch target { case .clip(let c): return c.duration; case .layer(let o): return o.duration; case nil: return 1 } }
    var u: Double { Double(editor.project.settings.height) / 100 }
    var isV1: Bool { if case .clip(let c) = target { return editor.project.clips.contains { $0.id == c.id } }; return false }

    var allChans: [Chan] {
        guard let tg = target else { return [] }
        var out: [Chan] = []
        let pos = [Color(red: 1, green: 0.35, blue: 0.35), Color(red: 0.35, green: 0.85, blue: 0.4)]
        switch tg {
        case .clip:
            out += [Chan(id: "px", name: "Position X", prop: "position", idx: 0, kind: .xf, k: u, unit: "px", color: pos[0], def: [0, 0], digits: 0),
                    Chan(id: "py", name: "Position Y", prop: "position", idx: 1, kind: .xf, k: u, unit: "px", color: pos[1], def: [0, 0], digits: 0),
                    Chan(id: "sc", name: "Scale", prop: "scale", idx: 0, kind: .xf, k: 100, unit: "%", color: .cyan, def: [1], digits: 1),
                    Chan(id: "ro", name: "Rotation", prop: "rotation", idx: 0, kind: .xf, k: 1, unit: "°", color: .purple, def: [0], digits: 1),
                    Chan(id: "op", name: "Opacity", prop: "opacity", idx: 0, kind: .xf, k: 100, unit: "%", color: .white, def: [1], digits: 0)]
            if isV1 {
                out += [Chan(id: "zm", name: "Zoom", prop: "zoom", idx: 0, kind: .zoom, k: 100, unit: "%", color: .orange, def: [1], digits: 1),
                        Chan(id: "sx", name: "Slide X", prop: "motion", idx: 0, kind: .motion, k: u, unit: "px", color: .pink, def: [0, 0], digits: 0),
                        Chan(id: "sy", name: "Slide Y", prop: "motion", idx: 1, kind: .motion, k: u, unit: "px", color: .mint, def: [0, 0], digits: 0)]
            }
        case .layer:
            out += [Chan(id: "px", name: "Position X", prop: "position", idx: 0, kind: .layer, k: u, unit: "px", color: pos[0], def: [0, 0], digits: 0),
                    Chan(id: "py", name: "Position Y", prop: "position", idx: 1, kind: .layer, k: u, unit: "px", color: pos[1], def: [0, 0], digits: 0),
                    Chan(id: "sc", name: "Scale", prop: "scale", idx: 0, kind: .layer, k: 100, unit: "%", color: .cyan, def: [1, 1], digits: 1),
                    Chan(id: "ro", name: "Rotation", prop: "rotation", idx: 0, kind: .layer, k: 1, unit: "°", color: .purple, def: [0], digits: 1),
                    Chan(id: "op", name: "Opacity", prop: "opacity", idx: 0, kind: .layer, k: 100, unit: "%", color: .white, def: [1], digits: 0)]
        }
        return out
    }
    func animated(_ c: Chan) -> Bool { keys(c).count >= 2 }
    var chans: [Chan] { allChans.filter { showAll || animated($0) } }
    var visible: [Chan] { chans.filter { !hidden.contains($0.id) } }
    var focusChan: Chan? { visible.first { $0.id == focusCh } ?? visible.first }

    func keys(_ c: Chan) -> [Keyframe] {
        switch target {
        case .clip(let cl):
            switch c.kind {
            case .zoom: return cl.zoom ?? []
            case .motion: return cl.motion ?? []
            default: return cl.xf?.keys?[c.prop] ?? []
            }
        case .layer(let o): return Editor.keys(o, c.prop)
        case nil: return []
        }
    }
    /// value (raw units) at clip time, also for a property without keyframes
    func value(_ c: Chan, _ lt: Double) -> Double {
        let k = keys(c)
        if k.isEmpty, case .clip(let cl) = target, c.kind == .xf { let v = (cl.xf ?? ClipXf()).value(c.prop); return c.idx < v.count ? v[c.idx] : c.def[min(c.idx, c.def.count - 1)] }
        let v = KF.at(k, lt, c.def); return c.idx < v.count ? v[c.idx] : v[0]
    }
    func setKeys(_ c: Chan, _ k: [Keyframe]) {
        let k = k.sorted { $0.t < $1.t }
        switch c.kind {
        case .zoom: editor.liveZoom(tid) { $0 = k }
        case .motion: editor.liveMotion(tid) { $0 = k }
        case .xf: editor.liveUpper([tid]) { x in if x.keys == nil { x.keys = [:] }; x.keys?[c.prop] = k.isEmpty ? nil : k }
        case .layer: editor.liveLayers([tid]) { Editor.setKeys(&$0, c.prop, k) }
        }
    }

    // MARK: geometry
    struct Geo { var rect: CGRect; var t0: Double; var t1: Double
        func x(_ t: Double) -> CGFloat { rect.minX + CGFloat((t - t0) / max(0.0001, t1 - t0)) * rect.width }
        func t(_ x: CGFloat) -> Double { t0 + Double((x - rect.minX) / max(1, rect.width)) * (t1 - t0) }
    }
    /// value range shown for a channel: its curve fits the height
    func range(_ c: Chan) -> (Double, Double) {
        let k = keys(c)
        var vs = k.map { c.idx < $0.v.count ? $0.v[c.idx] : $0.v[0] }
        if vs.isEmpty { vs = [value(c, 0)] }
        // overshoot / bounce go past the keyframe values: sample the curve too
        for i in 0...60 { vs.append(value(c, duration * Double(i) / 60)) }
        var lo = vs.min()!, hi = vs.max()!
        if hi - lo < 1e-6 { let p = max(abs(lo) * 0.1, c.k == 100 ? 0.1 : 1 / c.k * 20); lo -= p; hi += p }
        let pad = (hi - lo) * 0.12
        return (lo - pad, hi + pad)
    }
    func y(_ v: Double, _ r: (Double, Double), _ g: Geo) -> CGFloat { g.rect.maxY - CGFloat((v - r.0) / (r.1 - r.0)) * g.rect.height }
    func v(_ y: CGFloat, _ r: (Double, Double), _ g: Geo) -> Double { r.0 + Double((g.rect.maxY - y) / max(1, g.rect.height)) * (r.1 - r.0) }

    /// the bezier handles of an ease, in 0...1 segment units (nil: not a curve we can show as handles)
    static func handles(_ e: String?) -> [Double]? {
        switch e ?? "linear" {
        case "linear": return [1 / 3, 1 / 3, 2 / 3, 2 / 3]
        case "in": return [0.32, 0, 0.67, 0]
        case "out": return [0.33, 1, 0.68, 1]
        case "s": return [0.65, 0, 0.35, 1]
        case "strong": return [0.16, 1, 0.3, 1]
        case "back": return [0.34, 1.56, 0.64, 1]
        default:
            if let e, e.hasPrefix("bez:") { let v = e.dropFirst(4).split(separator: ",").compactMap { Double($0) }; return v.count == 4 ? v : nil }
            return nil
        }
    }
    static func bez(_ h: [Double]) -> String { "bez:" + h.map { String(format: "%.3f", $0) }.joined(separator: ",") }

    /// handle points of keyframe i on a channel: (in handle, out handle) in view coordinates
    func handlePts(_ c: Chan, _ i: Int, _ g: Geo, _ r: (Double, Double)) -> (CGPoint?, CGPoint?) {
        let k = keys(c)
        func val(_ j: Int) -> Double { c.idx < k[j].v.count ? k[j].v[c.idx] : k[j].v[0] }
        var inP: CGPoint?, outP: CGPoint?
        if i > 0, let h = Self.handles(k[i].e) {
            let t = k[i - 1].t + h[2] * (k[i].t - k[i - 1].t), vv = val(i - 1) + h[3] * (val(i) - val(i - 1))
            inP = CGPoint(x: g.x(t), y: y(vv, r, g))
        }
        if i + 1 < k.count, let h = Self.handles(k[i + 1].e) {
            let t = k[i].t + h[0] * (k[i + 1].t - k[i].t), vv = val(i) + h[1] * (val(i + 1) - val(i))
            outP = CGPoint(x: g.x(t), y: y(vv, r, g))
        }
        return (inP, outP)
    }

    // MARK: view
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if target == nil {
                Text("Select a clip or graphic to see its keyframes as curves.").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    channelList.frame(width: 210)
                    Divider()
                    graph
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onChange(of: tid) { _, _ in sel = []; focusCh = nil }
    }

    var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(Brand.accent)
            Text("Graph editor").font(.system(size: 12, weight: .semibold))
            if let tg = target {
                Text("·  " + { switch tg { case .clip(let c): return URL(fileURLWithPath: editor.project.assets.first { $0.id == c.asset }?.path ?? c.id).lastPathComponent; case .layer(let o): return o.name.isEmpty ? "Layer" : o.name } }())
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(sel.isEmpty ? "Ease:" : "Ease into \(sel.count == 1 ? "keyframe" : "\(sel.count) keyframes"):").font(.caption).foregroundStyle(.secondary)
            ForEach([("linear", "Linear", "line.diagonal"), ("in", "In", "arrow.up.right"), ("out", "Out", "arrow.down.right"), ("s", "In & Out", "point.topleft.down.to.point.bottomright.curvepath"),
                     ("back", "Overshoot", "arrow.uturn.down"), ("bounce", "Bounce", "waveform.path")], id: \.0) { e in
                Button { applyEase(e.0) } label: { HStack(spacing: 3) { EaseCurve(e: e.0).frame(width: 18, height: 14); Text(e.1).font(.caption) } }
                    .buttonStyle(.bordered).controlSize(.small).disabled(focusChan == nil)
                    .help(sel.isEmpty ? "Set \(e.1) on every keyframe of the shown properties" : "Set \(e.1) on the selected keyframes")
            }
            Divider().frame(height: 16)
            Button { deleteSelected() } label: { Image(systemName: "trash") }.buttonStyle(.borderless).disabled(sel.isEmpty).help("Delete the selected keyframes (Delete)")
            Toggle("All properties", isOn: $showAll).toggleStyle(.checkbox).font(.caption).help("Also list properties that have no keyframes yet")
            Button { NotificationCenter.default.post(name: .toggleGraph, object: nil) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Close the graph editor (⇧⌘G)")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    var channelList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if chans.isEmpty {
                    Text("No keyframes on this item yet. Tick “All properties”, then double-click a line to add one, or use ◆ in the Effects panel.")
                        .font(.caption).foregroundStyle(.secondary).padding(10)
                }
                ForEach(chans) { c in
                    let lt = live.playhead - offset, on = !hidden.contains(c.id), isF = focusChan?.id == c.id
                    let k = keys(c), here = k.contains { abs($0.t - lt) < editor.frameLength * 0.5 }
                    HStack(spacing: 6) {
                        Button { if on { hidden.insert(c.id) } else { hidden.remove(c.id) } } label: {
                            Image(systemName: on ? "eye" : "eye.slash").font(.system(size: 10)).foregroundStyle(on ? .primary : .secondary)
                        }.buttonStyle(.borderless).help(on ? "Hide this curve" : "Show this curve")
                        RoundedRectangle(cornerRadius: 2).fill(c.color).frame(width: 10, height: 10)
                        Text(c.name).font(.caption).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.\(c.digits)f", value(c, lt) * c.k) + c.unit).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button { toggleKey(c, lt) } label: {
                            Image(systemName: here ? "diamond.fill" : "diamond").font(.system(size: 9)).foregroundStyle(here ? Color.yellow : (k.count >= 2 ? Color.orange : Color.secondary))
                        }.buttonStyle(.borderless).help(here ? "Remove the keyframe at the playhead" : "Add a keyframe at the playhead")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(isF ? Color.white.opacity(0.08) : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { focusCh = c.id; sel = []; hidden.remove(c.id) }
                }
            }.padding(.vertical, 6)
        }
    }

    var graph: some View {
        GeometryReader { gr in
            let d = max(0.04, duration), len = d / max(1, zoom), st = min(max(0, viewStart), d - len)
            let g = Geo(rect: CGRect(x: 44, y: 22, width: max(10, gr.size.width - 60), height: max(10, gr.size.height - 46)), t0: st, t1: st + len)
            let _ = dragState.tick
            Canvas { ctx, size in draw(&ctx, size, g) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { dragChanged($0, g) }.onEnded { _ in dragEnded() })
                .focusable().focused($focused).focusEffectDisabled()
                .simultaneousGesture(MagnifyGesture().onChanged { m in setZoom(pinch0 * m.magnification, around: live.playhead - offset) }.onEnded { _ in pinch0 = zoom })
                .overlay(alignment: .bottom) { zoomBar(g) }
                .onKeyPress(.delete) { deleteSelected(); return .handled }
                .onKeyPress(.deleteForward) { deleteSelected(); return .handled }
        }
    }

    func setZoom(_ z: Double, around t: Double) {
        let d = max(0.04, duration), nz = min(40, max(1, z)), len = d / nz
        viewStart = min(max(0, t - len / 2), d - len); zoom = nz
    }
    /// zoom in / out in time, fit, and a scroll bar for the shown part of the clip
    func zoomBar(_ g: Geo) -> some View {
        let d = max(0.04, duration)
        return HStack(spacing: 6) {
            Button { setZoom(zoom / 1.6, around: (g.t0 + g.t1) / 2); pinch0 = zoom } label: { Image(systemName: "minus.magnifyingglass") }.buttonStyle(.borderless).help("Show more time")
            Button { setZoom(zoom * 1.6, around: live.playhead - offset); pinch0 = zoom } label: { Image(systemName: "plus.magnifyingglass") }.buttonStyle(.borderless).help("Zoom in around the playhead (or pinch)")
            Button("Fit") { zoom = 1; viewStart = 0; pinch0 = 1 }.buttonStyle(.borderless).font(.caption).disabled(zoom == 1).help("Show the whole clip")
            if zoom > 1 {
                Slider(value: Binding(get: { g.t0 }, set: { viewStart = $0 }), in: 0...max(0.001, d - (g.t1 - g.t0))).controlSize(.mini)
            } else { Spacer() }
        }
        .font(.system(size: 11)).padding(.horizontal, 44).padding(.bottom, 2).frame(height: 20)
    }
    func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ g: Geo) {
        let r = g.rect
        ctx.fill(Path(r), with: .color(Color.black.opacity(0.25)))
        // time ruler: a line each second (or half / tenth when short)
        let d = g.t1 - g.t0, step = d > 20 ? 5.0 : d > 6 ? 1.0 : d > 2 ? 0.5 : 0.1
        var t = (g.t0 / step).rounded(.down) * step
        while t <= g.t1 + 1e-6 {
            let x = g.x(t)
            if x < r.minX - 1 { t += step; continue }
            ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY)) }, with: .color(.white.opacity(0.06)), lineWidth: 1)
            ctx.draw(Text(String(format: step < 1 ? "%.1fs" : "%.0fs", t)).font(.system(size: 9).monospacedDigit()).foregroundColor(.secondary), at: CGPoint(x: x, y: 10))
            t += step
        }
        // value axis for the focused channel
        if let f = focusChan {
            let rg = range(f)
            for i in 0...4 {
                let yy = r.minY + r.height * CGFloat(i) / 4, val = v(yy, rg, g) * f.k
                ctx.stroke(Path { p in p.move(to: CGPoint(x: r.minX, y: yy)); p.addLine(to: CGPoint(x: r.maxX, y: yy)) }, with: .color(.white.opacity(0.06)), lineWidth: 1)
                ctx.draw(Text(String(format: "%.\(f.digits)f", val)).font(.system(size: 9).monospacedDigit()).foregroundColor(f.color.opacity(0.9)), at: CGPoint(x: 22, y: yy))
            }
        }
        // curves: the focused one last (on top), others dimmer
        let order = visible.sorted { a, _ in a.id != focusChan?.id }
        ctx.clip(to: Path(r.insetBy(dx: -8, dy: -12)))
        for c in order {
            let rg = range(c), isF = c.id == focusChan?.id
            var p = Path()
            let n = max(60, Int(r.width / 2))
            for i in 0...n {
                let tt = g.t0 + d * Double(i) / Double(n), pt = CGPoint(x: g.x(tt), y: y(value(c, tt), rg, g))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(c.color.opacity(isF ? 1 : 0.45)), lineWidth: isF ? 2 : 1.2)
            let k = keys(c)
            for (i, kf) in k.enumerated() {
                let pt = CGPoint(x: g.x(kf.t), y: y(c.idx < kf.v.count ? kf.v[c.idx] : kf.v[0], rg, g))
                let s: CGFloat = isF ? 6 : 4.5, chosen = isF && sel.contains(i)
                if chosen {
                    let (hi, ho) = handlePts(c, i, g, rg)
                    for h in [hi, ho].compactMap({ $0 }) {
                        ctx.stroke(Path { q in q.move(to: pt); q.addLine(to: h) }, with: .color(.yellow.opacity(0.8)), lineWidth: 1)
                        ctx.fill(Path(ellipseIn: CGRect(x: h.x - 4.5, y: h.y - 4.5, width: 9, height: 9)), with: .color(.yellow))
                        ctx.stroke(Path(ellipseIn: CGRect(x: h.x - 4.5, y: h.y - 4.5, width: 9, height: 9)), with: .color(.black.opacity(0.6)), lineWidth: 1)
                    }
                }
                let dia = Path { q in q.move(to: CGPoint(x: pt.x, y: pt.y - s)); q.addLine(to: CGPoint(x: pt.x + s, y: pt.y)); q.addLine(to: CGPoint(x: pt.x, y: pt.y + s)); q.addLine(to: CGPoint(x: pt.x - s, y: pt.y)); q.closeSubpath() }
                ctx.fill(dia, with: .color(chosen ? .yellow : (isF ? c.color : c.color.opacity(0.6))))
                ctx.stroke(dia, with: .color(.black.opacity(0.7)), lineWidth: 1)
            }
        }
        // playhead
        let ph = live.playhead - offset
        if ph >= g.t0 && ph <= g.t1 {
            let x = g.x(ph)
            ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 2)); p.addLine(to: CGPoint(x: x, y: r.maxY)) }, with: .color(.red), lineWidth: 1.5)
        }
        if visible.isEmpty == false, let f = focusChan, keys(f).count >= 2, sel.isEmpty {
            ctx.draw(Text("Click a ◆ to select it and see its ease handles · double-click a line to add a keyframe · drag the top to move the playhead")
                .font(.system(size: 10)).foregroundColor(.secondary), at: CGPoint(x: r.midX, y: r.maxY - 10))
        }
    }

    // MARK: editing
    func seek(_ lt: Double) {
        let to = offset + max(0, min(duration, lt))
        editor.playhead = to; Task { _ = await editor.handle(["cmd": "seek", "time": to]) }
    }
    func dragChanged(_ gv: DragGesture.Value, _ g: Geo) {
        focused = true
        let p = gv.location
        if drag == nil {
            let start = gv.startLocation
            if NSApp.currentEvent?.clickCount == 2 { addKeyAt(start, g); drag = Drag(mode: "none", ch: "", i: 0, start: start, keys: [], range: (0, 1)); return }
            if start.y < g.rect.minY { drag = Drag(mode: "seek", ch: "", i: 0, start: start, keys: [], range: (0, 1)); seek(g.t(start.x)); return }
            // 1. a handle of a selected keyframe on the focused curve
            if let f = focusChan {
                let rg = range(f), k = keys(f)
                for i in sel where i < k.count {
                    let (hi, ho) = handlePts(f, i, g, rg)
                    if let hi, hypot(hi.x - start.x, hi.y - start.y) <= 8 { drag = Drag(mode: "in", ch: f.id, i: i, start: start, keys: k, range: rg); break }
                    if let ho, hypot(ho.x - start.x, ho.y - start.y) <= 8 { drag = Drag(mode: "out", ch: f.id, i: i, start: start, keys: k, range: rg); break }
                }
            }
            // 2. a keyframe on any visible curve (the focused one first)
            if drag == nil {
                let order = visible.sorted { a, _ in a.id == focusChan?.id }
                outer: for c in order {
                    let rg = range(c), k = keys(c)
                    for (i, kf) in k.enumerated() {
                        let pt = CGPoint(x: g.x(kf.t), y: y(c.idx < kf.v.count ? kf.v[c.idx] : kf.v[0], rg, g))
                        if hypot(pt.x - start.x, pt.y - start.y) <= 8 {
                            if focusChan?.id != c.id { focusCh = c.id; sel = [] }
                            if NSEvent.modifierFlags.contains(.command) { if sel.contains(i) { sel.remove(i) } else { sel.insert(i) } }
                            else if !sel.contains(i) { sel = [i] }
                            drag = Drag(mode: "key", ch: c.id, i: i, start: start, keys: k, range: rg)
                            seek(kf.t)
                            break outer
                        }
                    }
                }
            }
            if drag == nil { sel = []; drag = Drag(mode: "seek", ch: "", i: 0, start: start, keys: [], range: (0, 1)); seek(g.t(start.x)); return }
        }
        guard var dg = drag, let c = allChans.first(where: { $0.id == dg.ch }) else { if drag?.mode == "seek" { seek(g.t(p.x)) }; return }
        if dg.mode == "none" { return }
        if hypot(p.x - dg.start.x, p.y - dg.start.y) < 3 { return }
        var k = dg.keys
        func val(_ j: Int) -> Double { c.idx < k[j].v.count ? k[j].v[c.idx] : k[j].v[0] }
        switch dg.mode {
        case "key":
            var dx = p.x - dg.start.x, dy = p.y - dg.start.y
            if NSEvent.modifierFlags.contains(.shift) {
                if dg.axis < 0 { dg.axis = abs(dx) > abs(dy) ? 0 : 1; drag = dg }
                if dg.axis == 0 { dy = 0 } else { dx = 0 }
            }
            let dt = Double(dx) / Double(g.rect.width) * (g.t1 - g.t0)
            let dv = -Double(dy) / Double(g.rect.height) * (dg.range.1 - dg.range.0)
            let f = editor.frameLength
            let idxs = sel.contains(dg.i) ? sel : [dg.i]
            for i in idxs where i < k.count {
                let lo = i > 0 && !idxs.contains(i - 1) ? dg.keys[i - 1].t + f : 0
                let hi = i + 1 < k.count && !idxs.contains(i + 1) ? dg.keys[i + 1].t - f : duration
                k[i].t = min(hi, max(lo, ((dg.keys[i].t + dt) / f).rounded() * f))
                if c.idx < k[i].v.count { k[i].v[c.idx] = dg.keys[i].v[c.idx] + dv }
                if c.prop == "scale", c.kind == .layer, k[i].v.count == 2 { k[i].v[1] = k[i].v[0] }
            }
            setKeys(c, k)
            if dx != 0 { seek(k[dg.i].t) }
        case "in", "out":
            // the in handle belongs to the move into keyframe i; the out handle to the move into keyframe i + 1
            let seg = dg.mode == "in" ? dg.i : dg.i + 1
            guard seg > 0, seg < k.count else { return }
            let t0 = k[seg - 1].t, t1 = k[seg].t, v0 = val(seg - 1), v1 = val(seg)
            var h = Self.handles(k[seg].e) ?? [0.33, 0, 0.67, 1]
            let tt = Double(g.t(p.x)), vv = v(p.y, dg.range, g)
            let x = min(1, max(0, (tt - t0) / max(0.0001, t1 - t0)))
            let yv = abs(v1 - v0) < 1e-9 ? (dg.mode == "in" ? h[3] : h[1]) : max(-1.5, min(2.5, (vv - v0) / (v1 - v0)))
            if dg.mode == "in" { h[2] = x; h[3] = yv } else { h[0] = x; h[1] = yv }
            // ⌥: the other handle of the same keyframe mirrors this one (a smooth keyframe)
            k[seg].e = Self.bez(h)
            setKeys(c, k)
        default: break
        }
    }
    func dragEnded() {
        if let dg = drag, dg.mode != "seek", dg.mode != "none" { editor.commitLive() }
        drag = nil
    }
    func applyEase(_ e: String) {
        let targets = sel.isEmpty ? Set(visible.map(\.group)) : [focusChan?.group].compactMap { $0 }.reduce(into: Set<String>()) { $0.insert($1) }
        var done = Set<String>()
        for c in allChans where targets.contains(c.group) && !done.contains(c.group) {
            done.insert(c.group)
            var k = keys(c)
            for i in k.indices where i > 0 && (sel.isEmpty || sel.contains(i)) { k[i].e = e == "linear" ? nil : e }
            setKeys(c, k)
        }
        editor.commitLive()
    }
    func deleteSelected() {
        guard let f = focusChan, !sel.isEmpty else { return }
        var k = keys(f)
        for i in sel.sorted(by: >) where i < k.count { k.remove(at: i) }
        setKeys(f, k); editor.commitLive(); sel = []
    }
    func toggleKey(_ c: Chan, _ lt: Double) {
        var k = keys(c), half = editor.frameLength * 0.5
        half = max(half, 0.001)
        if let i = k.firstIndex(where: { abs($0.t - lt) < half }) { k.remove(at: i) }
        else {
            var v = KF.at(k, lt, c.def)
            if k.isEmpty, case .clip(let cl) = target, c.kind == .xf { v = (cl.xf ?? ClipXf()).value(c.prop) }
            if k.isEmpty, case .layer(let o) = target { v = editor.layerValue(o, c.prop, at: offset + lt) }
            k.append(Keyframe(t: max(0, min(duration, lt)), v: v))
        }
        setKeys(c, k); editor.commitLive(); focusCh = c.id
    }
    func addKeyAt(_ p: CGPoint, _ g: Geo) {
        guard p.y >= g.rect.minY else { return }
        let lt = (g.t(p.x) / editor.frameLength).rounded() * editor.frameLength
        // the curve nearest to the click
        let best = visible.min { a, b in abs(y(value(a, lt), range(a), g) - p.y) < abs(y(value(b, lt), range(b), g) - p.y) }
        guard let c = best, abs(y(value(c, lt), range(c), g) - p.y) < 14 else { return }
        if !keys(c).contains(where: { abs($0.t - lt) < editor.frameLength * 0.5 }) { toggleKey(c, lt) }
        seek(lt)
    }
}

extension Notification.Name { static let toggleGraph = Notification.Name("cutgenie.toggleGraph") }
