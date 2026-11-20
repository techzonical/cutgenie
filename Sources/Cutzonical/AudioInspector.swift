import SwiftUI
import AppKit
import CutzonicalCore

// Premiere-style manual audio panel for the whole timeline's sound. Every effect starts neutral/off; you set the values.
struct AudioInspector: View {
    @ObservedObject var editor: Editor
    var ch: AudioChain { editor.audioChain }

    func live(_ f: @escaping (inout AudioChain) -> Void) { editor.liveAudio(f) }
    func commit() { editor.commitLive() }

    func slider(_ title: String, _ range: ClosedRange<Double>, _ fmt: String, get: @escaping (AudioChain) -> Double, set: @escaping (inout AudioChain, Double) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).frame(width: 74, alignment: .leading)
            Slider(value: Binding(get: { get(ch) }, set: { v in live { set(&$0, v) } }), in: range, onEditingChanged: { if !$0 { commit() } }).controlSize(.small)
            Text(String(format: fmt, get(ch))).font(.caption.monospacedDigit()).frame(width: 62, alignment: .trailing)
        }
    }
    func toggle(_ title: String, get: @escaping (AudioChain) -> Bool, set: @escaping (inout AudioChain, Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { get(ch) }, set: { v in live { set(&$0, v) }; commit() })).font(.caption.bold())
    }

    // Interactive EQ graph: each band is a dot. Drag left/right = frequency, up/down = gain (bell/shelves).
    // Double-click empty space to add a bell band there. One undo step per drag.
    var eqGraph: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let fx: (Double) -> Double = { f in log10(f / 20) / 3 * w }
            let fy: (Double) -> Double = { db in h / 2 - db / 24 * (h / 2) }
            let bands = ch.eq
            ZStack {
                Canvas { ctx, _ in
                    var grid = Path()
                    for f in [100.0, 1000, 10000] { grid.move(to: CGPoint(x: fx(f), y: 0)); grid.addLine(to: CGPoint(x: fx(f), y: h)) }
                    for db in [-12.0, 0, 12] { grid.move(to: CGPoint(x: 0, y: fy(db))); grid.addLine(to: CGPoint(x: w, y: fy(db))) }
                    ctx.stroke(grid, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
                    var p = Path()
                    let act = ch.eqEnabled ? bands : []
                    for i in 0...240 {
                        let f = 20 * pow(1000, Double(i) / 240)
                        let pt = CGPoint(x: fx(f), y: fy(max(-24, min(24, DSP.responseDb(act, f: f)))))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                    ctx.stroke(p, with: .color(Color(white: 0.85)), lineWidth: 2)
                }
                ForEach(bands.indices, id: \.self) { i in
                    let b = bands[i]
                    let hasGain = ["bell", "lowshelf", "highshelf"].contains(b.type)
                    ZStack {
                        Circle().fill(b.enabled ? Color(white: 0.85) : Color.gray).frame(width: 16, height: 16)
                        Text("\(i + 1)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    }
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())          // only the dot itself can be grabbed
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("eqgraph"))
                        .onChanged { v in
                            let f = 20 * pow(1000, min(max(v.location.x / w, 0), 1))
                            let db = min(max((h / 2 - v.location.y) / (h / 2) * 24, -24), 24)
                            live { c in
                                guard c.eq.indices.contains(i) else { return }
                                c.eq[i].freq = f
                                if hasGain { c.eq[i].gainDb = (db * 10).rounded() / 10 }
                            }
                        }
                        .onEnded { _ in commit() })
                    .position(x: fx(b.freq), y: fy(hasGain ? b.gainDb : 0))
                    .help("Band \(i + 1): drag left/right for frequency" + (hasGain ? ", up/down for gain" : ""))
                }
            }
            .coordinateSpace(name: "eqgraph")
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { pt in
                guard ch.eq.count < 10 else { return }
                let f = 20 * pow(1000, min(max(pt.x / w, 0), 1))
                let db = min(max((h / 2 - pt.y) / (h / 2) * 24, -24), 24)
                Task { _ = await editor.handle(["cmd": "set_eq", "band": ch.eq.count, "type": "bell", "freq": f, "gain": (db * 10).rounded() / 10, "q": 1]) }
            }
        }
        .frame(height: 140).background(Color.black.opacity(0.15)).clipShape(RoundedRectangle(cornerRadius: 6))
        .help("Drag a dot: left / right = frequency, up / down = gain. Double-click to add a band.")
    }

    @State private var band = 0
    /// the band chips (1 2 3 … +) and the controls of the chosen band
    var bandEditor: some View {
        let i = min(band, max(0, ch.eq.count - 1))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(ch.eq.indices, id: \.self) { k in
                    Button { band = k } label: {
                        Text("\(k + 1)").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 20)
                            .background(RoundedRectangle(cornerRadius: 5).fill(k == i ? Brand.chipOn : Color.white.opacity(0.07)))
                            .foregroundStyle(ch.eq[k].enabled ? Color.primary : Color.secondary)
                    }.buttonStyle(.plain).help("Band \(k + 1)")
                }
                Button { Task { _ = await editor.handle(["cmd": "set_eq", "band": ch.eq.count, "type": "bell", "freq": 1000, "gain": 0, "q": 1]); band = ch.eq.count - 1 } } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.15)))
                }.buttonStyle(.plain).disabled(ch.eq.count >= 10).help("Add a band")
                Spacer()
            }
            if ch.eq.indices.contains(i) { bandRow(i) }
        }
    }

    func bandRow(_ i: Int) -> some View {
        let b = ch.eq[i]
        func set(_ f: @escaping (inout EQBand) -> Void) { live { c in if c.eq.indices.contains(i) { f(&c.eq[i]) } } }
        func line<V: View>(_ t: String, @ViewBuilder _ v: () -> V) -> some View { HStack(spacing: 6) { Text(t).font(.caption).frame(width: 74, alignment: .leading); v() } }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Shape").font(.caption).frame(width: 74, alignment: .leading)
                Picker("", selection: Binding(get: { b.type }, set: { v in set { $0.type = v }; commit() })) {
                    Text("Bell").tag("bell"); Text("Low shelf").tag("lowshelf"); Text("High shelf").tag("highshelf")
                    Text("High-pass").tag("highpass"); Text("Low-pass").tag("lowpass"); Text("Notch").tag("notch")
                }.labelsHidden().pickerStyle(.menu)
                Toggle("", isOn: Binding(get: { b.enabled }, set: { v in set { $0.enabled = v }; commit() })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .help("Turn this band on or off")
                Menu {
                    Button("Remove band \(i + 1)", role: .destructive) { Task { _ = await editor.handle(["cmd": "remove_eq", "band": i]); band = max(0, i - 1) } }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            line("Frequency") {
                Slider(value: Binding(get: { log10(b.freq / 20) / 3 }, set: { t in set { $0.freq = 20 * pow(1000, t) } }), in: 0...1, onEditingChanged: { if !$0 { commit() } }).controlSize(.small)
                Text(b.freq >= 1000 ? String(format: "%.2f kHz", b.freq / 1000) : String(format: "%.0f Hz", b.freq)).font(.caption.monospacedDigit()).frame(width: 62, alignment: .trailing)
            }
            if ["bell", "lowshelf", "highshelf"].contains(b.type) {
                line("Gain") {
                    Slider(value: Binding(get: { b.gainDb }, set: { v in set { $0.gainDb = v } }), in: -24...24, onEditingChanged: { if !$0 { commit() } }).controlSize(.small)
                    Text(String(format: "%+.1f dB", b.gainDb)).font(.caption.monospacedDigit()).frame(width: 62, alignment: .trailing)
                }
            }
            line("Width (Q)") {
                Slider(value: Binding(get: { log10(b.q / 0.1) / log10(180) }, set: { t in set { $0.q = 0.1 * pow(180, t) } }), in: 0...1, onEditingChanged: { if !$0 { commit() } }).controlSize(.small)
                Text(String(format: "%.2f", b.q)).font(.caption.monospacedDigit()).frame(width: 62, alignment: .trailing)
            }
        }
        .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
        .opacity(b.enabled ? 1 : 0.55)
    }

    @State private var target = -14.0
    func stat(_ t: String, _ v: Double, _ u: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(t).font(.system(size: 8)).foregroundStyle(.secondary)
            Text(v <= -89 ? "–" : String(format: "%.1f %@", v, u)).font(.caption.monospacedDigit())
        }
    }
    @State private var busy = false

    /// effect chains saved for every project
    var presetsMenu: some View {
        let _ = editor.looksVersion
        let ps = Editor.savedAudioPresets()
        let tracks = ["A1"] + (0..<max(0, editor.project.audioLanes ?? 0)).map { "A\($0 + 2)" }
        return Menu {
            if ps.isEmpty { Text("No saved presets yet") }
            else {
                Section("Apply to \(editor.audioTrack)") {
                    ForEach(ps, id: \.self) { p in Button(p) { run(["cmd": "apply_audio_preset", "name": p]) } }
                }
                if tracks.count > 1 {
                    Menu("Apply to all tracks") { ForEach(ps, id: \.self) { p in Button(p) { run(["cmd": "apply_audio_preset", "name": p, "tracks": tracks.joined(separator: ",")]) } } }
                }
            }
            Divider()
            Button("Save \(editor.audioTrack) effects as a preset…") {
                if let n = askName("Save preset", "Name for these effects (EQ, gate, compressor, output gain, limiter):") { run(["cmd": "save_audio_preset", "name": n]) }
            }
            if !ps.isEmpty { Menu("Delete preset") { ForEach(ps, id: \.self) { p in Button(p) { run(["cmd": "delete_audio_preset", "name": p]) } } } }
        } label: { Label("Presets", systemImage: "slider.horizontal.3") }
        .menuStyle(.borderlessButton).fixedSize()
    }
    func run(_ c: [String: Any]) {
        Task { let r = await editor.handle(c); if let e = r["error"] as? String { NSSound.beep(); editor.lastMessage = e } }
    }

    func on(_ get: @escaping (AudioChain) -> Bool, _ set: @escaping (inout AudioChain, Bool) -> Void) -> Binding<Bool> {
        Binding(get: { get(ch) }, set: { v in live { set(&$0, v) }; commit() })
    }
    func resetPart(_ f: @escaping (inout AudioChain) -> Void) { live(f); commit() }
    var tracks: [String] { ["A1"] + (0..<max(0, editor.project.audioLanes ?? 0)).map { "A\($0 + 2)" } }

    var body: some View {
        let n = AudioChain()
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Audio").font(.headline)
                    Spacer()
                    presetsMenu
                }
                // which track these effects are on
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform").foregroundStyle(.secondary)
                        Picker("", selection: $editor.audioTrack) {
                            ForEach(tracks, id: \.self) { t in Text(t == "A1" ? "A1 · main sound" : "\(t) · whole track").tag(t) }
                        }.labelsHidden().pickerStyle(.menu).fixedSize()
                        Spacer()
                    }
                    Text(editor.audioTrack == "A1" ? "The camera / V1 sound" : "Every clip on \(editor.audioTrack), including clips you add later")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                .help("Effects run in this order: Gate → EQ → Compressor → Output gain → Limiter")

                InspectorSection("Gate", key: "a.gate", open: false, changed: ch.gate != n.gate,
                                 help: "Turns the sound down when it is quieter than the threshold (room noise between words)",
                                 enabled: on({ $0.gate.enabled }, { $0.gate.enabled = $1 }), reset: { resetPart { $0.gate = GateParams() } }) {
                    slider("Threshold", -100...0, "%.1f dB", get: { $0.gate.thresholdDb }, set: { $0.gate.thresholdDb = $1 })
                    slider("Range", -100...0, "%.1f dB", get: { $0.gate.rangeDb }, set: { $0.gate.rangeDb = $1 })
                    slider("Attack", 0.1...100, "%.1f ms", get: { $0.gate.attackMs }, set: { $0.gate.attackMs = $1 })
                    slider("Release", 1...2000, "%.0f ms", get: { $0.gate.releaseMs }, set: { $0.gate.releaseMs = $1 })
                }

                InspectorSection("EQ", key: "a.eq", open: true, changed: ch.eq != n.eq,
                                 enabled: on({ $0.eqEnabled }, { $0.eqEnabled = $1 }), reset: { resetPart { $0.eq = AudioChain.neutralBands } }) {
                    eqGraph
                    bandEditor
                }

                InspectorSection("Compressor", key: "a.comp", open: false, changed: ch.compressor != n.compressor,
                                 help: "Evens out loud and quiet words",
                                 enabled: on({ $0.compressor.enabled }, { $0.compressor.enabled = $1 }), reset: { resetPart { $0.compressor = CompressorParams() } }) {
                    slider("Threshold", -60...0, "%.1f dB", get: { $0.compressor.thresholdDb }, set: { $0.compressor.thresholdDb = $1 })
                    slider("Ratio", 1...20, "%.1f:1", get: { $0.compressor.ratio }, set: { $0.compressor.ratio = $1 })
                    Divider().opacity(0.4)
                    slider("Attack", 0.1...200, "%.1f ms", get: { $0.compressor.attackMs }, set: { $0.compressor.attackMs = $1 })
                    slider("Release", 1...2000, "%.0f ms", get: { $0.compressor.releaseMs }, set: { $0.compressor.releaseMs = $1 })
                    slider("Knee", 0...24, "%.1f dB", get: { $0.compressor.kneeDb }, set: { $0.compressor.kneeDb = $1 })
                    slider("Make-up", -24...24, "%+.1f dB", get: { $0.compressor.makeupDb }, set: { $0.compressor.makeupDb = $1 })
                }

                InspectorSection("Output", key: "a.out", open: true, changed: abs(ch.outputGainDb) > 0.01 || ch.limiter != n.limiter,
                                 reset: { resetPart { $0.outputGainDb = 0; $0.limiter = LimiterParams() } }) {
                    slider("Gain", -40...40, "%+.1f dB", get: { $0.outputGainDb }, set: { $0.outputGainDb = $1 })
                    HStack(spacing: 6) {
                        Text("Limiter").font(.caption).frame(width: 74, alignment: .leading)
                        Toggle("", isOn: on({ $0.limiter.enabled }, { $0.limiter.enabled = $1 })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        Text("keeps peaks under the ceiling").font(.caption2).foregroundStyle(.secondary)
                    }
                    if ch.limiter.enabled {
                        slider("Ceiling", -24...0, "%.1f dBFS", get: { $0.limiter.ceilingDb }, set: { $0.limiter.ceilingDb = $1 })
                        slider("Release", 1...1000, "%.0f ms", get: { $0.limiter.releaseMs }, set: { $0.limiter.releaseMs = $1 })
                        slider("Look-ahead", 0...20, "%.1f ms", get: { $0.limiter.lookaheadMs }, set: { $0.limiter.lookaheadMs = $1 })
                    }
                }

                InspectorSection("Loudness", key: "a.loud", open: false, changed: false,
                                 help: "Measures the whole timeline (ITU-R BS.1770). Match sets A1's output gain to reach the target") {
                    HStack(spacing: 14) {
                        stat("Integrated", editor.lastLoudness?.lufs ?? -90, "LUFS")
                        stat("Peak", editor.lastLoudness?.peakDb ?? -90, "dBFS")
                        Spacer()
                        Button(busy ? "Measuring…" : "Measure") { busy = true; Task { _ = await editor.handle(["cmd": "analyze_audio"]); busy = false } }.disabled(busy)
                    }
                    HStack(spacing: 6) {
                        Text("Target").font(.caption).frame(width: 74, alignment: .leading)
                        TextField("", value: $target, format: .number).frame(width: 50).textFieldStyle(.roundedBorder)
                        Text("LUFS").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Match") { busy = true; Task { _ = await editor.handle(["cmd": "match_loudness", "target": target]); busy = false } }.disabled(busy)
                            .help("Sets A1's output gain so the whole timeline measures the target. Turn the limiter on first. YouTube: about -14")
                    }
                }
            }.padding(10)
        }
    }
}

