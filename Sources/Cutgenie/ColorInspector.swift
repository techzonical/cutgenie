import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CutgenieCore

// Colour inspector, modelled on Final Cut's Color Wheels + basic controls + LUT slots.
// Every control edits live (the picture updates while you drag) and is ONE undo step per drag.
// No preset values: every control starts at neutral and you set them.

struct ColorInspector: View {
    @ObservedObject var editor: Editor

    var targets: [Int] { editor.gradeTargets }
    var first: ColorParams? { editor.gradePrimary.flatMap { editor.project.gradeClip($0)?.color } }

    func live(_ f: @escaping (inout ColorParams) -> Void) { editor.liveColor(targets, f) }
    func commit() { editor.commitLive() }

    func num(_ title: String, _ range: ClosedRange<Double>, neutral: Double, format: String = "%.2f",
             get: @escaping (ColorParams) -> Double, set: @escaping (inout ColorParams, Double) -> Void) -> some View {
        let b = Binding<Double>(get: { first.map(get) ?? neutral }, set: { v in live { set(&$0, v) } })
        return HStack(spacing: 6) {
            Text(title).frame(width: 78, alignment: .leading).font(.caption)
            Slider(value: b, in: range, onEditingChanged: { if !$0 { commit() } }).controlSize(.small)
            Button(String(format: format, b.wrappedValue)) { live { set(&$0, neutral) }; commit() }
                .buttonStyle(.plain).font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
                .help("Click to reset to neutral")
        }
    }

    func wheelBinding(_ which: String) -> Binding<WheelParams> {
        Binding(get: {
            let w = first?.wheels ?? Wheels()
            switch which { case "global": return w.global; case "shadows": return w.shadows; case "midtones": return w.midtones; default: return w.highlights }
        }, set: { v in
            live { c in
                var w = c.wheels ?? Wheels()
                switch which { case "global": w.global = v; case "shadows": w.shadows = v; case "midtones": w.midtones = v; default: w.highlights = v }
                c.wheels = w
            }
        })
    }

