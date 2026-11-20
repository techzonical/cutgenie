import SwiftUI
import AppKit
import CutzonicalCore

// Text section of the Effects tab for a text layer (Final Cut's Text inspector): the words, then the look of each
// styled part ("run"). Typing updates the viewer after a short pause; every finished change is one undo step.
struct TextSection: View {
    @ObservedObject var editor: Editor
    let layer: Overlay
    @State private var run = 0
    @State private var draft: String = ""
    @State private var draftRun = -1
    @State private var pending: DispatchWorkItem?
    @State private var drag: [String: Double] = [:]      // slider value while dragging (one undo step per drag)

    var spec: TextSpec { layer.text ?? TextSpec(runs: [TextRun(text: "")]) }
    var r: TextRun { spec.runs[min(run, spec.runs.count - 1)] }
    static let families: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    func send(_ c: [String: Any]) {
        var m = c; m["cmd"] = "text_edit"; m["id"] = layer.id; m["run"] = min(run, spec.runs.count - 1)
        Task { _ = await editor.handle(m) }
    }
    func rgba(_ c: [Double]?) -> Color { let v = c ?? [1, 1, 1, 1]; return Color(.sRGB, red: v[0], green: v[1], blue: v[2], opacity: v.count > 3 ? v[3] : 1) }
    func comps(_ c: Color) -> String {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
        return String(format: "%.4f,%.4f,%.4f,%.4f", n.redComponent, n.greenComponent, n.blueComponent, n.alphaComponent)
    }
    func typed(_ s: String) {
        draft = s
        pending?.cancel()
        let w = DispatchWorkItem { send(["text": s]) }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }
    func slider(_ title: String, _ v: Double, _ range: ClosedRange<Double>, _ key: String, unit: String = "px") -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).frame(width: 70, alignment: .leading)
            Slider(value: Binding(get: { drag[key] ?? v }, set: { drag[key] = $0 }), in: range,
                   onEditingChanged: { on in if !on, let d = drag[key] { send([key: (d * 10).rounded() / 10]); drag[key] = nil } })
            Text("\(Int((drag[key] ?? v).rounded())) \(unit)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
        }
    }

    var body: some View {
        InspectorSection("Text", key: "fx.text", open: true, changed: false) {
            VStack(alignment: .leading, spacing: 8) {
                if spec.runs.count > 1 {
                    HStack(spacing: 4) {
                        Text("Part").font(.caption).foregroundStyle(.secondary)
                        ForEach(spec.runs.indices, id: \.self) { i in
                            Button("\(i + 1)") { pending?.perform(); run = i; draftRun = -1 }
                                .buttonStyle(.bordered).controlSize(.small).tint(run == i ? Brand.accent : nil)
                        }
                        Spacer()
                        Button { send(["remove_run": run]); run = max(0, run - 1); draftRun = -1 } label: { Image(systemName: "minus") }
                            .buttonStyle(.borderless).help("Remove this part")
                    }
                }
                TextEditor(text: Binding(get: { draftRun == run ? draft : r.text }, set: { draftRun = run; typed($0) }))
                    .font(.system(size: 13)).frame(minHeight: 54, maxHeight: 110)
                    .scrollContentBackground(.hidden).padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                    .onDisappear { pending?.perform() }
                HStack {
                    Button("+ Part with a different style") { send(["add_run": " new"]); run = spec.runs.count; draftRun = -1 }
                        .font(.caption).buttonStyle(.borderless)
                    Spacer()
                    Picker("", selection: Binding(get: { spec.align }, set: { send(["align": $0]) })) {
                        Image(systemName: "text.alignleft").tag("left"); Image(systemName: "text.aligncenter").tag("center"); Image(systemName: "text.alignright").tag("right")
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 96)
                }
                HStack(spacing: 6) {
                    Text("Font").font(.caption).frame(width: 70, alignment: .leading)
                    Menu {
                        ForEach(Self.families, id: \.self) { f in Button(f) { send(["font": f]) } }
                    } label: { Text(r.font).font(.caption).lineLimit(1) }.menuStyle(.borderlessButton)
                    Toggle(isOn: Binding(get: { r.bold == true }, set: { send(["bold": $0]) })) { Image(systemName: "bold") }.toggleStyle(.button).controlSize(.small)
                    Toggle(isOn: Binding(get: { r.italic == true }, set: { send(["italic": $0]) })) { Image(systemName: "italic") }.toggleStyle(.button).controlSize(.small)
                }
                slider("Size", r.size, 8...400, "size")
                HStack(spacing: 6) {
                    Text("Colour").font(.caption).frame(width: 70, alignment: .leading)
                    ColorPicker("", selection: Binding(get: { rgba(r.color) }, set: { send(["color": comps($0)]) }), supportsOpacity: true).labelsHidden()
                    Spacer()
                }
                slider("Letter gap", r.tracking ?? 0, -10...60, "tracking")
                slider("Line gap", spec.lineSpacing ?? 0, -20...80, "line_spacing")
                slider("Wrap width", spec.width ?? 0, 0...1900, "width")
                Divider()
                HStack(spacing: 6) {
                    Toggle("Outline", isOn: Binding(get: { (r.strokeWidth ?? 0) > 0 }, set: { send($0 ? ["stroke_width": 3, "stroke_color": "0,0,0,1"] : ["stroke_width": 0]) }))
                        .font(.caption).toggleStyle(.switch).controlSize(.mini)
                    Spacer()
                    if (r.strokeWidth ?? 0) > 0 {
                        ColorPicker("", selection: Binding(get: { rgba(r.strokeColor) }, set: { send(["stroke_color": comps($0)]) }), supportsOpacity: true).labelsHidden()
                    }
                }
                if (r.strokeWidth ?? 0) > 0 { slider("Width", r.strokeWidth ?? 0, 0.5...20, "stroke_width") }
                HStack(spacing: 6) {
                    Toggle("Shadow", isOn: Binding(get: { r.shadowColor != nil }, set: { send($0 ? ["shadow_color": "0,0,0,0.6", "shadow_distance": 5, "shadow_blur": 8] : ["shadow_color": ""]) }))
                        .font(.caption).toggleStyle(.switch).controlSize(.mini)
                    Spacer()
                    if r.shadowColor != nil {
                        ColorPicker("", selection: Binding(get: { rgba(r.shadowColor) }, set: { send(["shadow_color": comps($0)]) }), supportsOpacity: true).labelsHidden()
                    }
                }
                if r.shadowColor != nil {
                    slider("Distance", r.shadowDistance ?? 0, 0...60, "shadow_distance")
                    slider("Blur", r.shadowBlur ?? 0, 0...60, "shadow_blur")
                    slider("Angle", r.shadowAngle ?? 315, 0...360, "shadow_angle", unit: "°")
                }
            }
        }
    }
}
