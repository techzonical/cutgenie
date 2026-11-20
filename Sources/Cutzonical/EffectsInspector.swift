import SwiftUI
import CutzonicalCore

// Effects tab. Graphic layers selected -> transform with keyframes, crop, fades, blend mode and an effect stack
// (applies to every selected layer at once). A sound / video clip selected -> its volume and fades (ClipInspector).
struct EffectsInspector: View {
    @ObservedObject var editor: Editor
    var layerIDs: [String] {
        let ids = editor.selection.isEmpty ? [editor.selectedOverlay].compactMap { $0 } : (editor.primarySelection.map { [$0] } ?? Array(editor.selection))
        let ov = Set((editor.project.overlays ?? []).map { $0.id })
        return ids.allSatisfy { ov.contains($0) } ? ids.sorted() : []
    }
    var upperID: String? {
        guard let id = editor.primarySelection else { return nil }
        // any video clip, on V1 or above: crop / position / scale / shadow
        return (editor.project.upperClips ?? []).contains(where: { $0.id == id }) || editor.project.clips.contains(where: { $0.id == id }) ? id : nil
    }
    var body: some View { SectionsPanel { panel } }
    @ViewBuilder var panel: some View {
        if let u = upperID { ScrollView { VStack(alignment: .leading, spacing: 0) { PipControls(editor: editor, dragState: editor.drag, live: editor.live, id: u); ClipInspector(editor: editor).frame(minHeight: 380) } } }
        else if layerIDs.isEmpty { ClipInspector(editor: editor) }
        else { LayerEffects(editor: editor, live: editor.live, dragState: editor.drag, ids: layerIDs).id(layerIDs.joined(separator: ",")) }
    }
}