    func wheelBlock(_ title: String, _ key: String) -> some View {
        let b = wheelBinding(key)
        return VStack(spacing: 4) {
            HStack {
                Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { b.wrappedValue = WheelParams(); commit() } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 9)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).opacity(b.wrappedValue == WheelParams() ? 0 : 1).help("Reset this wheel")
            }
            WheelView(value: b, onCommit: commit).frame(width: 104, height: 104)
            HStack(spacing: 4) {
                Text("Sat").font(.caption2).foregroundStyle(.secondary).frame(width: 22)
                Slider(value: Binding(get: { b.wrappedValue.saturation }, set: { var w = b.wrappedValue; w.saturation = $0; b.wrappedValue = w }),
                       in: 0...2, onEditingChanged: { if !$0 { commit() } })
                Text(String(format: "%.2f", b.wrappedValue.saturation)).font(.caption2.monospacedDigit()).frame(width: 34)
            }
            HStack(spacing: 4) {
                Text("Brt").font(.caption2).foregroundStyle(.secondary).frame(width: 22)
                Slider(value: Binding(get: { b.wrappedValue.brightness }, set: { var w = b.wrappedValue; w.brightness = $0; b.wrappedValue = w }),
                       in: -0.5...0.5, onEditingChanged: { if !$0 { commit() } })
                Text(String(format: "%+.2f", b.wrappedValue.brightness)).font(.caption2.monospacedDigit()).frame(width: 34)
            }
        }
    }

    func spacePicker(_ title: String, selection: Binding<String>, includeAuto: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).frame(width: 84, alignment: .leading)
            Picker("", selection: selection) {
                if let a = includeAuto { Text(a).tag("") }
                ForEach(ColorSpaces.all, id: \.id) { Text($0.name).tag($0.id) }
            }.labelsHidden().pickerStyle(.menu)
        }
    }

    var projectSpace: Binding<String> {
        Binding(get: { editor.project.settings.colorSpace },
                set: { v in Task { _ = await editor.handle(["cmd": "set_setting", "key": "colorSpace", "value": v]) } })
    }
    var toneMap: Binding<String> {
        Binding(get: { editor.project.settings.hdrToSdr ?? "soft" },
                set: { v in Task { _ = await editor.handle(["cmd": "set_setting", "key": "hdrToSdr", "value": v]) } })
    }
    var wheelScale: Binding<Double> {
        Binding(get: { editor.project.settings.wheelScale ?? 0.32 },
                set: { v in Task { _ = await editor.handle(["cmd": "set_setting", "key": "wheelScale", "value": String(v)]) } })
    }
    var wheelRange: Binding<Double> {
        Binding(get: { editor.project.settings.wheelRange ?? 0.25 },
                set: { v in Task { _ = await editor.handle(["cmd": "set_setting", "key": "wheelRange", "value": String(v)]) } })
    }
    var sourceSpace: Binding<String> {
        Binding(get: { first?.sourceSpace ?? "" }, set: { v in live { $0.sourceSpace = v.isEmpty ? nil : v }; commit() })
    }
    func lutSpace(_ slot: String, input: Bool) -> Binding<String> {
        Binding(get: {
            let l = first?.luts?.first { $0.slot == slot }
            return (input ? l?.inputSpace : l?.outputSpace) ?? ""
        }, set: { v in
            live { c in c.luts = c.luts?.map { var l = $0; if l.slot == slot { if input { l.inputSpace = v.isEmpty ? nil : v } else { l.outputSpace = v.isEmpty ? nil : v } }; return l } }
            commit()
        })
    }

    func lutRow(_ slot: String, title: String) -> some View {
        let entry = first?.luts?.first { $0.slot == slot }
        let name = entry.flatMap { e in editor.project.assets.first { $0.id == e.asset }?.path }.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.caption).frame(width: 64, alignment: .leading)
                Button { pickLUT(slot) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: name == nil ? "plus" : "cube").font(.system(size: 9))
                        Text(name ?? "Choose LUT…").lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .font(.caption).foregroundStyle(name == nil ? .secondary : .primary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.1)))
                }.buttonStyle(.plain).help(name == nil ? "Load a .cube LUT" : "Change the LUT")
                if let e = entry {
                    Toggle("", isOn: Binding(get: { e.enabled }, set: { v in live { c in c.luts = c.luts?.map { var l = $0; if l.slot == slot { l.enabled = v }; return l } }; commit() }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden().help("Turn this LUT on or off")
                    Menu {
                        Picker("LUT expects", selection: lutSpace(slot, input: true)) {
                            Text("As is").tag(""); ForEach(ColorSpaces.all, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        Picker("LUT produces", selection: lutSpace(slot, input: false)) {
                            Text("Same as it expects").tag(""); ForEach(ColorSpaces.all, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        Divider()
                        Button("Remove LUT", role: .destructive) {
                            Task { _ = await editor.handle(["cmd": "remove_lut", "clip": editor.gradeClipID ?? "", "slot": slot].merging(editor.gradeAllSameMedia ? ["same_media_as": editor.gradeClipID ?? ""] : [:]) { $1 }) }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Colour spaces, remove")
                }
            }
            if let e = entry {
                HStack(spacing: 6) {
                    Text("Amount").font(.caption2).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    Slider(value: Binding(get: { e.intensity }, set: { v in live { c in c.luts = c.luts?.map { var l = $0; if l.slot == slot { l.intensity = v }; return l } } }),
                           in: 0...1, onEditingChanged: { if !$0 { commit() } }).controlSize(.small)
                    Text(String(format: "%.0f%%", e.intensity * 100)).font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                }
                .opacity(e.enabled ? 1 : 0.45)
            }
        }
    }

    func pickLUT(_ slot: String) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        p.message = "Choose a .cube LUT file for the \(slot) slot (a copy is kept in the project's LUTs folder)"
        guard p.runModal() == .OK, let u = p.url else { return }
        let id = editor.gradeClipID ?? ""
        var cmd: [String: Any] = ["cmd": "set_lut", "slot": slot, "path": u.path]
        if editor.gradeAllSameMedia { cmd["same_media_as"] = id } else { cmd["clip"] = id }
        Task { _ = await editor.handle(cmd) }
    }

    /// copy / paste a whole grade, and looks saved for every project
    var looksMenu: some View {
        let _ = editor.looksVersion
        let looks = Editor.savedLooks()
        let n = editor.selection.filter { editor.project.gradeIndex(of: $0) != nil }.count
        return Menu {
            Button("Copy grade") { run(["cmd": "copy_grade"]) }
            Button(n > 1 ? "Paste grade to \(n) selected clips" : "Paste grade") { run(["cmd": "paste_grade"]) }.disabled(editor.gradeClipboard == nil)
            Divider()
            if looks.isEmpty { Text("No saved looks yet") }
            else {
                Section(n > 1 ? "Apply to \(n) selected clips" : "Apply look") {
                    ForEach(looks, id: \.self) { l in Button(l) { run(["cmd": "apply_look", "name": l]) } }
                }
            }
            Divider()
            Button("Save this grade as a look…") {
                if let name = askName("Save look", "Name for this look (sliders, wheels and LUTs):") { run(["cmd": "save_look", "name": name]) }
            }
            if !looks.isEmpty {
                Menu("Delete look") { ForEach(looks, id: \.self) { l in Button(l) { run(["cmd": "delete_look", "name": l]) } } }
            }
        } label: { Label("Looks", systemImage: "swatchpalette") }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Copy this clip's grade to other clips, or save it as a look for any project")
    }
    func run(_ c: [String: Any]) {
        Task { let r = await editor.handle(c); if let e = r["error"] as? String { NSSound.beep(); editor.lastMessage = e } }
    }

    func resetAll() {
        live { c in c = ColorParams(luts: c.luts) }
        commit()
    }

    // what is changed in each section (a dot shows on its header)
    var basicChanged: Bool {
        guard let c = first else { return false }
        return abs(c.exposure) > 0.001 || abs(c.contrast - 1) > 0.001 || abs(c.saturation - 1) > 0.001 || abs(c.temperature - 6500) > 0.5
            || abs(c.tint ?? 0) > 0.01 || abs(c.hue ?? 0) > 0.01
    }
    var wheelsChanged: Bool { first?.wheels.map { $0 != Wheels() } ?? false }
    var inputChanged: Bool { first?.sourceSpace != nil || first?.luts?.contains { $0.slot == "input" } == true }
    var lookChanged: Bool { first?.luts?.contains { $0.slot != "input" } == true }

    /// the clip being graded: file name and track
    var targetCard: some View {
        let sel = editor.gradeClipID ?? ""
        let adj = editor.project.overlays?.first { $0.id == sel && $0.adjust != nil }
        let clip = editor.gradePrimary.flatMap { editor.project.gradeClip($0) }
        let file = clip.flatMap { c in editor.project.assets.first { $0.id == c.asset }?.path }.map { ($0 as NSString).lastPathComponent }
        let track = adj.map { "V\($0.lane + 1)" } ?? editor.project.upperClips?.first(where: { $0.id == sel }).map { "V\(($0.lane ?? 1) + 1)" } ?? "V1"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: adj != nil ? "circle.lefthalf.filled" : "film").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(adj != nil ? "Adjustment layer" : (file ?? sel)).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(adj != nil ? "Grades everything below it on \(track)" : (targets.count > 1 ? "\(track) · and \(targets.count - 1) more from this file" : track))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if adj == nil {
                Toggle("All clips from this file", isOn: $editor.gradeAllSameMedia).toggleStyle(.switch).controlSize(.mini).font(.caption)
                    .help("On: changes go to every clip that uses the same video file")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
    }

    func row<V: View>(_ title: String, @ViewBuilder _ v: () -> V) -> some View {
        HStack(spacing: 6) { Text(title).font(.caption).frame(width: 84, alignment: .leading); v() }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Color").font(.headline)
                    Spacer()
                    looksMenu
                    Button { resetAll() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless).help("Reset basic and wheels to neutral (LUTs stay)")
                }
                if editor.gradeClipID == nil {
                    Text("Select a clip to grade it.").font(.caption).foregroundStyle(.secondary).padding(.top, 20)
                } else {
                    targetCard

                    InspectorSection("Input", key: "input", open: true, changed: inputChanged,
                                     help: "Converts the camera picture first (e.g. HLG → Rec. 709), before any grading",
                                     reset: { live { c in c.sourceSpace = nil; c.luts?.removeAll { $0.slot == "input" } }; commit() }) {
                        lutRow("input", title: "Input LUT")
                        row("Clip colour") {
                            Picker("", selection: sourceSpace) {
                                Text("Auto (from the file)").tag(""); ForEach(ColorSpaces.all, id: \.id) { Text($0.name).tag($0.id) }
                            }.labelsHidden().pickerStyle(.menu)
                        }
                    }

                    InspectorSection("Basic", key: "basic", open: true, changed: basicChanged,
                                     reset: { live { c in c.exposure = 0; c.contrast = 1; c.saturation = 1; c.temperature = 6500; c.tint = nil; c.hue = nil }; commit() }) {
                        num("Exposure", -3...3, neutral: 0, format: "%+.2f", get: { $0.exposure }, set: { $0.exposure = $1 })
                        num("Contrast", 0...2, neutral: 1, get: { $0.contrast }, set: { $0.contrast = $1 })
                        num("Saturation", 0...2, neutral: 1, get: { $0.saturation }, set: { $0.saturation = $1 })
                        Divider().opacity(0.4)
                        num("Temperature", 2000...12000, neutral: 6500, format: "%.0f K", get: { $0.temperature }, set: { $0.temperature = $1 })
                        num("Tint", -150...150, neutral: 0, format: "%+.0f", get: { $0.tint ?? 0 }, set: { $0.tint = $1 })
                        num("Hue", -180...180, neutral: 0, format: "%+.0f°", get: { $0.hue ?? 0 }, set: { $0.hue = $1 })
                    }

                    InspectorSection("Color wheels", key: "wheels", open: true, changed: wheelsChanged,
                                     reset: { live { c in c.wheels = nil }; commit() }) {
                        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                            GridRow { wheelBlock("Global", "global"); wheelBlock("Shadows", "shadows") }
                            GridRow { wheelBlock("Midtones", "midtones"); wheelBlock("Highlights", "highlights") }
                        }
                        num("Mix", 0...1, neutral: 1, format: "%.2f",
                            get: { $0.wheels?.mix ?? 1 }, set: { c, v in var w = c.wheels ?? Wheels(); w.mix = v; c.wheels = w })
                        Toggle("Preserve brightness", isOn: Binding(get: { first?.wheels?.preserveLuma ?? true },
                                                                   set: { v in live { c in var w = c.wheels ?? Wheels(); w.preserveLuma = v; c.wheels = w }; commit() }))
                            .toggleStyle(.switch).controlSize(.mini).font(.caption)
                            .help("Colour changes from the wheels do not make the picture lighter or darker")
                    }

                    InspectorSection("Look LUTs", key: "looks", open: false, changed: lookChanged,
                                     help: "Applied after the grade: a creative look, then a final output conversion",
                                     reset: { live { c in c.luts?.removeAll { $0.slot != "input" } }; commit() }) {
                        lutRow("creative", title: "Creative")
                        lutRow("output", title: "Output")
                    }

                    InspectorSection("Project colour", key: "project", open: false, changed: false,
                                     help: "Settings for the whole project, not this clip") {
                        row("Output") {
                            Picker("", selection: projectSpace) { ForEach(ColorSpaces.all, id: \.id) { Text($0.name).tag($0.id) } }.labelsHidden().pickerStyle(.menu)
                        }
                        row("HDR → SDR") {
                            Picker("", selection: toneMap) { Text("Soft roll-off").tag("soft"); Text("Clip").tag("clip") }.labelsHidden().pickerStyle(.menu)
                        }
                        row("Wheel strength") {
                            Slider(value: wheelScale, in: 0...1.5, step: 0.05).controlSize(.small)
                            Text(String(format: "%.2f", wheelScale.wrappedValue)).font(.caption.monospacedDigit()).frame(width: 36)
                        }.help("Scales how strongly all colour wheels act")
                        row("Wheel reach") {
                            Slider(value: wheelRange, in: 0.25...3, step: 0.05).controlSize(.small)
                            Text(String(format: "%.2f", wheelRange.wrappedValue)).font(.caption.monospacedDigit()).frame(width: 36)
                        }.help("Low: shadows / highlights wheels act across the whole picture. High: only near black / white")
                    }

                    InspectorSection("Viewer", key: "viewer", open: false, changed: false,
                                     help: "Only how this window shows the picture. Renders and exports are not affected") {
                        row("Display curve") {
                            Slider(value: Binding(get: { editor.displayGamma }, set: { editor.displayGamma = $0; editor.refreshFramePublic() }), in: 0.8...1.1, step: 0.01).controlSize(.small)
                            Text(String(format: "%.2f", editor.displayGamma)).font(.caption.monospacedDigit()).frame(width: 36)
                        }.help("0.91 matches how Final Cut's viewer looks")
                        row("Display warmth") {
                            Slider(value: Binding(get: { editor.displayWarmth }, set: { editor.displayWarmth = $0; editor.refreshFramePublic() }), in: -10...10, step: 0.5).controlSize(.small)
                            Text(String(format: "%+.1f", editor.displayWarmth)).font(.caption.monospacedDigit()).frame(width: 36)
                        }
                    }
                }
            }
            .padding(10)
        }
    }
}

