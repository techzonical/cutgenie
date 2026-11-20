import SwiftUI
import CutgenieCore

// Inspector for the selected item on the timeline (Final Cut's Inspector): timing, volume, fades, keyframes.
// Values are edited with sliders or typed numbers; each finished change is one undo step.
struct ClipInspector: View {
    @ObservedObject var editor: Editor
    @State private var draft: [String: Double] = [:]      // slider value while dragging

    enum Item { case clip(Clip), audio(AudioClip), layer(Overlay) }
    var item: Item? {
        let id = editor.primarySelection
        guard let id else { return nil }
        if let c = editor.project.clips.first(where: { $0.id == id }) { return .clip(c) }
        if let a = editor.project.audioClips?.first(where: { $0.id == id }) { return .audio(a) }
        if let o = editor.project.overlays?.first(where: { $0.id == id }) { return .layer(o) }
        // a clip on V2+: its linked sound (volume, fades) under the picture-in-picture controls
        if let a = editor.project.audioClips?.first(where: { $0.link == id }) { return .audio(a) }
        return nil
    }
    func run(_ c: [String: Any]) { Task { _ = await editor.handle(c) } }
    func fileName(_ asset: String) -> String { ((editor.project.assets.first { $0.id == asset }?.path ?? asset) as NSString).lastPathComponent }
    func tc(_ t: Double) -> String {
        let fps = 1 / max(editor.frameLength, 0.001), f = Int((t * fps).rounded()), r = Int(fps.rounded())
        return String(format: "%02d:%02d:%02d:%02d", f / r / 3600, f / r / 60 % 60, f / r % 60, f % r)
    }