// Premiere-style level meter at the right edge of the timeline: green → orange → red, peak hold line, OVER light
struct TimelineMeter: View {
    @ObservedObject var live: MeterState
    let reset: () -> Void
    var body: some View {
        let lo = -48.0
        func y(_ db: Double, _ h: Double) -> Double { h * max(0, min(1, (db - lo) / -lo)) }
        return VStack(spacing: 4) {
            Button { reset() } label: {
                Text("OVER").font(.system(size: 8, weight: .bold)).frame(maxWidth: .infinity).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(live.overload ? Color(red: 0.68, green: 0.30, blue: 0.28) : Color.white.opacity(0.08)))
                    .foregroundStyle(live.overload ? .white : .secondary)
            }.buttonStyle(.plain).help("Lights when the sound clipped. Click to clear")
            GeometryReader { g in
                let h = g.size.height, bw = 10.0
                HStack(alignment: .bottom, spacing: 3) {
                    ZStack(alignment: .bottom) {
                        Rectangle().fill(Color.black.opacity(0.4))
                        LinearGradient(colors: [Color(red: 0.30, green: 0.55, blue: 0.36), Color(red: 0.30, green: 0.55, blue: 0.36), Color(red: 0.66, green: 0.62, blue: 0.32),
                                                Color(red: 0.70, green: 0.48, blue: 0.28), Color(red: 0.68, green: 0.30, blue: 0.28)], startPoint: .bottom, endPoint: .top)
                            .opacity(0.85)
                            .mask(alignment: .bottom) { Rectangle().frame(height: y(live.rmsDb, h)) }
                        Rectangle().fill(Color.white.opacity(0.3)).frame(height: 1).offset(y: -y(live.meterDb, h))
                        Rectangle().fill(Color.white.opacity(0.6)).frame(height: 2).offset(y: -max(0, y(live.peakHoldDb, h) - 1))
                    }.frame(width: bw).clipShape(RoundedRectangle(cornerRadius: 2))
                    ZStack(alignment: .bottomLeading) {
                        ForEach([0.0, -6, -12, -18, -24, -36, -48], id: \.self) { d in
                            Text(d == 0 ? "0" : "\(Int(d))").font(.system(size: 8).monospacedDigit()).foregroundStyle(.secondary)
                                .offset(y: -min(max(y(d, h) - 5, 0), h - 10))
                        }
                    }.frame(width: 16, alignment: .leading)
                }.frame(maxHeight: .infinity, alignment: .bottom)
            }
            Text(live.momentaryLUFS <= -89 ? "–" : String(format: "%.0f", live.momentaryLUFS)).font(.system(size: 9, weight: .semibold).monospacedDigit())
                .help("Loudness right now (momentary LUFS). YouTube aims for about -14 over the whole video")
            Text("LUFS").font(.system(size: 7)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .frame(width: 42)
        .background(Color(white: 0.11))
    }
}