/// a section of the inspector: a header you click to fold it, a dot when something in it is changed, and its own reset
struct InspectorSection<Content: View>: View {
    let title: String
    let changed: Bool
    let help: String?
    let reset: (() -> Void)?
    let enabled: Binding<Bool>?
    @ViewBuilder let content: () -> Content
    @AppStorage private var isOpen: Bool
    init(_ title: String, key: String, open: Bool, changed: Bool, help: String? = nil, enabled: Binding<Bool>? = nil, reset: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.changed = changed; self.help = help; self.reset = reset; self.enabled = enabled; self.content = content
        _isOpen = AppStorage(wrappedValue: open, "inspector.section." + key)
    }
    @Environment(\.sectionFilter) private var filter
    @Environment(\.changedOnly) private var changedOnly
    @Environment(\.sectionCommand) private var command
    /// hidden by the panel's search box or "Changed only"
    var hidden: Bool {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty && !title.lowercased().contains(q) && !(SectionIcon.words[title] ?? "").contains(q) { return true }
        return changedOnly && !changed
    }
    var body: some View {
        if !hidden { card.onChange(of: command.tick) { _, _ in withAnimation(.easeInOut(duration: 0.18)) { isOpen = command.open } } }
    }
    /// a search opens the sections it finds
    var shown: Bool { isOpen || !filter.trimmingCharacters(in: .whitespaces).isEmpty }
    var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(shown ? 90 : 0))
                Image(systemName: SectionIcon.symbol(title)).font(.system(size: 11)).foregroundStyle(changed ? Brand.accent : .secondary).frame(width: 16)
                Text(title).font(.system(size: 12, weight: .semibold))
                if changed { Circle().fill(Brand.accent).frame(width: 6, height: 6).help("Changed") }
                Spacer()
                if let r = reset, changed {
                    Button { r() } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 10)) }
                        .buttonStyle(.borderless).help("Reset \(title.lowercased())")
                }
                if let e = enabled {
                    Toggle("", isOn: e).toggleStyle(.switch).controlSize(.mini).labelsHidden().help(e.wrappedValue ? "On: click to bypass" : "Off: click to turn on")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { isOpen.toggle() } }
            .help(help ?? "")
            if shown {
                VStack(alignment: .leading, spacing: 8) { content() }
                    .padding(.horizontal, 10).padding(.bottom, 10)
                    .opacity(enabled?.wrappedValue == false ? 0.5 : 1)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.07)))
    }
}