struct LayerEffects: View {
    @ObservedObject var editor: Editor
    @ObservedObject var live: LiveState
    @ObservedObject var dragState: DragState
    let ids: [String]
    @State private var open: Set<String> = []          // effects shown expanded
    @State private var presetTick = 0
    func askName(_ title: String) -> String? {
        let a = NSAlert(); a.messageText = title; a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); a.accessoryView = f; a.window.initialFirstResponder = f
        return a.runModal() == .alertFirstButtonReturn && !f.stringValue.isEmpty ? f.stringValue : nil
    }

    var layers: [Overlay] { ids.compactMap { editor.liveLayer($0) } }      // includes a drag in progress
    var first: Overlay? { layers.first }
    var t: Double { live.playhead }
    var u: Double { Double(editor.project.settings.height) / 100 }        // Final Cut position unit -> pixels
    var locked: Bool { ids.contains { editor.lockedTrack(of: $0) != nil } }

    func done() { editor.commitLive() }
    func header(_ s: String) -> some View { Text(s.uppercased()).font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 8) }

    // MARK: keyframe-aware row (value at the playhead; diamond = keyframe here)
    func keyRow(_ title: String, prop: String, index: Int, range: ClosedRange<Double>, scale k: Double, unit: String, digits: Int = 0) -> AnyView {
        guard let o = first else { return AnyView(EmptyView()) }      // the layer can vanish under the panel
        let cur = editor.layerValue(o, prop, at: t)
        let keys = Editor.keys(o, prop)
        let local = t - o.offset
        let here = keys.count >= 2 && keys.contains { abs($0.t - local) < editor.frameLength * 0.5 }
        let animated = keys.count >= 2
        let val = (index < cur.count ? cur[index] : cur[0]) * k
        func set(_ x: Double) {
            var v = cur; let raw = x / k
            if index < v.count { v[index] = raw } else { v = [raw] }
            if prop == "scale" { v = [raw, raw] }
            editor.setLayerValue(ids, prop, v, at: t)
        }
        return AnyView(HStack(spacing: 5) {
            Text(title).font(.caption).frame(width: 62, alignment: .leading)
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, val)) }, set: set), in: range, onEditingChanged: { if !$0 { done() } })
            TextField("", value: Binding(get: { val }, set: { set($0); done() }), format: .number.precision(.fractionLength(digits)))
                .textFieldStyle(.roundedBorder).font(.caption.monospacedDigit()).frame(width: 52)
            Text(unit).font(.caption2).foregroundStyle(.secondary).frame(width: 14, alignment: .leading)
            if index == 0 {
                HStack(spacing: 4) {
                Button { jump(keys, o, forward: false) } label: { Image(systemName: "chevron.left").font(.system(size: 8)) }
                    .buttonStyle(.borderless).disabled(!animated).help("Previous keyframe")
                Button { editor.toggleLayerKey(ids, prop, at: t) } label: {
                    Image(systemName: here ? "diamond.fill" : "diamond").font(.system(size: 10)).foregroundStyle(here ? Color.yellow : (animated ? Color.orange : Color.secondary))
                }.buttonStyle(.borderless)
                .help(here ? "Remove the keyframe at the playhead. Right-click: easing into this keyframe" : "Add a keyframe at the playhead (animate \(title.lowercased()))")
                .contextMenu {
                    if here, let k = keys.first(where: { abs($0.t - local) < editor.frameLength * 0.5 }) {
                        let cur = k.e ?? "linear"
                        Text("Easing into this keyframe")
                        ForEach(Ease.presets.filter { !$0.id.hasPrefix("bez:") }, id: \.id) { p in
                            Button { editor.setKeyEase(ids, prop, at: t, p.id) } label: { Text((cur == p.id ? "✓ " : "") + p.name) }
                        }
                        if cur.hasPrefix("bez:") { Text("✓ Custom Bezier") }
                    } else { Text("Move the playhead onto a keyframe to set its easing") }
                }
                Button { jump(keys, o, forward: true) } label: { Image(systemName: "chevron.right").font(.system(size: 8)) }
                    .buttonStyle(.borderless).disabled(!animated).help("Next keyframe")
                }.frame(width: 50)
            } else { Color.clear.frame(width: 50, height: 1) }
        })
    }
    static func col(_ c: [Double]?, _ d: [Double] = [1, 1, 1, 1]) -> Color { let v = c ?? d; return Color(.sRGB, red: v[0], green: v[1], blue: v[2], opacity: v.count > 3 ? v[3] : 1) }
    static func comps(_ c: Color) -> [Double] {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
        return [Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent), Double(n.alphaComponent)]
    }
    func colorRow(_ title: String, _ c: [Double]?, _ set: @escaping ([Double]) -> Void) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 62, alignment: .leading)
            ColorPicker("", selection: Binding(get: { Self.col(c) }, set: { set(Self.comps($0)); done() }), supportsOpacity: true).labelsHidden()
            Spacer()
        }
    }
    func editShape(_ f: @escaping (inout ShapeSpec) -> Void) { editor.liveLayers(ids) { l in if var s = l.shape { f(&s); l.shape = s } } }
    @ViewBuilder func shapeSection(_ sh: ShapeSpec) -> some View {
        InspectorSection("Shape", key: "fx.shape", open: true, changed: false) {
            let locked = sh.lock == true && sh.kind != "line"
            HStack(alignment: .center, spacing: 4) {
                VStack(spacing: 2) {
                    plain("Width", sh.w, 2...(PW*2), unit: "px") { v in editShape { s in let v = max(2, v); if locked, s.w > 0 { s.h = max(2, (s.h * v / s.w).rounded()) }; s.w = v } }
                    if sh.kind != "line" { plain("Height", sh.h, 2...(PH*2), unit: "px") { v in editShape { s in let v = max(2, v); if locked, s.h > 0 { s.w = max(2, (s.w * v / s.h).rounded()) }; s.h = v } } }
                }
                if sh.kind != "line" {
                    Button { editShape { $0.lock = $0.lock == true ? nil : true }; done() } label: {
                        Image(systemName: locked ? "lock.fill" : "lock.open").foregroundStyle(locked ? Brand.accent : .secondary).frame(width: 18)
                    }.buttonStyle(.borderless).help(locked ? "Width and height are locked together. Click to unlock." : "Lock width and height together (or hold ⇧ while dragging on the picture)")
                }
            }
            HStack(spacing: 6) {
                Text("Size").font(.caption).frame(width: 62, alignment: .leading)
                if sh.kind != "line" {
                    Button("Square") { editShape { s in let m = min(s.w, s.h); s.w = m; s.h = m }; done() }.help("Make width and height equal")
                    Button("Full frame") { let fw = Double(editor.project.settings.width), fh = Double(editor.project.settings.height); editShape { s in s.w = fw; s.h = fh }; editor.liveLayers(ids) { l in l.position = []; l.scale = []; l.rotation = nil }; done() }
                        .help("Cover the whole picture and centre it")
                }
                Button("½") { editShape { s in s.w = max(2, (s.w / 2).rounded()); if s.kind != "line" { s.h = max(2, (s.h / 2).rounded()) } }; done() }.help("Half the size")
                Button("×2") { editShape { s in s.w = min(3840, s.w * 2); if s.kind != "line" { s.h = min(2160, s.h * 2) } }; done() }.help("Double the size")
                Spacer()
            }.controlSize(.small)
            if sh.kind == "rect" || (sh.kind == "blur" && sh.round != true) { plain("Corners", sh.radius ?? 0, 0...500, unit: "px") { v in editShape { $0.radius = v > 0.5 ? v : nil } } }
            if sh.kind == "blur" {
                HStack {
                    Text("Hide by").font(.caption).frame(width: 62, alignment: .leading)
                    Picker("", selection: Binding(get: { sh.style ?? "blur" }, set: { v in editShape { $0.style = v }; done() })) {
                        Text("Blur").tag("blur"); Text("Pixelate").tag("pixelate")
                    }.pickerStyle(.segmented).labelsHidden()
                    Picker("", selection: Binding(get: { sh.round == true }, set: { v in editShape { $0.round = v ? true : nil }; done() })) {
                        Image(systemName: "rectangle").tag(false); Image(systemName: "oval").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 76)
                }
                plain(sh.style == "pixelate" ? "Block size" : "Strength", sh.amount ?? 30, 2...120, unit: "px") { v in editShape { $0.amount = v } }
                plain("Soft edge", sh.feather ?? 0, 0...80, unit: "px") { v in editShape { $0.feather = v > 0.2 ? v : nil } }
                Text("Place and size it over what to hide; keyframe Position to follow moving text.").font(.caption2).foregroundStyle(.secondary)
            }
            if sh.kind != "blur" {
            HStack {
                Text("Fill").font(.caption).frame(width: 62, alignment: .leading)
                if !(sh.kind == "solid" || sh.kind == "gradient") { Toggle("", isOn: Binding(get: { sh.fill != nil }, set: { on in editShape { $0.fill = on ? [1, 1, 1, 1] : nil }; done() })).labelsHidden().toggleStyle(.checkbox) }
                if sh.fill != nil || sh.kind == "solid" || sh.kind == "gradient" {
                    ColorPicker("", selection: Binding(get: { Self.col(sh.fill) }, set: { c in editShape { $0.fill = Self.comps(c) }; done() }), supportsOpacity: true).labelsHidden()
                }
                if sh.kind == "gradient" {
                    Text("to").font(.caption2).foregroundStyle(.secondary)
                    ColorPicker("", selection: Binding(get: { Self.col(sh.fill2) }, set: { c in editShape { $0.fill2 = Self.comps(c) }; done() }), supportsOpacity: true).labelsHidden()
                }
                Spacer()
            }
            }
            if sh.kind == "gradient" { plain("Angle", sh.angle ?? 0, 0...360, unit: "°") { v in editShape { $0.angle = v } } }
            if sh.kind == "line" { plain("Thickness", sh.strokeWidth ?? 8, 1...100, unit: "px") { v in editShape { $0.strokeWidth = v } } }
            if sh.kind == "rect" || sh.kind == "circle" {
                plain("Outline", sh.strokeWidth ?? 0, 0...60, unit: "px") { v in editShape { $0.strokeWidth = v > 0.2 ? v : nil; if $0.strokeColor == nil { $0.strokeColor = [1, 1, 1, 1] } } }
                if (sh.strokeWidth ?? 0) > 0 { colorRow("Outline col.", sh.strokeColor) { c in editShape { $0.strokeColor = c } } }
            }
        }
    }
    func edit(_ f: @escaping (inout MaskSpec) -> Void) { editor.liveLayers(ids) { l in var x = l.mask ?? MaskSpec(); f(&x); l.mask = x } }
    @ViewBuilder func maskRows(_ o: Overlay) -> some View {
        let m = o.mask
        HStack {
            Text("Shape").font(.caption).frame(width: 62, alignment: .leading)
            Picker("", selection: Binding(get: { m?.kind ?? "none" }, set: { k in
                editor.liveLayers(ids) { l in if k == "none" { l.mask = nil } else { var x = l.mask ?? MaskSpec(); x.kind = k; l.mask = x } }; done() })) {
                Text("None").tag("none"); Text("Rectangle").tag("rect"); Text("Circle").tag("circle")
            }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
            Spacer()
        }
        if let m {
            plain("Centre X", m.x, -PW...PW, unit: "px") { v in edit { $0.x = v } }
            plain("Centre Y", m.y, -PH...PH, unit: "px") { v in edit { $0.y = v } }
            plain("Width", m.w, 1...(PW*2), unit: "px") { v in edit { $0.w = v } }
            plain("Height", m.h, 1...(PH*2), unit: "px") { v in edit { $0.h = v } }
            if m.kind == "rect" { plain("Corners", m.radius ?? 0, 0...500, unit: "px") { v in edit { $0.radius = v > 0.5 ? v : nil } } }
            plain("Feather", m.feather ?? 0, 0...200, unit: "px") { v in edit { $0.feather = v > 0.3 ? v : nil } }
            Toggle("Invert (keep the outside)", isOn: Binding(get: { m.invert == true }, set: { v in edit { $0.invert = v ? true : nil }; done() }))
                .toggleStyle(.checkbox).font(.caption)
        }
    }
    func editBehaviour(_ i: Int, _ f: @escaping (inout Behaviour) -> Void) {
        editor.liveLayers(ids) { l in guard var bs = l.behaviours, i < bs.count else { return }; f(&bs[i]); l.behaviours = bs }
    }
    @ViewBuilder func behaviourRows(_ o: Overlay) -> some View {
        let bs = o.behaviours ?? []
        ForEach(Array(bs.enumerated()), id: \.1.id) { i, b in
            HStack {
                Toggle("", isOn: Binding(get: { b.on }, set: { v in editBehaviour(i) { $0.on = v }; done() })).labelsHidden().toggleStyle(.checkbox)
                Text(Behaviour.types.first { $0.id == b.type }?.name ?? b.type).font(.caption.bold())
                Spacer()
                Button { editor.liveLayers(ids) { l in l.behaviours?.removeAll { $0.id == b.id }; if l.behaviours?.isEmpty == true { l.behaviours = nil } }; done() } label: {
                    Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove this behaviour")
            }
            switch b.type {
            case "wiggle":
                plain("Amount", b.amount, 0...200, unit: "px") { v in editBehaviour(i) { $0.amount = v } }
                plain("Speed", b.speed, 0.1...10, digits: 1, unit: "/s") { v in editBehaviour(i) { $0.speed = v } }
            case "drift":
                plain("Speed", b.amount, 0...500, unit: "px/s") { v in editBehaviour(i) { $0.amount = v } }
                plain("Direction", b.angle ?? 0, 0...360, unit: "°") { v in editBehaviour(i) { $0.angle = v } }
            case "pulse":
                plain("Amount", b.amount, 0...50, digits: 1, unit: "%") { v in editBehaviour(i) { $0.amount = v } }
                plain("Speed", b.speed, 0.1...10, digits: 1, unit: "/s") { v in editBehaviour(i) { $0.speed = v } }
            default:
                plain("Speed", b.speed, -720...720, unit: "°/s") { v in editBehaviour(i) { $0.speed = v } }
            }
        }
        Menu("Add behaviour") {
            ForEach(Behaviour.types, id: \.id) { t in Button(t.name) { editor.liveLayers(ids) { l in l.behaviours = (l.behaviours ?? []) + [Behaviour(type: t.id)] }; done() } }
        }.fixedSize()
    }
    /// one Build In or Build Out: type menu, then its length (and direction / amount where it has one)
    @ViewBuilder func buildRows(_ title: String, _ b: Build?, _ o: Overlay, _ edit: @escaping ((inout Build?) -> Void) -> Void) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 62, alignment: .leading)
            Picker("", selection: Binding(get: { b?.type ?? "none" }, set: { ty in
                edit { x in if ty == "none" { x = nil } else { var n = x ?? Build(type: ty); n.type = ty; n.amount = nil; x = n } }; done() })) {
                Text("None").tag("none")
                ForEach(Build.types.filter { o.text != nil || !["typewriter", "words"].contains($0.id) }, id: \.id) { Text($0.name).tag($0.id) }
            }.labelsHidden().frame(width: 170)
            Spacer()
        }
        if let b {
            plain("Length", b.dur, 0.05...min(5, max(0.1, o.duration)), digits: 2, unit: "s") { v in edit { $0?.dur = v } }
            if b.type == "slide" {
                HStack {
                    Text(title == "Build In" ? "From" : "To").font(.caption).frame(width: 62, alignment: .leading)
                    Picker("", selection: Binding(get: { b.dir ?? "left" }, set: { d in edit { $0?.dir = d }; done() })) {
                        ForEach(["left", "right", "up", "down"], id: \.self) { Text($0.capitalized).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    Spacer()
                }
                plain("Distance", b.amount ?? 300, 0...1920, unit: "px") { v in edit { $0?.amount = v } }
            }
            if b.type == "scale" { plain("Start size", (b.amount ?? 0) * 100, 0...200, unit: "%") { v in edit { $0?.amount = v / 100 } } }
            if b.type == "blur" { plain("Blur", b.amount ?? 30, 0...100, unit: "px") { v in edit { $0?.amount = v } } }
        }
    }
    func jump(_ keys: [Keyframe], _ o: Overlay, forward: Bool) {
        let local = t - o.offset, f = editor.frameLength * 0.5
        let k = forward ? keys.first { $0.t > local + f } : keys.last { $0.t < local - f }
        if let k { Task { _ = await editor.handle(["cmd": "seek", "time": o.offset + k.t]) } }
    }

    /// plain slider for a still property (crop, fades, effect numbers); live, one undo step per drag
    func plain(_ title: String, _ value: Double, _ range: ClosedRange<Double>, digits: Int = 0, unit: String = "", _ set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.caption).frame(width: 62, alignment: .leading)
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, value)) }, set: set), in: range, onEditingChanged: { if !$0 { done() } })
            TextField("", value: Binding(get: { value }, set: { set($0); done() }), format: .number.precision(.fractionLength(digits)))
                .textFieldStyle(.roundedBorder).font(.caption.monospacedDigit()).frame(width: 52)
            Text(unit).font(.caption2).foregroundStyle(.secondary).frame(width: 14, alignment: .leading)
            Color.clear.frame(width: 50, height: 1)
        }
    }

    // MARK: effect stack (edits go to the same effect on every selected layer: n-th effect of that type)
    func editFx(_ fx: LayerEffect, _ f: @escaping (inout LayerEffect) -> Void) {
        guard let o = first, let idx = o.effects?.firstIndex(where: { $0.id == fx.id }) else { return }
        let nth = o.effects![..<idx].filter { $0.type == fx.type }.count
        editor.liveLayers(ids) { l in
            guard var e = l.effects else { return }
            let matches = e.indices.filter { e[$0].type == fx.type }
            if nth < matches.count { f(&e[matches[nth]]) }
            l.effects = e
        }
    }
    static let ranges: [String: [(String, String, ClosedRange<Double>, Int)]] = [
        "shadow": [("distance", "Distance", 0...80, 0), ("angle", "Angle", 0...360, 0), ("softness", "Softness", 0...60, 0), ("opacity", "Opacity", 0...1, 2)],
        "glow": [("radius", "Radius", 0...80, 0), ("intensity", "Intensity", 0...2, 2)],
        "stroke": [("width", "Width", 0...30, 1), ("opacity", "Opacity", 0...1, 2)],
        "corners": [("radius", "Radius", 0...200, 0)],
        "blur": [("amount", "Amount", 0...50, 1)],
        "color": [("brightness", "Brightness", -0.5...0.5, 2), ("contrast", "Contrast", 0.5...1.5, 2), ("saturation", "Saturation", 0...2, 2)],
        "tint": [("amount", "Amount", 0...1, 2)],
    ]
    func fxCard(_ fx: LayerEffect, index: Int, count: Int) -> some View {
        let name = LayerEffect.catalog.first { $0.type == fx.type }?.name ?? fx.type
        let isOpen = open.contains(fx.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { if isOpen { open.remove(fx.id) } else { open.insert(fx.id) } } label: {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.system(size: 9)).frame(width: 12)
                }.buttonStyle(.borderless)
                Toggle("", isOn: Binding(get: { fx.on }, set: { v in editFx(fx) { $0.on = v }; done() })).toggleStyle(.checkbox).labelsHidden()
                Text(name).font(.caption.bold()).foregroundStyle(fx.on ? .primary : .secondary)
                Spacer()
                Button { move(fx, -1) } label: { Image(systemName: "arrow.up").font(.system(size: 9)) }.buttonStyle(.borderless).disabled(index == 0).help("Move up (applied earlier)")
                Button { move(fx, 1) } label: { Image(systemName: "arrow.down").font(.system(size: 9)) }.buttonStyle(.borderless).disabled(index == count - 1).help("Move down (applied later)")
                Button { remove(fx) } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.borderless).help("Remove effect")
            }
            if isOpen {
                ForEach(Self.ranges[fx.type] ?? [], id: \.0) { k, title, range, digits in
                    plain(title, fx.p[k] ?? 0, range, digits: digits) { v in editFx(fx) { $0.p[k] = v } }
                }
                if fx.p["r"] != nil {
                    HStack {
                        Text("Colour").font(.caption).frame(width: 62, alignment: .leading)
                        ColorPicker("", selection: Binding(get: { Color(red: fx.p["r"] ?? 1, green: fx.p["g"] ?? 1, blue: fx.p["b"] ?? 1) }, set: { c in
                            let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
                            editFx(fx) { $0.p["r"] = n.redComponent; $0.p["g"] = n.greenComponent; $0.p["b"] = n.blueComponent }
                            done()
                        }), supportsOpacity: false).labelsHidden()
                        Spacer()
                    }
                }
            }
        }
        .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
    }
    func move(_ fx: LayerEffect, _ d: Int) {
        editor.liveLayers(ids) { l in
            guard var e = l.effects, let i = e.firstIndex(where: { $0.type == fx.type }) else { return }
            let j = i + d; guard e.indices.contains(j) else { return }
            e.swapAt(i, j); l.effects = e
        }
        done()
    }
    func remove(_ fx: LayerEffect) {
        guard let o = first, let idx = o.effects?.firstIndex(where: { $0.id == fx.id }) else { return }
        let nth = o.effects![..<idx].filter { $0.type == fx.type }.count
        editor.liveLayers(ids) { l in
            guard var e = l.effects else { return }
            let m = e.indices.filter { e[$0].type == fx.type }
            if nth < m.count { e.remove(at: m[nth]) }
            l.effects = e.isEmpty ? nil : e
        }
        done()
    }
    func add(_ type: String) {
        guard let cat = LayerEffect.catalog.first(where: { $0.type == type }) else { return }
        let id = UUID().uuidString
        editor.liveLayers(ids) { l in l.effects = (l.effects ?? []) + [LayerEffect(id: id + l.id, type: type, p: cat.defaults)] }
        done()
        if let e = first?.effects?.last { open.insert(e.id) }
    }

    var body: some View {
        ScrollView {
            if let o = first {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(ids.count > 1 ? "\(ids.count) layers" : (o.name.isEmpty ? "Layer" : o.name)).font(.headline).lineLimit(1)
                        Spacer()
                        Menu("Effects") {
                            Button("Copy effects") { editor.layerClipboard = o }
                            Button("Paste effects") {
                                if let c = editor.layerClipboard {
                                    editor.liveLayers(ids) { l in l.effects = c.effects.map { $0.map { var e = $0; e.id = UUID().uuidString; return e } }; l.crop = c.crop; l.blend = c.blend; l.fadeIn = c.fadeIn; l.fadeOut = c.fadeOut }
                                    done()
                                }
                            }.disabled(editor.layerClipboard == nil)
                            Divider()
                            Button("Save as title…") {
                                if let n = askName("Title name") { Task { _ = await editor.handle(["cmd": "save_title", "name": n, "ids": ids.joined(separator: ",")]) } }
                            }.disabled(!(editor.project.overlays ?? []).filter { ids.contains($0.id) }.allSatisfy { $0.asset.isEmpty })
                            .help("Keeps these text / shape layers (look, builds, keyframes) for every project: Edit ▸ Add title")
                            Button("Save as preset…") { if let n = askName("Preset name") { Editor.savePreset(n, from: o); presetTick += 1 } }
                            if !Editor.presetNames.isEmpty {
                                Menu("Apply preset") { ForEach(Editor.presetNames, id: \.self) { n in Button(n) { editor.applyPreset(n, to: ids) } } }
                                Menu("Delete preset") { ForEach(Editor.presetNames, id: \.self) { n in Button(n) { Editor.deletePreset(n); presetTick += 1 } } }
                            }
                            Divider()
                            Button("Reset effects") { editor.liveLayers(ids) { l in l.effects = nil; l.crop = nil; l.blend = nil; l.fadeIn = nil; l.fadeOut = nil }; done() }
                        }.menuStyle(.borderlessButton).fixedSize().font(.caption)
                    }
                    if locked { Text("This track is locked - unlock it to change these.").font(.caption).foregroundStyle(.orange) }
                    if ids.count > 1 { Text("Editing all \(ids.count) together").font(.caption2).foregroundStyle(.secondary) }

                    if ids.count == 1, o.text != nil { TextSection(editor: editor, layer: o) }
                    if ids.count == 1, let sh = o.shape { shapeSection(sh) }
                    InspectorSection("Transform", key: "fx.transform", open: true,
                                     changed: Editor.keys(o, "position").count + Editor.keys(o, "scale").count + Editor.keys(o, "rotation").count + Editor.keys(o, "opacity").count > 0) {
                    keyRow("Position X", prop: "position", index: 0, range: -PW...PW, scale: u, unit: "px")
                    keyRow("Position Y", prop: "position", index: 1, range: -PH...PH, scale: u, unit: "px")
                    keyRow("Scale", prop: "scale", index: 0, range: 0...400, scale: 100, unit: "%")
                    keyRow("Rotation", prop: "rotation", index: 0, range: -180...180, scale: 1, unit: "°")
                    keyRow("Opacity", prop: "opacity", index: 0, range: 0...100, scale: 100, unit: "%")
                    let anyKeys = ["position", "scale", "rotation", "opacity"].contains { Editor.keys(o, $0).count >= 2 }
                    let ease = Editor.ease(of: o)
                    HStack {
                        Text("Easing").font(.caption).frame(width: 62, alignment: .leading)
                        Picker("", selection: Binding(get: { ease.hasPrefix("bez:") ? "bez:0.25,0.1,0.25,1" : ease }, set: { editor.setEase(ids, $0 == "bez:0.25,0.1,0.25,1" && ease.hasPrefix("bez:") ? ease : $0) })) {
                            ForEach(Ease.presets, id: \.id) { Text($0.name).tag($0.id) }
                        }.labelsHidden().frame(width: 190).disabled(!anyKeys)
                        .help(anyKeys ? "How the motion speeds up / slows down between keyframes" : "Add keyframes (◆) first")
                        EaseCurve(e: ease).frame(width: 34, height: 22)
                        Spacer()
                    }
                    let mixed = Set(["position", "scale", "rotation", "opacity"].flatMap { Editor.keys(o, $0).dropFirst().map { $0.e ?? "linear" } }).count > 1
                    if mixed { Text("Keyframes have different easings (right-click a ◆ to set one). Choosing here sets them all.").font(.caption2).foregroundStyle(.secondary) }
                    if ease.hasPrefix("bez:"), anyKeys { BezierEditor(e: ease) { editor.setEase(ids, $0, commit: false) } done: { done() } }
                    Toggle("Anchor on the graphic", isOn: Binding(get: { o.anchor != nil }, set: { on in
                        if on { editor.anchorOnGraphic(ids) } else { editor.liveLayers(ids) { $0.anchor = nil }; done() } }))
                        .toggleStyle(.checkbox).font(.caption)
                        .help("On: scale and rotate around the middle of the visible graphic. Off: around the frame centre.")
                    }

                    let cr = o.crop ?? [0, 0, 0, 0]
                    InspectorSection("Crop", key: "fx.crop", open: false, changed: o.crop != nil,
                                     reset: { editor.liveLayers(ids) { $0.crop = nil }; done() }) {
                    ForEach(Array(["Left", "Right", "Top", "Bottom"].enumerated()), id: \.0) { i, n in
                        plain(n, cr[i] * 100, 0...45, unit: "%") { v in editor.liveLayers(ids) { l in var c = l.crop ?? [0, 0, 0, 0]; c[i] = v / 100; l.crop = c.allSatisfy { $0 == 0 } ? nil : c } }
                    }
                    }

                    InspectorSection("Mask", key: "fx.mask", open: false, changed: o.mask != nil,
                                     reset: { editor.liveLayers(ids) { $0.mask = nil }; done() }) { maskRows(o) }

                    InspectorSection("Behaviours", key: "fx.behave", open: false, changed: !(o.behaviours ?? []).isEmpty,
                                     reset: { editor.liveLayers(ids) { $0.behaviours = nil }; done() }) { behaviourRows(o) }

                    InspectorSection("Build In / Out", key: "fx.build", open: false, changed: o.buildIn != nil || o.buildOut != nil,
                                     reset: { editor.liveLayers(ids) { $0.buildIn = nil; $0.buildOut = nil }; done() }) {
                    buildRows("Build In", o.buildIn, o) { f in editor.liveLayers(ids) { l in f(&l.buildIn) } }
                    Divider()
                    buildRows("Build Out", o.buildOut, o) { f in editor.liveLayers(ids) { l in f(&l.buildOut) } }
                    }

                    InspectorSection("Fade & blend", key: "fx.fade", open: false, changed: o.fadeIn != nil || o.fadeOut != nil || o.blend != nil,
                                     reset: { editor.liveLayers(ids) { $0.fadeIn = nil; $0.fadeOut = nil; $0.blend = nil }; done() }) {
                    plain("Fade in", o.fadeIn ?? 0, 0...min(5, o.duration), digits: 2, unit: "s") { v in editor.liveLayers(ids) { $0.fadeIn = v > 0.005 ? v : nil } }
                    plain("Fade out", o.fadeOut ?? 0, 0...min(5, o.duration), digits: 2, unit: "s") { v in editor.liveLayers(ids) { $0.fadeOut = v > 0.005 ? v : nil } }
                    HStack {
                        Text("Blend").font(.caption).frame(width: 62, alignment: .leading)
                        Picker("", selection: Binding(get: { o.blend ?? "normal" }, set: { b in editor.liveLayers(ids) { $0.blend = b == "normal" ? nil : b }; done() })) {
                            ForEach(["normal", "screen", "add", "lighten", "multiply", "darken", "overlay"], id: \.self) { Text($0.capitalized).tag($0) }
                        }.labelsHidden().frame(width: 140)
                        Spacer()
                    }
                    }

                    let fx = o.effects ?? []
                    InspectorSection("Effects", key: "fx.effects", open: true, changed: !fx.isEmpty,
                                     reset: { editor.liveLayers(ids) { $0.effects = nil }; done() }) {
                        Menu {
                            ForEach(LayerEffect.catalog, id: \.type) { c in Button(c.name) { add(c.type) } }
                        } label: { Label("Add effect", systemImage: "plus") }.menuStyle(.borderlessButton).fixedSize().font(.caption)
                        if fx.isEmpty { Text("Shadow, glow, stroke, blur and more").font(.caption).foregroundStyle(.secondary) }
                        ForEach(Array(fx.enumerated()), id: \.1.id) { i, e in fxCard(e, index: i, count: fx.count) }
                    }
                }
                .padding(10)
                .disabled(locked)
            }
        }
    }
}