    /// slider + typed number; `commit` runs once when the drag ends or a number is entered
    func row(_ title: String, key: String, value: Double, range: ClosedRange<Double>, fmt: String, unit: String, commit: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).frame(width: 70, alignment: .leading)
            Slider(value: Binding(get: { draft[key] ?? value }, set: { draft[key] = $0 }), in: range,
                   onEditingChanged: { editing in if !editing, let v = draft[key] { commit(v); draft[key] = nil } })
            TextField("", value: Binding(get: { (draft[key] ?? value) }, set: { commit(min(range.upperBound, max(range.lowerBound, $0))) }),
                      format: .number.precision(.fractionLength(fmt == "%.2f" ? 2 : 1)))
                .textFieldStyle(.roundedBorder).font(.caption.monospacedDigit()).frame(width: 54)
            Text(unit).font(.caption).foregroundStyle(.secondary).frame(width: 18, alignment: .leading)
        }
    }
    func info(_ k: String, _ v: String) -> some View {
        HStack { Text(k).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading); Text(v).font(.caption.monospacedDigit()); Spacer() }
    }
    func header(_ t: String) -> some View { Text(t.uppercased()).font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 6) }

    func soundSection(id: String, gain: Double, keys: [VolKey]?, fadeIn: Double?, fadeOut: Double?, duration: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorSection("Volume", key: "clip.volume", open: true, changed: gain != 0 || !(keys ?? []).isEmpty,
                             reset: { run(["cmd": "set_volume", "id": id, "gain_db": 0]) }) {
            row("Volume", key: "gain", value: gain, range: -60...12, fmt: "%.1f", unit: "dB") { v in run(["cmd": "set_volume", "id": id, "gain_db": (v * 10).rounded() / 10]) }
            HStack {
                if let k = keys, !k.isEmpty {
                    Text("+ \(k.count) keyframe\(k.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    Button("Remove keyframes") { run(["cmd": "set_volume", "id": id, "keys": ""]) }.font(.caption)
                }
            }
            }
            InspectorSection("Fades", key: "clip.fades", open: false, changed: (fadeIn ?? 0) > 0 || (fadeOut ?? 0) > 0,
                             reset: { run(["cmd": "set_fade", "id": id, "in": 0, "out": 0]) }) {
            row("Fade in", key: "fin", value: fadeIn ?? 0, range: 0...max(0.1, min(10, duration)), fmt: "%.2f", unit: "s") { v in run(["cmd": "set_fade", "id": id, "in": v]) }
            row("Fade out", key: "fout", value: fadeOut ?? 0, range: 0...max(0.1, min(10, duration)), fmt: "%.2f", unit: "s") { v in run(["cmd": "set_fade", "id": id, "out": v]) }
            }
            .help("Tip: drag the small squares at a sound clip's top corners on the timeline")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                switch item {
                case .clip(let c):
                    Text(fileName(c.asset)).font(.headline).lineLimit(1)
                    InspectorSection("Clip", key: "clip.info", open: false, changed: false) {
                        info("Start", tc(c.offset)); info("Duration", tc(c.duration)); info("Source in", tc(c.sourceIn))
                    }
                    InspectorSection("Speed", key: "clip.speed", open: true, changed: abs(c.sp - 1) > 0.0001,
                                     reset: { run(["cmd": "set_speed", "clip": c.id, "speed": 1]) }) {
                        SpeedControls(editor: editor, clip: c)
                    }
                    if c.audioDetached == true {
                        header("Sound"); info("Sound", "detached to its own audio clip")
                    } else {
                        soundSection(id: c.id, gain: c.audio.gainDb, keys: c.audio.keys, fadeIn: c.audio.fadeIn, fadeOut: c.audio.fadeOut, duration: c.duration)
                        Button("Unlink audio  (⌘L)") { run(["cmd": "detach_audio", "clip": c.id]) }.font(.caption).padding(.top, 4)
                    }
                case .audio(let a):
                    Text(a.name.isEmpty ? fileName(a.asset) : a.name).font(.headline).lineLimit(1)
                    info("Track", "A\(a.lane)"); info("Start", tc(a.offset)); info("Duration", tc(a.duration))
                    soundSection(id: a.id, gain: a.gainDb, keys: a.keys, fadeIn: a.fadeIn, fadeOut: a.fadeOut, duration: a.duration)
                case .layer(let o):
                    Text(o.name.isEmpty ? fileName(o.asset) : o.name).font(.headline).lineLimit(1)
                    info("Track", o.lane > 0 ? "V\(o.lane + 1)" : "V1 (under)"); info("Start", tc(o.offset))
                    row("Duration", key: "odur", value: o.duration, range: 0.1...max(30, o.duration), fmt: "%.2f", unit: "s") { v in run(["cmd": "overlay_edit", "id": o.id, "duration": v]) }
                    info("Animation", "\(o.position.count + o.scale.count + o.opacity.count) keyframes (from Final Cut)")
                case nil:
                    Text(editor.selection.count > 1 ? "\(editor.selection.count) items selected" : "Select a clip, a sound clip or a layer on the timeline")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 20)
                }
            }
            .padding(10)
        }
        .id(editor.selection.first ?? editor.selectedClip ?? "none")   // fresh drafts per item
    }
}

// Clip speed (retime): presets + slider. The timeline makes room / closes up; the sound keeps its natural pitch.
struct SpeedControls: View {
    @ObservedObject var editor: Editor
    let clip: Clip
    @State private var draft: Double? = nil
    func set(_ s: Double) { Task { _ = await editor.handle(["cmd": "set_speed", "clip": clip.id, "speed": s]) } }
    var body: some View {
        let pct = clip.sp * 100
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach([25, 50, 75, 100, 150, 200, 400], id: \.self) { p in
                    Button("\(p)") { set(Double(p) / 100) }.font(.caption2)
                        .buttonStyle(.bordered).tint(abs(pct - Double(p)) < 0.5 ? Brand.chipOn : nil)
                }
                Text("%").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text("Speed").font(.caption).frame(width: 70, alignment: .leading)
                Slider(value: Binding(get: { log2((draft ?? pct) / 100) }, set: { draft = pow(2, $0) * 100 }), in: -3...3,
                       onEditingChanged: { if !$0, let d = draft { set((d / 5).rounded() * 5 / 100); draft = nil } })
                Text("\(Int((draft ?? pct).rounded())) %").font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
            }
            .help("Slower = longer on the timeline, faster = shorter; clips after it move to make room")
        }
    }
}