// A colour wheel: drag the puck. Direction = colour (hue), distance from the centre = amount. Double-click resets.
struct WheelView: View {
    @Binding var value: WheelParams
    var onCommit: () -> Void

    // Puck position from hue/amount; for a direct RGB offset (e.g. imported values) derive an equivalent position.
    func polar() -> (hue: Double, amount: Double) {
        if let o = value.rgb, o.count == 3 {
            let m = (o[0] + o[1] + o[2]) / 3
            let d = o.map { $0 - m }
            let chroma = d.map { abs($0) }.max() ?? 0
            if chroma < 1e-6 { return (0, 0) }
            var h = atan2(3.0.squareRoot() * (o[1] - o[2]), 2 * o[0] - o[1] - o[2]) * 180 / .pi
            if h < 0 { h += 360 }
            return (h, min(1, chroma / 0.25))
        }
        return (value.hue, value.amount)
    }

    var body: some View {
        GeometryReader { g in
            let r = min(g.size.width, g.size.height) / 2
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            let (h, a) = polar()
            let pos = CGPoint(x: c.x + r * a * cos(h * .pi / 180), y: c.y + r * a * sin(h * .pi / 180))
            ZStack {
                Circle().fill(AngularGradient(gradient: Gradient(colors: stride(from: 0.0, through: 360.0, by: 30.0).map { Color(hue: $0 / 360, saturation: 0.85, brightness: 0.9) }), center: .center))
                Circle().fill(RadialGradient(colors: [Color(white: 0.1), Color(white: 0.1).opacity(0)], center: .center, startRadius: 0, endRadius: r))
                Circle().stroke(Color.white.opacity(0.5), lineWidth: 1)
                Path { p in p.move(to: CGPoint(x: c.x - r, y: c.y)); p.addLine(to: CGPoint(x: c.x + r, y: c.y)); p.move(to: CGPoint(x: c.x, y: c.y - r)); p.addLine(to: CGPoint(x: c.x, y: c.y + r)) }
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                Circle().stroke(Color.white, lineWidth: 2).background(Circle().fill(Color.black.opacity(0.35))).frame(width: 14, height: 14).position(pos)
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let dx = v.location.x - c.x, dy = v.location.y - c.y
                    let dist = min(1, (dx * dx + dy * dy).squareRoot() / r)
                    var deg = atan2(dy, dx) * 180 / .pi; if deg < 0 { deg += 360 }
                    var w = value; w.hue = deg; w.amount = dist; w.rgb = nil; value = w
                }
                .onEnded { _ in onCommit() })
            .simultaneousGesture(TapGesture(count: 2).onEnded { var w = value; w.hue = 0; w.amount = 0; w.rgb = nil; value = w; onCommit() })
        }
    }
}

/// a small window asking for a name (looks, presets)
@MainActor func askName(_ title: String, _ message: String) -> String? {
    let a = NSAlert(); a.messageText = title; a.informativeText = message
    let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); a.accessoryView = f
    a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
    a.window.initialFirstResponder = f
    guard a.runModal() == .alertFirstButtonReturn else { return nil }
    let s = f.stringValue.trimmingCharacters(in: .whitespaces)
    return s.isEmpty ? nil : s
}