// Picture-in-picture controls for a video clip on V2+ (B-roll over the A-roll).
struct PipControls: View {
    @ObservedObject var editor: Editor
    @ObservedObject var dragState: DragState
    @ObservedObject var live: LiveState
    let id: String
    var clip: Clip? { editor.liveUpperClip(id) }
    var u: Double { Double(editor.project.settings.height) / 100 }
    var t: Double { live.playhead }
    func done() { editor.commitLive() }
    /// one number of a property (value at the playhead); the diamond adds / removes a keyframe there (like Final Cut)
    func krow(_ title: String, _ prop: String, _ index: Int, _ range: ClosedRange<Double>, k: Double, unit: String, digits: Int = 0, showKeys: Bool = true) -> AnyView {
        // the clip can vanish under the panel (another project opened, clip deleted): show nothing instead of stopping
        guard let c = clip else { return AnyView(EmptyView()) }
        let x = c.xf ?? ClipXf(), local = t - c.offset
        let cur = x.value(prop, at: local), keys = x.keys?[prop] ?? []
        let here = keys.contains { abs($0.t - local) < editor.frameLength * 0.5 }
        let val = (index < cur.count ? cur[index] : 0) * k
        func set(_ v: Double) { var n = cur; if index < n.count { n[index] = v / k }; editor.setClipXf([id], prop, n, at: t) }
        func jump(_ fwd: Bool) {
            let ts = keys.map { $0.t + c.offset }
            if let to = fwd ? ts.first(where: { $0 > t + editor.frameLength * 0.5 }) : ts.last(where: { $0 < t - editor.frameLength * 0.5 }) {
                editor.playhead = to; Task { _ = await editor.handle(["cmd": "seek", "time": to]) }
            }
        }
        return AnyView(HStack(spacing: 5) {
            Text(title).font(.caption).frame(width: 62, alignment: .leading)
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, val)) }, set: set), in: range, onEditingChanged: { if !$0 { done() } })
            TextField("", value: Binding(get: { val }, set: { set($0); done() }), format: .number.precision(.fractionLength(digits)))
                .textFieldStyle(.roundedBorder).font(.caption.monospacedDigit()).frame(width: 52)
            Text(unit).font(.caption2).foregroundStyle(.secondary).frame(width: 14, alignment: .leading)
            if showKeys {
                HStack(spacing: 4) {
                    Button { jump(false) } label: { Image(systemName: "chevron.left").font(.system(size: 8)) }
                        .buttonStyle(.borderless).disabled(keys.isEmpty).help("Previous keyframe")
                    Button { editor.toggleClipKey([id], prop, at: t) } label: {
                        Image(systemName: here ? "diamond.fill" : "diamond").font(.system(size: 10))
                            .foregroundStyle(here ? Color.yellow : (keys.isEmpty ? Color.secondary : Color.orange))
                    }.buttonStyle(.borderless)
                    .help(here ? "Remove the keyframe at the playhead. Right-click: easing into it" : "Add a keyframe at the playhead (animate \(title.lowercased()))")
                    .contextMenu {
                        if here, let kf = keys.first(where: { abs($0.t - local) < editor.frameLength * 0.5 }) {
                            let e = kf.e ?? "linear"
                            Text("Easing into this keyframe")
                            ForEach(Ease.presets.filter { !$0.id.hasPrefix("bez:") }, id: \.id) { p in
                                Button { editor.setClipKeyEase([id], prop, at: t, p.id) } label: { Text((e == p.id ? "✓ " : "") + p.name) }
                            }
                        } else { Text("Move the playhead onto a keyframe to set its easing") }
                    }
                    Button { jump(true) } label: { Image(systemName: "chevron.right").font(.system(size: 8)) }
                        .buttonStyle(.borderless).disabled(keys.isEmpty).help("Next keyframe")
                }.frame(width: 50)
            } else { Color.clear.frame(width: 50, height: 1) }
        })
    }
    func go(_ to: Double) { editor.playhead = to; Task { _ = await editor.handle(["cmd": "seek", "time": to]) } }
    /// V1 zoom (scale about the zoom point, picture stays filling the frame) with its own keyframes
    func zoomRow(_ c: Clip) -> some View {
        let z = c.zoom ?? [], local = t - c.offset
        let val = KF.at(z, local, [1])[0] * 100
        let here = z.contains { abs($0.t - local) < editor.frameLength * 0.5 }
        return InspectorSection("Zoom", key: "pip.zoom", open: true, changed: !z.isEmpty,
                                reset: { editor.liveZoom(id) { $0 = [] }; done() }) {
            HStack(spacing: 5) {
                Text("Zoom").font(.caption).frame(width: 62, alignment: .leading)
                Slider(value: Binding(get: { min(300, max(100, val)) }, set: { editor.setClipZoom(id, $0 / 100, at: t) }), in: 100...300,
                       onEditingChanged: { if !$0 { done() } })
                TextField("", value: Binding(get: { val }, set: { editor.setClipZoom(id, $0 / 100, at: t); done() }), format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder).font(.caption.monospacedDigit()).frame(width: 52)
                Text("%").font(.caption2).foregroundStyle(.secondary).frame(width: 14, alignment: .leading)
                HStack(spacing: 4) {
                    Button { if let to = z.map({ $0.t + c.offset }).last(where: { $0 < t - editor.frameLength * 0.5 }) { go(to) } } label: { Image(systemName: "chevron.left").font(.system(size: 8)) }
                        .buttonStyle(.borderless).disabled(z.isEmpty).help("Previous zoom keyframe")
                    Button { editor.toggleZoomKey(id, at: t) } label: {
                        Image(systemName: here ? "diamond.fill" : "diamond").font(.system(size: 10)).foregroundStyle(here ? Color.yellow : (z.isEmpty ? Color.secondary : Color.orange))
                    }.buttonStyle(.borderless).help(here ? "Remove the zoom keyframe at the playhead. Right-click: easing" : "Add a zoom keyframe at the playhead")
                    .contextMenu {
                        if here, let kf = z.first(where: { abs($0.t - local) < editor.frameLength * 0.5 }) {
                            let e = kf.e ?? "linear"
                            Text("Easing into this keyframe")
                            ForEach(Ease.presets.filter { !$0.id.hasPrefix("bez:") }, id: \.id) { p in
                                Button { editor.setZoomEase(id, at: t, p.id) } label: { Text((e == p.id ? "✓ " : "") + p.name) }
                            }
                        } else { Text("Move the playhead onto a keyframe to set its easing") }
                    }
                    Button { if let to = z.map({ $0.t + c.offset }).first(where: { $0 > t + editor.frameLength * 0.5 }) { go(to) } } label: { Image(systemName: "chevron.right").font(.system(size: 8)) }
                        .buttonStyle(.borderless).disabled(z.isEmpty).help("Next zoom keyframe")
                }.frame(width: 50)
            }
        }
    }
    /// V1 slide aside: the camera picture moves over for a side panel (separate from Transform, like zoom)
    func slideRow(_ c: Clip) -> some View {
        let m = c.motion ?? [], local = t - c.offset
        let cur = KF.at(m, local, [0, 0])
        let here = m.contains { abs($0.t - local) < editor.frameLength * 0.5 }
        func row(_ title: String, _ i: Int, _ range: ClosedRange<Double>) -> some View {
            let val = cur[i] * u
            return HStack(spacing: 5) {
                Text(title).font(.caption).frame(width: 62, alignment: .leading)
                Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, val)) }, set: { editor.setClipMotion(id, i, $0 / u, at: t) }), in: range,
                       onEditingChanged: { if !$0 { done() } })
                TextField("", value: Binding(get: { val }, set: { editor.setClipMotion(id, i, $0 / u, at: t); done() }), format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder).font(.caption.monospacedDigit()).frame(width: 52)
                Text("px").font(.caption2).foregroundStyle(.secondary).frame(width: 14, alignment: .leading)
                if i == 0 {
                    HStack(spacing: 4) {
                        Button { if let to = m.map({ $0.t + c.offset }).last(where: { $0 < t - editor.frameLength * 0.5 }) { go(to) } } label: { Image(systemName: "chevron.left").font(.system(size: 8)) }
                            .buttonStyle(.borderless).disabled(m.isEmpty).help("Previous slide keyframe")
                        Button { editor.toggleMotionKey(id, at: t) } label: {
                            Image(systemName: here ? "diamond.fill" : "diamond").font(.system(size: 10)).foregroundStyle(here ? Color.yellow : (m.isEmpty ? Color.secondary : Color.orange))
                        }.buttonStyle(.borderless).help(here ? "Remove the slide keyframe at the playhead" : "Add a slide keyframe at the playhead")
                        Button { if let to = m.map({ $0.t + c.offset }).first(where: { $0 > t + editor.frameLength * 0.5 }) { go(to) } } label: { Image(systemName: "chevron.right").font(.system(size: 8)) }
                            .buttonStyle(.borderless).disabled(m.isEmpty).help("Next slide keyframe")
                    }.frame(width: 50)
                } else { Color.clear.frame(width: 50, height: 1) }
            }
        }
        return InspectorSection("Slide aside", key: "pip.slide", open: true, changed: !m.isEmpty,
                                help: "Moves the camera picture over to make room for a side panel. Kept apart from Transform, like Zoom.",
                                reset: { editor.liveMotion(id) { $0 = [] }; done() }) {
            row("Slide X", 0, -PW...PW)
            row("Slide Y", 1, -PH...PH)
            if m.count > 1 { Text("\(m.count) slide keyframes").font(.caption2).foregroundStyle(.secondary) }
        }
    }
    /// one place for a clip's keyframes: where they are, what is keyframed at the playhead, and how it moves into it
    @ViewBuilder func keyframeSection(_ c: Clip) -> some View {
        let all = TimelineCanvas.clipKeyTimes(c), local = t - c.offset, half = editor.frameLength * 0.5
        if !all.isEmpty {
            let x = c.xf ?? ClipXf()
            var here: [(String, Keyframe, Int)] = []
            let _ = {
                let names = ["position": "Position", "scale": "Scale", "rotation": "Rotation", "opacity": "Opacity", "crop": "Crop", "shadow": "Shadow"]
                for (p, k) in (x.keys ?? [:]).sorted(by: { $0.key < $1.key }) { if let i = k.firstIndex(where: { abs($0.t - local) < half }) { here.append((names[p] ?? p, k[i], i)) } }
                if let z = c.zoom, let i = z.firstIndex(where: { abs($0.t - local) < half }) { here.append(("Zoom", z[i], i)) }
                if let m = c.motion, let i = m.firstIndex(where: { abs($0.t - local) < half }) { here.append(("Slide", m[i], i)) }
            }()
            let idx = all.firstIndex(where: { abs($0 - local) < half })
            let eases = Set(here.filter { $0.2 > 0 }.map { $0.1.e ?? "linear" })
            let ease = eases.count == 1 ? eases.first! : (eases.isEmpty ? "linear" : "mixed")
            InspectorSection("Keyframes", key: "pip.keys", open: true, changed: true) {
                // 1. where: previous / next, and a strip of the clip with every keyframe (click one to go there)
                HStack(spacing: 6) {
                    Button { if let to = all.last(where: { $0 < local - half }) { go(to + c.offset) } } label: { Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 18) }
                        .buttonStyle(.borderless).help("Previous keyframe")
                    GeometryReader { g in
                        let w = g.size.width, d = max(0.001, c.duration)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08)).frame(height: 3)
                            Rectangle().fill(Color.red).frame(width: 1.5, height: 14).offset(x: min(w, max(0, local / d * w)))
                            ForEach(Array(all.enumerated()), id: \.offset) { n, kt in
                                Image(systemName: "diamond.fill").font(.system(size: n == idx ? 10 : 8))
                                    .foregroundStyle(n == idx ? Color.yellow : Color.orange)
                                    .position(x: kt / d * w, y: 7).onTapGesture { go(kt + c.offset) }
                            }
                        }.frame(height: 14)
                    }.frame(height: 14)
                    Button { if let to = all.first(where: { $0 > local + half }) { go(to + c.offset) } } label: { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 18) }
                        .buttonStyle(.borderless).help("Next keyframe")
                    Text(idx.map { "\($0 + 1)/\(all.count)" } ?? "\(all.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                }
                // 2. what is keyframed here (small tags), delete, graph editor
                HStack(spacing: 4) {
                    if here.isEmpty {
                        Text("Playhead between keyframes").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        ForEach(here.map(\.0), id: \.self) { n in
                            Text(n).font(.system(size: 10, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.yellow.opacity(0.18))).foregroundStyle(Color.yellow)
                        }
                    }
                    Spacer(minLength: 4)
                    Button { editor.deleteClipKeys(id, at: local) } label: { Image(systemName: "trash").font(.system(size: 11)).frame(width: 20, height: 18) }
                        .buttonStyle(.borderless).disabled(here.isEmpty).help("Delete the keyframe at the playhead")
                    Button { NotificationCenter.default.post(name: .toggleGraph, object: nil) } label: {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").font(.system(size: 12)).frame(width: 22, height: 18) }
                        .buttonStyle(.borderless).foregroundStyle(Brand.accent).help("Graph editor: shape the curves (⇧⌘G)")
                }
                // 3. easing: one tap, picture of each curve (into this keyframe; ⌥-click = every keyframe on the clip)
                HStack(spacing: 3) {
                    ForEach(Ease.presets.filter { !$0.id.hasPrefix("bez:") }, id: \.id) { p in
                        let on = ease == p.id && here.contains(where: { $0.2 > 0 })
                        Button {
                            editor.setClipEaseAll(id, at: NSEvent.modifierFlags.contains(.option) || !here.contains(where: { $0.2 > 0 }) ? nil : local, p.id)
                        } label: {
                            EaseCurve(e: p.id).frame(width: 26, height: 18).padding(2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(on ? Brand.accent.opacity(0.35) : Color.clear))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(on ? Brand.accent : Color.white.opacity(0.1)))
                        }.buttonStyle(.plain)
                        .help(p.name + (here.contains(where: { $0.2 > 0 }) ? ": ease into this keyframe (⌥-click: every keyframe on the clip)" : ": every keyframe on the clip"))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
    var body: some View {
        if let c = clip {
            let x = c.xf ?? ClipXf()
            let hasKeys = { (ps: [String]) in ps.contains { !(x.keys?[$0] ?? []).isEmpty } }
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Spacer()
                    Menu {
                        Button("Full frame") { editor.liveUpper([id]) { $0 = ClipXf() }; done() }
                        Button("Top right, 35 %") { editor.liveUpper([id]) { x in x = ClipXf(); x.scale = 0.35; x.position = [52, 28] }; done() }
                        Button("Bottom right, 35 %") { editor.liveUpper([id]) { x in x = ClipXf(); x.scale = 0.35; x.position = [52, -28] }; done() }
                        Button("Left half") { editor.liveUpper([id]) { x in x = ClipXf(); x.crop = [0.25, 0.25, 0, 0]; x.position = [-44.4, 0] }; done() }
                        Button("Right half") { editor.liveUpper([id]) { x in x = ClipXf(); x.crop = [0.25, 0.25, 0, 0]; x.position = [44.4, 0] }; done() }
                    } label: { Label("Layout presets", systemImage: "rectangle.3.group").font(.caption) }
                    .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary).help("Quick picture-in-picture layouts")
                }
                InspectorSection("Transform", key: "pip.transform", open: true, changed: !(x.position == nil && x.scale == nil && x.rotation == nil && x.opacity == nil) || hasKeys(["position", "scale", "rotation", "opacity"]),
                                 reset: { editor.liveUpper([id]) { x in x.position = nil; x.scale = nil; x.rotation = nil; x.opacity = nil
                                     for p in ["position", "scale", "rotation", "opacity"] { x.keys?[p] = nil } }; done() }) {
                    krow("Position X", "position", 0, -PW...PW, k: u, unit: "px")
                    krow("Position Y", "position", 1, -PH...PH, k: u, unit: "px")
                    krow("Scale", "scale", 0, 5...400, k: 100, unit: "%")
                    krow("Rotation", "rotation", 0, -180...180, k: 1, unit: "°")
                    krow("Opacity", "opacity", 0, 0...100, k: 100, unit: "%")
                }
                if editor.project.clips.contains(where: { $0.id == id }) { zoomRow(c); slideRow(c) }
                keyframeSection(c)
                InspectorSection("Drop shadow", key: "pip.shadow", open: false, changed: (x.shadow?.first ?? 0) > 0 || hasKeys(["shadow"]),
                                 reset: { editor.liveUpper([id]) { $0.shadow = nil; $0.keys?["shadow"] = nil }; done() }) {
                    krow("Opacity", "shadow", 0, 0...100, k: 100, unit: "%")
                    krow("Softness", "shadow", 1, 0...150, k: 1, unit: "px")
                    krow("Distance", "shadow", 2, 0...150, k: 1, unit: "px")
                }
                InspectorSection("Crop", key: "pip.crop", open: false, changed: (x.crop.map { $0.contains { $0 > 0 } } ?? false) || hasKeys(["crop"]),
                                 reset: { editor.liveUpper([id]) { $0.crop = nil; $0.keys?["crop"] = nil }; done() }) {
                    krow("Left", "crop", 0, 0...45, k: 100, unit: "%")
                    krow("Right", "crop", 1, 0...45, k: 100, unit: "%")
                    krow("Top", "crop", 2, 0...45, k: 100, unit: "%")
                    krow("Bottom", "crop", 3, 0...45, k: 100, unit: "%")
                }
            }
            .padding(10)
            .disabled(editor.lockedTrack(of: id) != nil)
        }
    }
}

// tiny picture of an easing curve
struct EaseCurve: View {
    let e: String
    var body: some View {
        Canvas { ctx, sz in
            var p = Path()
            for i in 0...30 { let u = Double(i) / 30, v = Ease.apply(e, u)
                let pt = CGPoint(x: u * sz.width, y: sz.height - 3 - v * (sz.height - 6)); if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) } }
            ctx.stroke(p, with: .color(.yellow), lineWidth: 1.2)
        }
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.06)))
        .help("Speed of the move between keyframes")
    }
}

// Custom Bezier: drag the two yellow handles (like CSS / After Effects curves)
struct BezierEditor: View {
    let e: String
    let set: (String) -> Void
    let done: () -> Void
    var v: [Double] { let x = e.dropFirst(4).split(separator: ",").compactMap { Double($0) }; return x.count == 4 ? x : [0.25, 0.1, 0.25, 1] }
    var body: some View {
        GeometryReader { g in
            // 0...1 sits in the middle; room above / below for overshoot (-0.3 ... 1.3)
            let w = g.size.width, h = g.size.height, pad = 14.0, vy = (h - 2 * pad) / 1.6
            let toV: (Double, Double) -> CGPoint = { x, y in CGPoint(x: pad + x * (w - 2 * pad), y: h - pad - (y + 0.3) * vy) }
            let p1 = toV(v[0], v[1]), p2 = toV(v[2], v[3]), a = toV(0, 0), b = toV(1, 1)
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.05))
                Path { p in p.addRect(CGRect(x: a.x, y: b.y, width: b.x - a.x, height: a.y - b.y)) }.stroke(Color.white.opacity(0.12), lineWidth: 1)
                Path { p in p.move(to: a); p.addLine(to: p1); p.move(to: b); p.addLine(to: p2) }.stroke(Color.gray, lineWidth: 1)
                Path { p in p.move(to: a); p.addCurve(to: b, control1: p1, control2: p2) }.stroke(Color.yellow, lineWidth: 1.5)
                ForEach(0..<2, id: \.self) { i in
                    Circle().fill(Color.white).frame(width: 10, height: 10).position(i == 0 ? p1 : p2)
                        .gesture(DragGesture(coordinateSpace: .named("bez")).onChanged { d in
                            let x = min(1, max(0, (d.location.x - pad) / (w - 2 * pad))), y = min(1.3, max(-0.3, (h - pad - d.location.y) / vy - 0.3))
                            var n = v; n[i * 2] = (x * 100).rounded() / 100; n[i * 2 + 1] = (y * 100).rounded() / 100
                            set("bez:" + n.map { String($0) }.joined(separator: ","))
                        }.onEnded { _ in done() })
                }
            }.coordinateSpace(name: "bez")
        }
        .frame(height: 150).clipped()
        .help("Drag the two handles to shape the speed curve")
    }
}

/// project frame size for slider ranges (a 4K project gets ±3840 px, not the 1080p numbers)
@MainActor var PW: Double { Double(EditorRef.current?.project.settings.width ?? 1920) }
@MainActor var PH: Double { Double(EditorRef.current?.project.settings.height ?? 1080) }
@MainActor enum EditorRef { static weak var current: Editor? }
