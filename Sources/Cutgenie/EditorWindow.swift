import SwiftUI
import AppKit
import CutgenieCore

// Editor window: dark, resizable panels (viewer | inspector on top, timeline below), icon toolbar.
struct ContentView: View {
    @ObservedObject var editor: Editor
    var time: Double { editor.playhead }
    var frame: Double { editor.frameLength }

    func run(_ cmd: [String: Any], needsClip: Bool = false) {
        if needsClip && editor.selectedClip == nil && editor.selectedOverlay == nil { editor.lastMessage = "Select a clip or graphic on the timeline first"; return }
        Task { _ = await editor.handle(cmd) }
    }
    func seek(_ t: Double) {
        let c = max(0, min(editor.project.totalDuration, t)); editor.playhead = c; run(["cmd": "seek", "time": c])
        editor.revealPlayhead(c)       // keyboard moves past the visible part: the timeline turns the page (Final Cut)
    }
    func jump(forward: Bool) {
        // every start / end / cut on every track (V1, V2+, graphics, sound), like Final Cut / Premiere ↑ ↓
        let p = editor.project
        let spans = p.clips.map { ($0.offset, $0.duration) } + (p.upperClips ?? []).map { ($0.offset, $0.duration) }
            + (p.overlays ?? []).map { ($0.offset, $0.duration) } + (p.audioClips ?? []).map { ($0.offset, $0.duration) }
        let pts = Set(spans.flatMap { [$0.0, $0.0 + $0.1] }.map { ($0 / frame).rounded() * frame } + [0]).sorted()
        let target = forward ? pts.first { $0 > time + frame * 0.5 } : pts.last { $0 < time - frame * 0.5 }
        if let target { seek(target) }
    }
    func deleteSelected(ripple: Bool) {
        // one path for everything selected (clips, layers, sound clips): pieces cut through all tracks go together
        if !editor.selection.isEmpty { run(["cmd": "delete_selected", "ripple": ripple && editor.magnetic]); return }
        if let o = editor.selectedOverlay { run(["cmd": "overlay_delete", "id": o]); return }
        run(["cmd": ripple ? "ripple_delete" : "delete", "clip": editor.selectedClip ?? ""], needsClip: true)
    }

    // toolbar button; keys are handled centrally (KeyHandler), so no keyboardShortcut here
    func icon(_ symbol: String, _ tip: String, _ k: KeyEquivalent? = nil, _ m: EventModifiers = [], action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 26, height: 22).contentShape(Rectangle()) }
            .buttonStyle(.borderless)
            .help(tip)                      // macOS tooltip at the pointer; no hover state that could swallow clicks
    }

    var timecode: String {
        let fps = 1 / max(frame, 0.001)
        let f = Int((time * fps).rounded()); let r = Int(fps.rounded())
        return String(format: "%02d:%02d:%02d:%02d", f / r / 3600, f / r / 60 % 60, f / r % 60, f % r)
    }

    @State private var showSettings = false
    @State private var showExport = false
    @State private var showKeys = false
    @State private var focus = ""        // "timeline" or "viewer": that area takes the whole window
    @State private var showNewProject = false
    @AppStorage("mediaShown") var showMedia = true
    func toggle(_ symbol: String, _ on: Bool, _ tip: String, _ k: KeyEquivalent, _ m: EventModifiers = [], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).frame(width: 26, height: 22)
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .background(on ? Brand.chipOn.opacity(0.45) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.borderless)
        .help(tip + (on ? ": on" : ": off"))
    }
    func speedLabel(_ s: Double) -> String { (s == s.rounded() ? String(Int(s)) : String(format: "%g", s)) + "×" }
    func shuttle(_ dir: Int) {   // Final Cut J / K / L
        let r = Double(editor.player.rate)
        let n: Double = dir == 0 ? 0 : dir > 0 ? (r <= 0 ? 1 : min(r * 2, 8)) : (r >= 0 ? -1 : max(r * 2, -8))
        run(["cmd": "shuttle", "rate": n])
    }
    func selectUnderPlayhead() {
        if let c = editor.project.clips.first(where: { time >= $0.offset && time < $0.offset + $0.duration }) { editor.selectedClip = c.id; editor.selectedOverlay = nil; editor.selection = [c.id] }
    }
    func hidden(_ k: KeyEquivalent, _ m: EventModifiers = [], _ action: @escaping () -> Void) -> some View {
        Button("", action: action).keyboardShortcut(k, modifiers: m).frame(width: 0, height: 0).opacity(0)
    }

    static let speeds: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3, 4]
    func stepSpeed(_ d: Int) {
        let l = Self.speeds, i = l.firstIndex(where: { $0 >= editor.playSpeed - 0.001 }) ?? 3
        run(["cmd": "play_speed", "speed": l[max(0, min(l.count - 1, i + d))]])
    }
    /// under the viewer: playback only (clean)
    var toolbar: some View {
        HStack(spacing: 2) {
            TimecodeLabel(live: editor.live, frame: frame, total: editor.project.totalDuration).fixedSize().padding(.leading, 6).layoutPriority(1)
            Spacer()
            icon("backward.end.fill", "Start (Home)", .home) { seek(0) }
            icon("arrow.left.to.line", "Previous edit (↑)", .upArrow) { jump(forward: false) }
            icon("backward.frame.fill", "Back 1 frame (←)", .leftArrow) { seek(time - frame) }
            icon("minus", "Play slower") { stepSpeed(-1) }.disabled(editor.playSpeed <= Self.speeds.first!)
            icon(editor.player.rate == 0 ? "play.fill" : "pause.fill", "Play / Pause (Space)", .space) { run(["cmd": editor.player.rate == 0 ? "play" : "pause"]) }
            icon("plus", "Play faster") { stepSpeed(1) }.disabled(editor.playSpeed >= Self.speeds.last!)
            icon("forward.frame.fill", "Forward 1 frame (→)", .rightArrow) { seek(time + frame) }
            icon("arrow.right.to.line", "Next edit (↓)", .downArrow) { jump(forward: true) }
            icon("forward.end.fill", "End (End)", .end) { seek(editor.project.totalDuration) }
            Menu {
                ForEach(Self.speeds, id: \.self) { sp in
                    Button((editor.playSpeed == sp ? "✓ " : "   ") + speedLabel(sp)) { run(["cmd": "play_speed", "speed": sp]) }
                }
            } label: { Text(speedLabel(editor.playSpeed)).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(editor.playSpeed == 1 ? Color.secondary : Color.orange) }
                .menuStyle(.borderlessButton).fixedSize().help("Playback speed (viewer only)").padding(.leading, 6)
            Menu {
                ForEach([(1.0, "Full"), (0.5, "Half"), (0.25, "Quarter")], id: \.0) { v, n in
                    Button((abs(editor.playbackScale - v) < 0.01 ? "✓ " : "   ") + n) { editor.playbackScale = v }
                }
            } label: { Text(editor.playbackScale >= 0.99 ? "Full" : editor.playbackScale >= 0.49 ? "½" : "¼").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.secondary) }
                .menuStyle(.borderlessButton).fixedSize().help("Playback resolution: lower is lighter on the computer. Exports are always full quality.")
            Button { FullscreenPlayer.toggle(editor) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 12, weight: .semibold)) }
                .buttonStyle(.borderless).foregroundStyle(Color.secondary).help("Play full screen (⇧⌘F)")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color(white: 0.13))
    }

    /// editing tools: on the left of the timeline's own bar
    var editTools: some View {
        VStack(spacing: 2) {
            toggle("cursorarrow", editor.tool == "select", "Select (A)", "a") { editor.tool = "select" }
            toggle("scissors", editor.tool == "blade", "Blade (B)", "b") { editor.tool = "blade" }
            toggle("arrow.left.and.right.square", editor.tool == "trim", "Trim (T)", "t") { editor.tool = "trim" }
            toggle("pencil.tip", editor.tool == "pen", "Pen: volume keyframes (P)", "p") { editor.tool = "pen" }
            toggle("plus.magnifyingglass", editor.tool == "zoom", "Zoom (Z)", "z") { editor.tool = "zoom" }
            toggle("hand.raised", editor.tool == "hand", "Hand: drag to move around the timeline (H)", "h") { editor.tool = "hand" }
            Divider().frame(width: 20).padding(.vertical, 3)
            toggle("rectangle.split.3x1.fill", editor.magnetic, "Magnetic timeline (⌥P)", "p") { editor.magnetic.toggle() }
            toggle("arrow.right.and.line.vertical.and.arrow.left", editor.snapping, "Snapping (N)", "n") { editor.snapping.toggle() }
            toggle("waveform.path", editor.skimming, "Skimming (S)", "s") { editor.skimming.toggle(); if !editor.skimming { editor.skim(to: nil) } }
            Divider().frame(width: 20).padding(.vertical, 3)
            icon("scissors.circle", "Cut at playhead (⌘B)", "b", .command) { run(["cmd": "blade_selected", "at": time]) }
            icon("arrow.right.to.line.compact", "Trim start to playhead (⌥[)", "[", .option) { run(["cmd": "trim", "clip": editor.selectedClip ?? "", "edge": "start", "to": time], needsClip: true) }
            icon("arrow.left.to.line.compact", "Trim end to playhead (⌥])", "]", .option) { run(["cmd": "trim", "clip": editor.selectedClip ?? "", "edge": "end", "to": time], needsClip: true) }
            icon("delete.backward", "Delete (⌫)", .delete) { deleteSelected(ripple: true) }
            icon("rectangle.dashed", "Delete, leave gap (⇧⌫)", .delete, .shift) {
                if editor.selection.count > 1 { run(["cmd": "delete_selected", "ripple": false]); return }
                if let o = editor.selectedOverlay { run(["cmd": "overlay_delete", "id": o]) }
                else { run(["cmd": "delete", "clip": editor.selectedClip ?? "", "magnetic": false], needsClip: true) }
            }
            Divider().frame(width: 20).padding(.vertical, 3)
            icon("arrow.uturn.backward", "Undo (⌘Z)") { run(["cmd": "undo"]) }.disabled(!editor.canUndo)
            icon("arrow.uturn.forward", "Redo (⇧⌘Z)") { run(["cmd": "redo"]) }.disabled(!editor.canRedo)
        }
    }


    var viewer: some View {
        VStack(spacing: 0) {
            HStack {
                Button { showMedia.toggle() } label: { Image(systemName: "sidebar.left") }.buttonStyle(.borderless)
                    .foregroundStyle(showMedia ? Color.primary : Color.secondary).help("Show or hide the media panel (⌘1)")
                LogoMark(size: 18).padding(.leading, 2)
                // narrow window: the app name and "Saved … ago" give way first; nothing wraps onto several lines
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text("Cutgenie").font(.system(size: 12, weight: .bold, design: .rounded)).fixedSize()
                        ProjectMenu(editor: editor)
                        SaveStatus(editor: editor).fixedSize()
                    }
                    HStack(spacing: 8) { ProjectMenu(editor: editor); SaveStatus(editor: editor).fixedSize() }
                    ProjectMenu(editor: editor)
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                ExportPill(editor: editor)
                GuidesMenu()
                ViewerZoomMenu()
                Button { showSettings = true } label: {
                    Text(formatLabel(editor.project.settings)).font(.system(size: 10, weight: .medium).monospacedDigit()).lineLimit(1).fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Color(white: 0.18)).clipShape(RoundedRectangle(cornerRadius: 4))
                }.buttonStyle(.plain).help("Project settings (⌘J)")
                Button { openPanel(editor) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Open project (⌘O)")
                Button { showExport = true } label: { Image(systemName: "square.and.arrow.up") }.buttonStyle(.borderless).help("Export (⌘E)")
            }.padding(.horizontal, 10).padding(.vertical, 5)
            ZoomableViewer(pixelSize: CGSize(width: max(1, editor.project.settings.width), height: max(1, editor.project.settings.height))) {
                PlayerSurface(editor: editor)
                    .overlay { TransformHandles(editor: editor, live: editor.live, dragState: editor.drag) }
                    .overlay { SourceMonitor() }
                    .overlay { FrameOutline() }
            }
                .background(GeometryReader { g in Color.clear.onAppear { MediaState.shared.viewerRect = g.frame(in: .global) }.onChange(of: g.frame(in: .global)) { _, r in MediaState.shared.viewerRect = r } })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ViewerSurround())
            toolbar
        }
        .background(Color(white: 0.09))
    }

    var inspector: some View {
        VStack(spacing: 0) {
            Picker("", selection: $editor.inspectorTab) { Text("Effects").tag("clip"); Text("Color").tag("color"); Text("Audio").tag("audio") }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 10).padding(.vertical, 6)
            switch editor.inspectorTab {
            case "audio": AudioInspector(editor: editor)
            case "clip": EffectsInspector(editor: editor)
            default: ColorInspector(editor: editor)
            }
        }
        .background(Color(white: 0.12))
    }

    @AppStorage("graph.show") var showGraph = false
    var timelineRow: some View {
        HStack(spacing: 0) {
            TimelinePanel(editor: editor, vp: editor.viewport, leading: AnyView(editTools))
            Divider()
            TimelineMeter(live: editor.meter, reset: { editor.resetMeter() })
        }
    }
    var body: some View {
        VSplitView {
            if focus != "timeline" {
            HSplitView {
                if showMedia && focus != "viewer" { MediaPanel(editor: editor).frame(minWidth: 240, idealWidth: 320, maxWidth: 640, minHeight: 300, maxHeight: .infinity) }
                viewer.frame(minWidth: 520, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                if focus != "viewer" { inspector.frame(minWidth: 280, idealWidth: 340, maxWidth: 560, minHeight: 300, maxHeight: .infinity) }
            }
            }
            if focus != "viewer" {
            VStack(spacing: 0) {
                ProjectTabBar(editor: editor)
                MissingMediaBar(editor: editor)
                if showGraph {
                    VSplitView {
                        GraphEditor(editor: editor, live: editor.live, dragState: editor.drag).frame(minHeight: 160, idealHeight: 260, maxHeight: .infinity)
                        timelineRow.frame(minHeight: 120, maxHeight: .infinity)
                    }
                } else { timelineRow }
            }.frame(minHeight: 150, idealHeight: 300, maxHeight: .infinity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleGraph)) { _ in withAnimation(.easeInOut(duration: 0.2)) { showGraph.toggle() } }
        .onReceive(NotificationCenter.default.publisher(for: .fullscreenPlay)) { _ in FullscreenPlayer.toggle(editor) }
        .onReceive(NotificationCenter.default.publisher(for: .focusArea)) { n in
            let a = n.object as? String ?? ""
            withAnimation(.easeInOut(duration: 0.2)) { focus = focus == a ? "" : a }
        }
        .alert("Unsaved changes found", isPresented: Binding(get: { editor.recoveryOffer != nil }, set: { if !$0 && editor.recoveryOffer != nil { editor.discardRecovery() } })) {
            Button("Restore") { Task { await editor.restoreRecovery() } }
            Button("Discard", role: .destructive) { editor.discardRecovery() }
        } message: {
            Text("Cutgenie kept changes to this project that were not saved (from \(editor.recoveryOffer.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "")). Restore them? You can undo the restore with ⌘Z.")
        }
        .sheet(isPresented: $showSettings) { ProjectSettingsView(editor: editor) { showSettings = false } }
        .sheet(isPresented: $showNewProject) { ProjectSettingsView(editor: editor, isNew: true) { showNewProject = false } }
        .onReceive(NotificationCenter.default.publisher(for: .openProjectSettings)) { _ in showSettings = true }
        .sheet(isPresented: $showExport) { ExportView(editor: editor) { showExport = false } }
        .onReceive(NotificationCenter.default.publisher(for: .openExport)) { _ in showExport = true }
        .sheet(isPresented: $showKeys) { KeyboardMap { showKeys = false } }
        .onReceive(NotificationCenter.default.publisher(for: .openShortcuts)) { _ in showKeys = true }
        .onReceive(NotificationCenter.default.publisher(for: .newProject)) { _ in showNewProject = true }
        .onChange(of: editor.projectURL) { _, u in if let u { ProjectTabs.opened(u.path); ProjectPrefs.opened(u.path) } }
        .modifier(ProjectSheets(editor: editor))
        .onAppear { EditorRef.current = editor }
        .onChange(of: editor.offerMatch) { _, f in
            // first clip in an empty project with another format: offer to take its size and frame rate
            guard let f else { return }
            DispatchQueue.main.async {
                let al = NSAlert()
                al.messageText = "Match the project to this clip?"
                al.informativeText = "The clip is \(f.label) (\(f.width) × \(f.height)). The project is \(formatLabel(editor.project.settings))."
                al.addButton(withTitle: "Match this clip"); al.addButton(withTitle: "Keep project settings")
                if al.runModal() == .alertFirstButtonReturn, let p = f.path { Task { _ = await editor.handle(["cmd": "match_clip", "path": p]) } }
                else { editor.offerMatch = nil }
            }
        }
        .preferredColorScheme(.dark)
        .background(Brand.window)
        .overlay(alignment: .top) {
            // messages: a small note that slides in over the viewer and goes away by itself
            if !editor.lastMessage.isEmpty && !editor.lastMessage.hasPrefix("Control server") {
                Toast(text: editor.lastMessage).padding(.top, 52)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: editor.lastMessage)
        .onAppear { KeyHandler.install(self) }
        .onAppear { PlaybackDriver.start(editor) }
    }
}

// MARK: - Timeline

struct TimelinePanel: View {
    nonisolated(unsafe) static var area = CGRect.zero
    static let remapTag: Int64 = 0x6375746c   // timeline area in window points (top-left origin), for the scroll wheel
    @ObservedObject var editor: Editor
    @ObservedObject var vp: ViewportState
    @State private var wfTick = 0
    @State private var resizeStart: (String, Double)? = nil
    @State private var monitor: Any?
    @State private var rmonitor: Any?
    let rulerH = 22.0, gfxH = 18.0, videoH = 40.0, audioH = 54.0, labelW = 64.0

    enum Row: Hashable { case lane(Int), video, audio, alane(Int) }
    // the track list and each track's top are worked out once per change, not once per drawn clip (500+ per redraw)
    nonisolated(unsafe) static var layoutMemo: (key: [Double], rows: [Row], ys: [Row: Double], hs: [Row: Double])?
    var layoutKey: [Double] {
        let p = editor.project
        var k: [Double] = [Double(p.overlays?.count ?? 0), Double(p.upperClips?.count ?? 0), Double(p.audioClips?.count ?? 0),
                           Double(p.gfxLanes ?? 0), Double(p.audioLanes ?? 0), videoH, audioH, gfxH, rulerH]
        var a = 0.0, b = 0.0
        for o in p.overlays ?? [] { a += Double(o.lane * o.lane + o.lane * 7) }
        for c in p.upperClips ?? [] { b += Double((c.lane ?? 1) * 13 + 1) }
        for x in p.audioClips ?? [] { b += Double(x.lane * 31) }
        k += [a, b]
        for (n, h) in (p.trackHeights ?? [:]).sorted(by: { $0.key < $1.key }) { k += [Double(n.hashValue % 100000), h] }
        return k
    }
    func layout() -> (rows: [Row], ys: [Row: Double], hs: [Row: Double]) {
        let key = layoutKey
        if let m = Self.layoutMemo, m.key == key { return (m.rows, m.ys, m.hs) }
        let rs = computeRows()
        var ys: [Row: Double] = [:], hs: [Row: Double] = [:]; var y = rulerH
        for r in rs { let h = computeHeight(r); ys[r] = y; hs[r] = h; y += h }
        Self.layoutMemo = (key, rs, ys, hs)
        return (rs, ys, hs)
    }
    var rows: [Row] { layout().rows }
    func computeRows() -> [Row] {
        let p = editor.project
        var lanes = Set((p.overlays ?? []).map { $0.lane } + (p.upperClips ?? []).map { $0.lane ?? 1 })
        if let g = p.gfxLanes, g > 0 { for l in 1...g { lanes.insert(l) } }
        let aMax = max((p.audioLanes ?? 0) + 1, (p.audioClips ?? []).map { $0.lane }.max() ?? 1)
        // Final Cut order: graphics above the picture, sound right under it (A1, A2, ...), background layers at the bottom
        return lanes.filter { $0 > 0 }.sorted(by: >).map { Row.lane($0) } + [.video] + lanes.filter { $0 < 0 }.sorted(by: >).map { Row.lane($0) }
            + [.audio] + (aMax >= 2 ? (2...aMax).map { Row.alane($0) } : [])
    }
    func name(_ r: Row) -> String { switch r { case .video: return "V1"; case .audio: return "A1"; case .alane(let n): return "A\(n)"; case .lane(let l): return videoName(l) } }
    func height(_ r: Row) -> Double { layout().hs[r] ?? computeHeight(r) }
    func computeHeight(_ r: Row) -> Double {
        if let h = editor.project.trackHeights?[name(r)] { return h }
        switch r {
        case .video: return videoH
        case .audio, .alane: return audioH
        case .lane(let l): return (editor.project.upperClips ?? []).contains { ($0.lane ?? 1) == l } ? videoH : gfxH   // a track with video gets full height
        }
    }
    /// video track names: V1 = main storyline, V2, V3... above it; layers drawn underneath V1 are V1-a, V1-b... (shown below it)
    func videoName(_ l: Int) -> String { l > 0 ? "V\(l + 1)" : "V1-" + String(UnicodeScalar(UInt8(96 + min(26, -l)))) }
    func rowY(_ r: Row) -> Double {
        if r == .alane(1) { return rowY(.audio) }
        let l = layout()
        if let y = l.ys[r] { return y }
        return l.rows.last.map { (l.ys[$0] ?? rulerH) + height($0) } ?? rulerH
    }
    var totalH: Double { rulerH + rows.reduce(0) { $0 + height($1) } }
    /// video track under the pointer for a drag (1 = V2...); above the top track (the ruler) = a new track on top
    func videoLaneAt(_ y: Double) -> Int? {
        if case .lane(let l)? = rowAt(y), l >= 1 { return l }
        if y < rulerH { return (rows.compactMap { if case .lane(let l) = $0 { return l } else { return nil } }.max() ?? 0) + 1 }
        return nil
    }
    func rowAt(_ y: Double) -> Row? { var t = rulerH; for r in rows { if y >= t && y < t + height(r) { return r }; t += height(r) }; return nil }
    var pps: Double { editor.pxPerSec }
    var dur: Double { max(editor.project.totalDuration, 1) }

    func setZoom(_ z: Double) { editor.zoom(to: z, atPointer: false) }
    func importVideo(append: Bool) { TimelinePanel.chooseVideo(editor, append: append) }
    static func chooseVideo(_ editor: Editor, append: Bool) {
        let op = NSOpenPanel()
        op.allowedContentTypes = [.movie]; op.allowsMultipleSelection = true
        guard op.runModal() == .OK else { return }
        Task {
            var at = append ? editor.project.totalDuration : editor.playhead
            for u in op.urls {
                let r = await editor.handle(["cmd": "add_clip", "path": u.path, "offset": at, "insert": !append])
                if let d = r["duration"] as? Double { at += d }
            }
        }
    }
    /// Sync with Audio: problems (wrong selection, no matching sound) come up as a dialog, not just the small status text
    @MainActor static func askText(_ title: String, _ value: String) -> String? {
        let al = NSAlert(); al.messageText = title
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); f.stringValue = value; al.accessoryView = f
        al.addButton(withTitle: "OK"); al.addButton(withTitle: "Cancel")
        al.window.initialFirstResponder = f
        guard al.runModal() == .alertFirstButtonReturn else { return nil }
        let v = f.stringValue.trimmingCharacters(in: .whitespaces); return v.isEmpty ? nil : v
    }
    @MainActor static func syncAudio(_ ed: Editor) {
        Task { @MainActor in
            let r = await ed.handle(["cmd": "sync_clips"])
            let a = NSAlert()
            if r["ok"] as? Bool != true {
                let why = r["error"] as? String ?? "Something went wrong."
                let isSelection = why.hasPrefix("No clips") || why.hasPrefix("Only one") || why.hasPrefix("All the selected")
                a.messageText = "Can't sync with audio"
                a.informativeText = why + (isSelection
                    ? "\n\nTo sync, select at least two clips that recorded the same moment:\n• the main clip (on V1, or the lowest track)\n• the clips to line up with it: other cameras on V2 and up, or sound on audio tracks"
                    : "")
                a.alertStyle = .warning
            } else if let miss = r["not_matched"] as? [String], !miss.isEmpty {
                let n = miss.count
                a.messageText = "\(n) clip\(n == 1 ? "" : "s") couldn't be synced"
                a.informativeText = "\(n == 1 ? "Its" : "Their") sound doesn't match the main clip, so \(n == 1 ? "it was" : "they were") left where \(n == 1 ? "it was" : "they were"). The other clips were synced."
            } else { return }
            a.runModal()
        }
    }
    /// another camera angle: onto the first free video track above V1, at the playhead (several files stack on separate tracks)
    static func chooseVideoUpper(_ editor: Editor) {
        let op = NSOpenPanel()
        op.allowedContentTypes = [.movie]; op.allowsMultipleSelection = true
        guard op.runModal() == .OK else { return }
        Task {
            let at = editor.playhead
            var made: [String] = []
            for u in op.urls {
                let r = await editor.handle(["cmd": "add_clip", "path": u.path, "offset": at, "lane": 1])
                if let id = r["clip"] as? String { made.append(id) }
            }
            editor.selection = Set(made)
        }
    }
    func importFile(audio: Bool) {
        let op = NSOpenPanel()
        op.allowedContentTypes = audio ? [.audio] : [.image]
        op.allowsMultipleSelection = true
        guard op.runModal() == .OK else { return }
        Task {
            for u in op.urls {
                _ = await editor.handle(["cmd": audio ? "add_audio" : "add_graphic", "path": u.path])
            }
        }
    }
    nonisolated(unsafe) static var hovering = false
    nonisolated(unsafe) static var frameInWindow = CGRect.zero   // timeline area, window coordinates (top-left origin)

    var leading: AnyView? = nil          // editing tools from the window (left of the timeline bar)
    var zoomBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: Binding(get: { log2(editor.pxPerSec) }, set: { setZoom(pow(2, $0)) }), in: -1...8.6).frame(width: 120).help("Zoom (⌘ + scroll, pinch, ⌘+ / ⌘−)")
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            Button("Fit") { fit() }.buttonStyle(.borderless).font(.system(size: 11)).help("Fit the whole timeline (⇧Z)")
            Menu {
                Button("New audio track") { Task { _ = await editor.handle(["cmd": "add_track", "kind": "audio"]) } }
                Button("New video track") { Task { _ = await editor.handle(["cmd": "add_track", "kind": "graphics"]) } }
                Button("Adjustment layer (over the selection or at the playhead)") { Task { _ = await editor.handle(["cmd": "add_adjustment"]) } }
                Divider()
                Button("Insert video at playhead (W)…") { importVideo(append: false) }
                Button("Append video at end (E)…") { importVideo(append: true) }
                Button("Add video to a new track (V2+) at playhead…") { TimelinePanel.chooseVideoUpper(editor) }
                Button("Import music / audio at playhead…") { importFile(audio: true) }
                Button("Import image to a video track at playhead…") { importFile(audio: false) }
            } label: { Label("Tracks", systemImage: "plus.rectangle.on.rectangle") }
                .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11)).help("Add tracks, music or images")
            Menu {
                Button("Text (⌃T)") { Task { _ = await editor.handle(["cmd": "add_text"]) } }
                Divider()
                ForEach(ShapeSpec.kinds, id: \.id) { k in Button(k.name) { Task { _ = await editor.handle(["cmd": "add_shape", "kind": k.id]) } } }
            } label: { Label("Graphics", systemImage: "square.on.circle") }
                .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11)).help("Add text, a shape (rectangle, circle, line, colour, gradient) or a blur area at the playhead")
            Spacer()
            if editor.selection.count > 1 {
                Text("\(editor.selection.count) items selected").font(.system(size: 10)).foregroundStyle(.secondary)
            } else if let id = editor.selectedOverlay, let o = editor.project.overlays?.first(where: { $0.id == id }) {
                Text("Layer: \(o.name)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            } else if let c = editor.selectedClip { Text("Clip: \(c)").font(.system(size: 10)).foregroundStyle(.secondary) }
        }.padding(.horizontal, 8).padding(.vertical, 3).background(Color(white: 0.13))
    }
    @State private var viewportW = 1000.0
    @State private var didFit = false
    func fit() { editor.pxPerSec = max(0.5, (editor.viewportW - 20) / dur); editor.scrollX = 0; editor.clampScroll() }

    /// thin grab line at a track's top or bottom edge: drag to make the track taller / shorter (measured against the window,
    /// so the line follows the pointer smoothly while the track grows)
    func resizeHandle(_ r: Row, _ name: String, top: Bool) -> some View {
        Color.clear.frame(height: 5).contentShape(Rectangle())
            .modifier(PointerStyleMod(kind: "updown"))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { v in
                    if resizeStart == nil { resizeStart = (name, height(r)) }
                    if let st = resizeStart {
                        let before = height(r)
                        editor.setTrackHeight(st.0, st.1 + (top ? -1 : 1) * v.translation.height)
                        // top edge: keep the track's bottom where it is, so it grows upward under the pointer
                        if top { editor.scrollY += height(r) - before; editor.clampScroll() }
                    }
                }
                .onEnded { _ in resizeStart = nil })
            .help("Drag to resize \(name)")
    }

    var labels: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: rulerH)
            VStack(spacing: 0) {
            ForEach(rows, id: \.self) { r in
                let name = self.name(r)
                let on = !(editor.project.unsynced ?? []).contains(name)
                TrackHeader(editor: editor, name: name, isVideo: { if case .alane = r { return false }; return r != .audio }(),
                            height: height(r), synced: on, hidden: (editor.project.hiddenTracks ?? []).contains(name), canLock: true,
                            soundOff: (editor.project.hiddenTracks ?? []).contains("\(name) SOUND"),
                            resetHeight: { var d = editor.project.trackHeights ?? [:]; d[name] = nil; editor.project.trackHeights = d.isEmpty ? nil : d })
                    .equatable()
                    .frame(width: labelW, height: height(r)).background(Color(white: r == .video ? 0.17 : 0.14))
                    .overlay(alignment: .bottom) { resizeHandle(r, name, top: false) }
                    .overlay(alignment: .top) { resizeHandle(r, name, top: true) }
                    .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Color.black), alignment: .bottom)
            }
            }
            .fixedSize(horizontal: false, vertical: true)       // full height of all tracks, never squeezed or centred
            .offset(y: -editor.scrollY)
            .frame(maxHeight: .infinity, alignment: .top).clipped()
        }
        .frame(maxHeight: .infinity, alignment: .top).clipped()  // names line up with the tracks however tall they get
    }

    var body: some View {
        HStack(spacing: 0) {
            if let leading {      // vertical tool strip, left of the track names
                ScrollView(.vertical, showsIndicators: false) { leading.padding(.vertical, 6) }
                    .frame(width: 34).background(Color(white: 0.12))
                    .overlay(Rectangle().frame(width: 0.5).foregroundStyle(Color.black), alignment: .trailing)
            }
            mainColumn
        }
    }
    var mainColumn: some View {
        VStack(spacing: 0) {
            zoomBar
            GeometryReader { g in
                let vw = max(100, g.size.width - labelW), vh = g.size.height - 14
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        labels.frame(width: labelW, height: vh, alignment: .top).clipped()
                        ZStack(alignment: .topLeading) {
                            TimelineCanvas(editor: editor, vp: editor.viewport, dp: editor.dragPreview, panel: self, wfTick: wfTick)
                            PlayheadLayer(live: editor.live, pps: pps, height: vh, scrollX: editor.scrollX)
                        }
                        .frame(width: vw, height: vh, alignment: .topLeading).clipped()
                    }
                    // horizontal scroll bar
                    HStack(spacing: 0) {
                        Color.clear.frame(width: labelW)
                        Slider(value: Binding(get: { editor.scrollX }, set: { editor.scrollX = $0; editor.clampScroll() }),
                               in: 0...max(1, dur * pps + 80 - vw)).controlSize(.mini)
                    }.frame(height: 14)
                }
                .background(GeometryReader { gg in Color.clear
                    .onAppear { TimelinePanel.frameInWindow = gg.frame(in: .global); editor.timelineFrame = gg.frame(in: .global) }
                    .onChange(of: gg.frame(in: .global)) { _, f in TimelinePanel.frameInWindow = f; editor.timelineFrame = f } })
                .onAppear {
                    editor.viewportW = vw; editor.viewportH = vh - rulerH; editor.contentH = totalH - rulerH
                }
                .onChange(of: g.size) { _, sz in editor.viewportW = max(100, sz.width - labelW); editor.viewportH = sz.height - 14 - rulerH; editor.clampScroll() }
                .onChange(of: totalH) { _, h in editor.contentH = h - rulerH; editor.clampScroll() }
                .onChange(of: editor.fitTick) { _, _ in fit() }
                .onChange(of: editor.project.totalDuration) { _, _ in editor.clampScroll() }   // edits keep your zoom; only keep the view in range
            }
            .background(Color(white: 0.1))
        }
        .onAppear {
            Waveforms.shared.onReady = { DispatchQueue.main.async { wfTick += 1 } }
            Thumbs.shared.onReady = { DispatchQueue.main.async { wfTick += 1 } }
            // the scroll wheel over the timeline is handled by Cutgenie itself:
            //   mouse wheel = forward/back, ⇧ + wheel = up/down, ⌘ + wheel = zoom at the pointer, trackpad = both directions
            rmonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { e in
                // a click on the timeline ends typing in a panel number box, so arrow keys move the playhead again
                if e.type == .leftMouseDown, let w = e.window, let cv = w.contentView, w.firstResponder is NSText {
                    let p = CGPoint(x: e.locationInWindow.x, y: cv.bounds.height - e.locationInWindow.y)
                    if TimelinePanel.frameInWindow.contains(p) || ViewerZoom.frameInWindow.contains(p) { w.makeFirstResponder(nil) }
                }
                if e.type == .leftMouseDown && !e.modifierFlags.contains(.control) { return e }   // ⌃-click = right-click
                guard let w = e.window, let cv = w.contentView else { return e }
                let p = CGPoint(x: e.locationInWindow.x, y: cv.bounds.height - e.locationInWindow.y)
                let f = TimelinePanel.frameInWindow
                guard f.contains(p), p.x >= f.minX + labelW, let menu = TimelineCanvas.rightClick?(CGPoint(x: p.x - f.minX - labelW, y: p.y - f.minY)) else { return e }
                NSMenu.popUpContextMenu(menu, with: e, for: cv)
                return nil
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { e in
                // only when the wheel is turned over the timeline (checked from where the event lands, not from hover state)
                guard let w = e.window ?? NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }), let cv = w.contentView else { return e }
                let lw = e.window == nil ? w.convertPoint(fromScreen: e.locationInWindow) : e.locationInWindow
                let p = CGPoint(x: lw.x, y: cv.bounds.height - lw.y)
                let vf = ViewerZoom.frameInWindow
                if vf.contains(p) {
                    // over the viewer: pinch / ⌘-scroll zoom around the pointer, scroll pans when zoomed in
                    return MainActor.assumeIsolated { () -> NSEvent? in
                        let vz = ViewerZoom.shared
                        let c = CGPoint(x: p.x - vf.midX, y: p.y - vf.midY)
                        if e.type == .magnify { vz.set(vz.scale * (1 + e.magnification), around: c); return nil }
                        if e.modifierFlags.contains(.command) {
                            let d = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 40 : e.scrollingDeltaY / 4
                            vz.set(vz.scale * pow(1.25, d), around: c); return nil
                        }
                        guard vz.zoom != nil else { return e }
                        let m = e.hasPreciseScrollingDeltas ? 1.0 : 20.0
                        vz.pan = CGSize(width: vz.pan.width + e.scrollingDeltaX * m, height: vz.pan.height + e.scrollingDeltaY * m)
                        return nil
                    }
                }
                guard TimelinePanel.frameInWindow.contains(p) else { return e }
                if e.type == .magnify {          // trackpad pinch: zoom around the pointer, following the fingers
                    let k = 1 + e.magnification
                    MainActor.assumeIsolated { editor.zoom(to: editor.pxPerSec * k) }
                    return nil
                }
                if e.modifierFlags.contains(.command) {
                    let d = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 40 : e.scrollingDeltaY / 4
                    MainActor.assumeIsolated { editor.zoom(to: editor.pxPerSec * pow(1.25, d)) }
                    return nil
                }
                let precise = e.hasPreciseScrollingDeltas
                let trackpad = precise && (!e.phase.isEmpty || !e.momentumPhase.isEmpty) && abs(e.scrollingDeltaX) > 0.01
                var dx = 0.0, dy = 0.0
                if e.modifierFlags.contains(.shift) {
                    // ⇧ + wheel = up/down. macOS turns ⇧+wheel into a sideways scroll (and smooth mice look like a trackpad), so take whichever axis moved.
                    let raw = abs(e.scrollingDeltaY) >= abs(e.scrollingDeltaX) ? e.scrollingDeltaY : e.scrollingDeltaX
                    dy = -raw * (precise ? 1.5 : 30)
                } else if trackpad {
                    dx = -e.scrollingDeltaX; dy = -e.scrollingDeltaY
                } else {
                    let raw = e.scrollingDeltaY != 0 ? e.scrollingDeltaY : e.scrollingDeltaX
                    let amt = raw * (precise ? 1.5 : 30)
                    dx = -amt
                }
                let glide = !precise          // a wheel with notches: glide; trackpad / smooth mouse: follow exactly
                MainActor.assumeIsolated { if glide { editor.glideBy(dx, dy) } else { editor.glideTarget = nil; editor.scrollBy(dx, dy) } }
                return nil
            }
        }
        .onDisappear { if let m = monitor { NSEvent.removeMonitor(m) }; if let m = rmonitor { NSEvent.removeMonitor(m) } }
    }
}

struct TimelineCanvas: View {
    @State private var dropFrame: CGRect = .zero   // the timeline area in window points (top-left origin), for drops
    @ObservedObject var editor: Editor
    @ObservedObject var vp: ViewportState
    @ObservedObject var dp: DragPreview
    let panel: TimelinePanel
    let wfTick: Int
    @State private var session: (kind: String, id: String, mode: DragMode?, startX: Double)? = nil
    @State private var marquee: CGRect? = nil
    @State private var pointerKind = "arrow"
    @State private var lastHover: CGPoint? = nil
    @StateObject private var dbLabel = PointerLabel()       // dB readout next to the pointer (own view, so the timeline isn't redrawn)
    @State private var bladeLine: CGRect? = nil     // blade preview: red line on the item under the pointer (all lanes with ⇧)
    @State private var marqueeBase: Set<String> = []
    @State private var markerDrag: (String, Double)? = nil
    @State private var keyDrag: (id: String, from: Double, to: Double)? = nil   // a clip keyframe diamond being dragged
    @State private var audioPreview: AudioClip? = nil
    @State private var upPreview: Clip? = nil            // video clip being dragged on / onto V2+ (lane nil = back into V1)
    @State private var startRow: TimelinePanel.Row? = nil
    @State private var panLast: CGPoint? = nil
    @State private var volDrag: (id: String, keys: [Int]?, point: Bool, dDb: Double, dt: Double)? = nil
    @State private var volStartT = 0.0
    @State private var fadeDrag: (id: String, out: Bool, value: Double)? = nil   // fade handle being dragged   // volume line / keyframe being dragged
    @State private var dupDrag = false
    @State private var selAnchor: String? = nil    // last clip clicked: ⇧-click selects everything from it to the clicked one
    @State private var groupDt: Double? = nil      // moving several selected items (a group) together: how far, while dragging
    @State private var snapX: Double? = nil            // snap line while an edge is stuck
    @State private var volStartY = 0.0                  // ⌥-drag: move a copy, leave the original
    @State private var trimHint: (x: Double, text: String)? = nil   // Trim tool: live position line + numbers
    @State private var lastMarkerClick: (p: CGPoint, t: Date) = (.zero, .distantPast)

    var pps: Double { editor.pxPerSec }
    func x(_ t: Double) -> Double { t * pps }

    func color(_ name: String) -> Color {
        let n = name.lowercased()
        if n.hasPrefix("bg") { return Color(red: 0.25, green: 0.3, blue: 0.45) }
        if n.hasPrefix("guide") { return Color(red: 0.55, green: 0.35, blue: 0.7) }
        if n.hasPrefix("photo") { return Color(red: 0.25, green: 0.55, blue: 0.6) }
        if n.hasPrefix("transition") { return Color(red: 0.7, green: 0.3, blue: 0.3) }
        if n.contains("amazon") || n.contains("price") { return Color(red: 0.75, green: 0.55, blue: 0.2) }
        return Color(red: 0.45, green: 0.45, blue: 0.6)
    }

    var body: some View {
        let ed = editor
        let sx = ed.scrollX, sy = ed.scrollY
        Canvas { ctx0, size in
            let drawStart = CACurrentMediaTime(); defer { DrawTiming.add(CACurrentMediaTime() - drawStart) }
            _ = wfTick      // redraw when waveforms / thumbnails arrive
            // content is drawn in timeline coordinates, shifted by the scroll position; only what is visible is drawn
            let t0 = sx / pps, t1 = (sx + size.width) / pps
            var rctx = ctx0; rctx.translateBy(x: -sx, y: 0)
            var ctx = ctx0
            ctx.clip(to: Path(CGRect(x: 0, y: panel.rulerH, width: size.width, height: size.height)))
            ctx.translateBy(x: -sx, y: -sy)
            let fullW = size.width + sx
            // ruler (scrolls sideways only)
            rctx.fill(Path(CGRect(x: sx, y: 0, width: size.width, height: panel.rulerH)), with: .color(Color(white: 0.15)))
            let steps = [1.0 / 24, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
            let step = steps.first { $0 * pps >= 70 } ?? 600
            var t = floor(t0 / step) * step
            while t <= t1 + step {
                let px = x(t)
                rctx.stroke(Path { p in p.move(to: CGPoint(x: px, y: panel.rulerH - 8)); p.addLine(to: CGPoint(x: px, y: panel.rulerH)) }, with: .color(.gray), lineWidth: 1)
                let s = Int(t)
                let label = step < 1 ? String(format: "%d:%02d.%02d", s / 60, s % 60, Int((t - Double(s)) * 100)) : String(format: "%d:%02d", s / 60, s % 60)
                rctx.draw(Text(label).font(.system(size: 9)).foregroundColor(.gray), at: CGPoint(x: px + 3, y: 7), anchor: .leading)
                for k in 1..<5 { let mx = x(t + step * Double(k) / 5); rctx.stroke(Path { p in p.move(to: CGPoint(x: mx, y: panel.rulerH - 4)); p.addLine(to: CGPoint(x: mx, y: panel.rulerH)) }, with: .color(Color.gray.opacity(0.5)), lineWidth: 0.5) }
                t += step
            }
            // markers: orange flags on the ruler with their names, thin line down through the tracks
            let shownMarkers = (ed.project.markers ?? []).filter { $0.time >= t0 - 1 && $0.time <= t1 + 1 }.sorted { $0.time < $1.time }
            for (mi, m) in shownMarkers.enumerated() {
                let mx = x(m.time), sel = ed.selectedMarker == m.id
                // the name gets the room up to the next marker (cut short there); markers on top of each other share one label
                let later = shownMarkers[(mi + 1)...].map { x($0.time) }
                let stacked = later.prefix { $0 - mx < 12 }.count
                let prevClose = mi > 0 && mx - x(shownMarkers[mi - 1].time) < 12
                let room = (later.dropFirst(stacked).first ?? .greatestFiniteMagnitude) - mx - 12
                let col = sel ? Brand.accent : Color.orange
                rctx.fill(Path { p in p.move(to: CGPoint(x: mx, y: panel.rulerH)); p.addLine(to: CGPoint(x: mx - 5, y: panel.rulerH - 9))
                    p.addLine(to: CGPoint(x: mx + 5, y: panel.rulerH - 9)); p.closeSubpath() }, with: .color(col))
                if !prevClose && room > 14 {
                    let label = stacked > 0 ? "\(m.name)  +\(stacked)" : m.name
                    rctx.drawLayer { l in
                        l.clip(to: Path(CGRect(x: mx + 6, y: 0, width: room, height: panel.rulerH)))
                        l.draw(Text(label).font(.system(size: 8, weight: .semibold)).foregroundColor(col), at: CGPoint(x: mx + 7, y: panel.rulerH - 5), anchor: .leading)
                    }
                }
                ctx.stroke(Path { p in p.move(to: CGPoint(x: mx, y: sy + panel.rulerH)); p.addLine(to: CGPoint(x: mx, y: sy + size.height)) }, with: .color(col.opacity(0.35)), lineWidth: 1)
            }
            // rows
            for r in panel.rows {
                let y = panel.rowY(r), h = panel.height(r)
                ctx.fill(Path(CGRect(x: sx, y: y, width: fullW, height: h)), with: .color(Color(white: r == .video ? 0.12 : 0.1)))
                ctx.stroke(Path { p in p.move(to: CGPoint(x: sx, y: y + h)); p.addLine(to: CGPoint(x: sx + size.width, y: y + h)) }, with: .color(.black), lineWidth: 0.5)
            }
            let assets = Dictionary(uniqueKeysWithValues: ed.project.assets.map { ($0.id, $0.path) })
            // video clips on V2, V3...
            for raw in (ed.project.upperClips ?? []) + (upPreview.map { u in (ed.project.upperClips ?? []).contains { $0.id == u.id } ? [] : [u] } ?? []) {
                var c = (upPreview?.id == raw.id ? upPreview : nil) ?? raw
                if let ap = audioPreview, let a0 = ed.project.audioClips?.first(where: { $0.id == ap.id }), a0.link == raw.id {
                    // its linked sound is being dragged / trimmed: the picture comes along on screen
                    c.offset = max(0, raw.offset + ap.offset - a0.offset); c.sourceIn = raw.sourceIn + (ap.sourceIn - a0.sourceIn) * raw.sp
                    c.duration = max(0.04, raw.duration + ap.duration - a0.duration)
                }
                if let g = groupDt, ed.selection.contains(c.id) { c.offset += g }
                if c.offset + c.duration < t0 || c.offset > t1 { continue }
                let row: TimelinePanel.Row = (c.lane ?? 0) >= 1 ? .lane(c.lane!) : .video
                let r = CGRect(x: x(c.offset), y: panel.rowY(row) + 2, width: max(2, x(c.duration) - 1), height: panel.height(row) - 4)
                let sel = ed.selection.contains(c.id)
                ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(Color(red: 0.25, green: 0.4, blue: 0.68).opacity(upPreview?.id == c.id ? 0.6 : (sel ? 1 : 0.85))))
                drawThumbs(&ctx, path: assets[c.asset] ?? "", sourceIn: c.sourceIn, speed: c.sp, rect: r, visible: sx...(sx + size.width))
                groupBand(&ctx, c.id, r)
                fpsBadge(&ctx, c, r)
                keyDiamonds(&ctx, c, r)
                if c.disabled == true { ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(Color.black.opacity(0.6))) }   // switched off (V)
                if sel { ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(Brand.accent), lineWidth: 2) }
                if r.width > 24 { clipName(&ctx, Text(((assets[c.asset] ?? "") as NSString).lastPathComponent).font(.system(size: 9)).foregroundColor(.white.opacity(0.9)), r) }
            }
            // graphics
            for raw in ed.project.overlays ?? [] {
                var o = (ed.overlayPreview?.id == raw.id ? ed.overlayPreview : nil) ?? raw
                if let g = groupDt, ed.selection.contains(o.id) || (o.connectedTo.map { ed.selection.contains($0) } ?? false) { o.offset += g }
                if o.offset + o.duration < t0 || o.offset > t1 { continue }
                let y = panel.rowY(.lane(o.lane)) + 1
                let r = CGRect(x: x(o.offset), y: y, width: max(2, x(o.duration) - 1), height: panel.height(.lane(o.lane)) - 2)
                let isAdj = o.adjust != nil
                ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color((isAdj ? Color(red: 0.45, green: 0.42, blue: 0.5) : color(o.name)).opacity(ed.selection.contains(o.id) ? 1 : 0.8)))
                if isAdj { ctx.stroke(Path(roundedRect: r.insetBy(dx: 1, dy: 1), cornerRadius: 3), with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                groupBand(&ctx, o.id, r)
                if o.disabled == true { ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(Color.black.opacity(0.6))) }   // switched off (V)
                if ed.selection.contains(o.id) { ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(Brand.accent), lineWidth: 1.5) }
                if r.width > 30 { clipName(&ctx, Text((isAdj ? "◐ " : "") + o.name).font(.system(size: 8)).foregroundColor(.white), r) }
            }
            // video + audio clips
            let vy = panel.rowY(.video), ay = panel.rowY(.audio)
            for raw in ed.project.clips {
                var c = (ed.preview?.id == raw.id ? ed.preview : nil) ?? raw
                if let g = groupDt, ed.selection.contains(c.id) { c.offset += g }
                if c.offset + c.duration < t0 || c.offset > t1 { continue }
                let path = assets[c.asset] ?? ""
                let isVideo = !(path.hasSuffix(".wav") || path.hasSuffix(".mp3") || path.hasSuffix(".m4a"))
                let sel = ed.selection.contains(c.id)
                if !isVideo {
                    // a sound file on the picture track: nothing to show there (the viewer goes black) - say so
                    let r = CGRect(x: x(c.offset), y: vy + 2, width: max(2, x(c.duration) - 1), height: panel.height(.video) - 4)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(Color.orange.opacity(sel ? 0.35 : 0.18)))
                    ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(sel ? Brand.accent : Color.orange.opacity(0.6)), lineWidth: sel ? 2 : 1)
                    if r.width > 74 {
                        let br = CGRect(x: r.minX + 3, y: r.minY + 3, width: 66, height: 11)
                        ctx.fill(Path(roundedRect: br, cornerRadius: 2), with: .color(.orange))
                        ctx.draw(Text("Sound only").font(.system(size: 8, weight: .bold)).foregroundColor(.black), at: CGPoint(x: br.midX, y: br.midY))
                    }
                    if r.width > 160 { clipName(&ctx, Text("   " + (path as NSString).lastPathComponent + " - no picture").font(.system(size: 9)).foregroundColor(.orange), r.offsetBy(dx: 70, dy: 0)) }
                }
                if isVideo {
                    let r = CGRect(x: x(c.offset), y: vy + 2, width: max(2, x(c.duration) - 1), height: panel.height(.video) - 4)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(Color(red: 0.2, green: 0.35, blue: 0.6).opacity(sel ? 1 : 0.85)))
                    drawThumbs(&ctx, path: path, sourceIn: c.sourceIn, speed: c.sp, rect: r, visible: sx...(sx + size.width))
                    groupBand(&ctx, c.id, r)
                    fpsBadge(&ctx, c, r)
                    keyDiamonds(&ctx, c, r)
                    if c.disabled == true { ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(Color.black.opacity(0.6))) }   // switched off (V)
                    if sel { ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(Brand.accent), lineWidth: 2) }
                    if r.width > 24 { clipName(&ctx, Text((path as NSString).lastPathComponent + (abs(c.sp - 1) > 0.0001 ? "  \(Int((c.sp * 100).rounded())) %" : "")).font(.system(size: 9)).foregroundColor(abs(c.sp - 1) > 0.0001 ? .orange : .white.opacity(0.9)), r) }
                }
                // audio lane with waveform (empty once the sound has been detached to its own clip)
                if c.audioDetached == true { continue }
                let apath = c.audioSource.flatMap { assets[$0.asset] } ?? path
                let ain = c.audioSource?.sourceIn ?? c.sourceIn
                let ar = CGRect(x: x(c.offset), y: ay + 2, width: max(2, x(c.duration) - 1), height: panel.height(.audio) - 4)
                ctx.fill(Path(roundedRect: ar, cornerRadius: 4), with: .color(Color(red: 0.15, green: 0.4, blue: 0.3).opacity(sel ? 1 : 0.85)))
                if c.disabled == true { ctx.fill(Path(roundedRect: ar, cornerRadius: 4), with: .color(Color.black.opacity(0.6))) }   // switched off (V)
                if sel { ctx.stroke(Path(roundedRect: ar, cornerRadius: 4), with: .color(Brand.accent), lineWidth: 2) }
                if let pk = Waveforms.shared.peaks(apath), !pk.isEmpty {
                    var p = Path(); let mid = ar.midY, hh = ar.height / 2 - 2
                    let ck = c.audio.keys?.isEmpty == false ? c.audio.keys : nil   // waveform follows volume, keyframes and fades
                    var px = max(ar.minX, sx)
                    while px < min(ar.maxX, sx + size.width) {
                        let tt = ain + (px - ar.minX) / pps * c.sp
                        let i0 = Int(tt * Waveforms.rate), i1 = max(i0 + 1, Int((tt + 1 / pps) * Waveforms.rate))
                        var m: Float = 0
                        if i0 >= 0 && i0 < pk.count { for i in i0..<min(i1, pk.count) { m = max(m, pk[i]) } }
                        let lt = (px - ar.minX) / pps, gain = pow(10, Volume.level(gain: c.audio.gainDb, keys: ck, at: lt) / 20) * Volume.fade(lt, duration: c.duration, fadeIn: c.audio.fadeIn, fadeOut: c.audio.fadeOut)
                        let a = min(1, Double(m) * gain) * hh
                        p.move(to: CGPoint(x: px, y: mid - a)); p.addLine(to: CGPoint(x: px, y: mid + a))
                        px += 1
                    }
                    ctx.stroke(p, with: .color(Color(red: 0.5, green: 0.9, blue: 0.7)), lineWidth: 1)
                } else {
                    Waveforms.shared.request(apath)
                }
            }
            // extra audio tracks (A2...)
            for raw in ed.project.audioClips ?? [] {
                var a = (audioPreview?.id == raw.id ? audioPreview : nil) ?? raw
                if let l = raw.link, let up = upPreview, up.id == l, let v0 = ed.project.upperClips?.first(where: { $0.id == l }) {
                    // its picture is being dragged: the sound comes along on screen too
                    a.offset = max(0, raw.offset + up.offset - v0.offset)
                    if up.sourceIn != v0.sourceIn || up.duration != v0.duration { a.sourceIn = raw.sourceIn + (up.sourceIn - v0.sourceIn) / max(v0.sp, 0.01); a.duration = up.duration }
                }
                if let g = groupDt, ed.selection.contains(a.id) { a.offset += g }
                if a.offset + a.duration < t0 || a.offset > t1 { continue }
                let sel = ed.selection.contains(a.id)
                let ar = CGRect(x: x(a.offset), y: panel.rowY(.alane(a.lane)) + 2, width: max(2, x(a.duration) - 1), height: panel.height(.alane(a.lane)) - 4)
                let linkedColor = Color(red: 0.2, green: 0.38, blue: 0.62)
                ctx.fill(Path(roundedRect: ar, cornerRadius: 4), with: .color((a.link != nil ? linkedColor : Color(red: 0.3, green: 0.25, blue: 0.5)).opacity(sel ? 1 : 0.85)))
                groupBand(&ctx, a.id, ar)
                if a.disabled == true { ctx.fill(Path(roundedRect: ar, cornerRadius: 4), with: .color(Color.black.opacity(0.6))) }   // switched off (V)
                if sel { ctx.stroke(Path(roundedRect: ar, cornerRadius: 4), with: .color(Brand.accent), lineWidth: 2) }
                let apath = assets[a.asset] ?? ""
                if let pk = Waveforms.shared.peaks(apath), !pk.isEmpty {
                    var p = Path(); let mid = ar.midY, hh = ar.height / 2 - 2, ak = a.keys?.isEmpty == false ? a.keys : nil
                    var px = max(ar.minX, sx)
                    while px < min(ar.maxX, sx + size.width) {
                        let tt = a.sourceIn + (px - ar.minX) / pps
                        let i0 = Int(tt * Waveforms.rate), i1 = max(i0 + 1, Int((tt + 1 / pps) * Waveforms.rate))
                        var m: Float = 0
                        if i0 >= 0 && i0 < pk.count { for i in i0..<min(i1, pk.count) { m = max(m, pk[i]) } }
                        let lt = (px - ar.minX) / pps, gain = pow(10, Volume.level(gain: a.gainDb, keys: ak, at: lt) / 20) * Volume.fade(lt, duration: a.duration, fadeIn: a.fadeIn, fadeOut: a.fadeOut)
                        let h = min(1, Double(m) * gain) * hh
                        p.move(to: CGPoint(x: px, y: mid - h)); p.addLine(to: CGPoint(x: px, y: mid + h)); px += 1
                    }
                    ctx.stroke(p, with: .color(Color(red: 0.75, green: 0.65, blue: 1)), lineWidth: 1)
                } else { Waveforms.shared.request(apath) }
                if ar.width > 30 { clipName(&ctx, Text((a.link != nil ? "🔗 " : "") + a.name + (a.gainDb != 0 ? String(format: "  %+.1f dB", a.gainDb) : "")).font(.system(size: 9)).foregroundColor(.white.opacity(0.9)), ar) }
                // out of sync with its picture (only possible once unlinked): red badge with how far, in frames
                if let off = syncOffset(a), abs(off) >= 0.5 {
                    let tx = Text(String(format: "%+d", Int(off.rounded()))).font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                    let br = CGRect(x: ar.minX + 2, y: ar.maxY - 15, width: 30, height: 13)
                    ctx.fill(Path(roundedRect: br, cornerRadius: 3), with: .color(.red))
                    ctx.draw(tx, at: CGPoint(x: br.midX, y: br.midY))
                }
            }
            // volume lines (+ keyframes) on every visible piece of sound
            var vids: [String] = ed.project.clips.filter { $0.audioDetached != true && $0.offset + $0.duration >= t0 && $0.offset <= t1 }.map { $0.id }
            vids += (ed.project.audioClips ?? []).filter { $0.offset + $0.duration >= t0 && $0.offset <= t1 }.map { $0.id }
            for id in vids {
                guard let v0 = volTarget(id) else { continue }
                let v = applied(v0), r = v.rect
                guard r.width > 3 else { continue }
                let active = volDrag?.id == id
                // fades: darken the faded corner and draw the curve; small handles at the top corners
                for out in [false, true] {
                    let len = out ? v.fadeOut : v.fadeIn
                    if len > 0.001 {
                        var sh = Path(), cv = Path()
                        let n = 16
                        for j in 0...n {
                            let f = Double(j) / Double(n), tt = out ? v.duration - len + f * len : f * len
                            let px = r.minX + tt * pps
                            let lvl = volY(Volume.level(gain: v.gain, keys: v.keys.isEmpty ? nil : v.keys, at: tt), r)
                            let g = Volume.fade(tt, duration: v.duration, fadeIn: out ? nil : len, fadeOut: out ? len : nil)
                            let py = r.maxY - (r.maxY - lvl) * g
                            if j == 0 { sh.move(to: CGPoint(x: px, y: r.minY)); sh.addLine(to: CGPoint(x: px, y: py)); cv.move(to: CGPoint(x: px, y: py)) }
                            else { sh.addLine(to: CGPoint(x: px, y: py)); cv.addLine(to: CGPoint(x: px, y: py)) }
                        }
                        sh.addLine(to: CGPoint(x: r.minX + (out ? v.duration : len) * pps, y: r.minY)); sh.closeSubpath()
                        ctx.fill(sh, with: .color(.black.opacity(0.35)))
                        ctx.stroke(cv, with: .color(.white.opacity(0.75)), lineWidth: 1)
                    }
                    if r.width > 30 {
                        let hx = out ? r.maxX - len * pps - 4 : r.minX + len * pps + 4
                        let hr = CGRect(x: hx - 3, y: r.minY + 1, width: 6, height: 6)
                        ctx.fill(Path(roundedRect: hr, cornerRadius: 1.5), with: .color(fadeDrag?.id == id ? .yellow : .white.opacity(0.85)))
                    }
                }
                if let f = fadeDrag, f.id == id {
                    ctx.draw(Text(String(format: "Fade %@ %.2f s", f.out ? "out" : "in", f.value)).font(.system(size: 10, weight: .semibold)).foregroundColor(.yellow),
                             at: CGPoint(x: max(r.minX, sx) + 6, y: r.maxY - 8), anchor: .leading)
                }
                var path = Path()
                if v.keys.isEmpty {
                    let y = volY(v.gain, r); path.move(to: CGPoint(x: r.minX + 1, y: y)); path.addLine(to: CGPoint(x: r.maxX - 1, y: y))
                } else {
                    path.move(to: CGPoint(x: r.minX + 1, y: volY(v.gain + v.keys[0].db, r)))
                    for k in v.keys { path.addLine(to: CGPoint(x: r.minX + k.t * pps, y: volY(v.gain + k.db, r))) }
                    path.addLine(to: CGPoint(x: r.maxX - 1, y: volY(v.gain + v.keys[v.keys.count - 1].db, r)))
                }
                ctx.stroke(path, with: .color(active ? .yellow : .white.opacity(0.75)), lineWidth: active ? 1.5 : 1)
                for k in v.keys {
                    let c = CGPoint(x: r.minX + k.t * pps, y: volY(v.gain + k.db, r))
                    ctx.fill(Path { p in p.move(to: CGPoint(x: c.x, y: c.y - 4)); p.addLine(to: CGPoint(x: c.x + 4, y: c.y)); p.addLine(to: CGPoint(x: c.x, y: c.y + 4)); p.addLine(to: CGPoint(x: c.x - 4, y: c.y)); p.closeSubpath() },
                             with: .color(active ? .yellow : .white))
                }
            }
            // locked tracks: light grey wash
            for r in panel.rows where (ed.project.unsynced ?? []).contains(panel.name(r)) {
                ctx.fill(Path(CGRect(x: sx, y: panel.rowY(r), width: size.width, height: panel.height(r))), with: .color(.gray.opacity(0.18)))
            }
            // hidden video / muted audio tracks are dimmed
            for r in panel.rows where (ed.project.hiddenTracks ?? []).contains(panel.name(r)) {
                ctx.fill(Path(CGRect(x: sx, y: panel.rowY(r), width: size.width, height: panel.height(r))), with: .color(.black.opacity(0.5)))
            }
        }
        .overlay(alignment: .topLeading) {
            if let b = bladeLine {
                Rectangle().fill(Color.red).frame(width: 1, height: b.height).offset(x: b.minX - 0.5 - editor.scrollX, y: b.minY - editor.scrollY).allowsHitTesting(false)
            }
            if let sx0 = snapX, session != nil {   // snap line: the dragged edge is stuck here
                Rectangle().fill(Brand.accent).frame(width: 1, height: panel.totalH).offset(x: sx0 - editor.scrollX).allowsHitTesting(false)
            }
            PointerLabelView(label: dbLabel, scrollX: editor.scrollX, scrollY: editor.scrollY, rulerH: panel.rulerH)
            if let h = trimHint {
                Rectangle().fill(Brand.accent).frame(width: 1.5, height: panel.totalH).offset(x: h.x - editor.scrollX).allowsHitTesting(false)
                Text(h.text).font(.system(size: 10, weight: .semibold)).padding(3).background(Color.black.opacity(0.75)).foregroundStyle(.yellow)
                    .offset(x: h.x - editor.scrollX + 6, y: panel.rulerH + 2).allowsHitTesting(false)
            }
            if let m = marquee {
                Rectangle().fill(Brand.accent.opacity(0.08)).overlay(Rectangle().stroke(Brand.accent, lineWidth: 1))
                    .frame(width: m.width, height: m.height).offset(x: m.minX - editor.scrollX, y: m.minY - editor.scrollY).allowsHitTesting(false)
            }
        }
        .modifier(PointerStyleMod(kind: pointerKind))
        .onAppear { TimelineCanvas.rightClick = { p in contextMenu(at: p) } }
        .background(GeometryReader { g in Color.clear.onAppear { dropFrame = g.frame(in: .global) }.onChange(of: g.frame(in: .global)) { _, r in dropFrame = r } })
        .onDrop(of: [.fileURL], isTargeted: nil) { providers, loc in
            // drop from Finder: video = inserted into V1 at the nearest cut (or split there), image = layer on a video track, sound = audio track
            // the pointer's real place over the timeline (the drop location SwiftUI gives can be upside down on the Mac)
            var lp = loc
            if let w = NSApp.keyWindow ?? NSApp.mainWindow, let cv = w.contentView, dropFrame.width > 0 {
                let m = w.mouseLocationOutsideOfEventStream
                lp = CGPoint(x: m.x - dropFrame.minX, y: cv.bounds.height - m.y - dropFrame.minY)
            }
            let cp = toContent(lp)
            var t = max(0, cp.x / pps)
            let cuts = editor.project.clips.flatMap { [$0.offset, $0.offset + $0.duration] }
            if let c = cuts.min(by: { abs($0 - t) < abs($1 - t) }), abs(c - t) * pps <= 12 { t = c }
            // the track under the pointer (empty space = V1)
            let row: TimelinePanel.Row = cp.y < panel.rulerH ? .video : (panel.rowAt(cp.y) ?? .video)
            for pr in providers {
                _ = pr.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    let ext = url.pathExtension.lowercased()
                    var cmd: [String: Any]
                    let isVideo = ["mov", "mp4", "m4v", "mxf", "avi"].contains(ext)
                    let isImage = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"].contains(ext)
                    switch row {
                    case .lane(let l) where l >= 1 && (isVideo || isImage):
                        // any video track above V1: video and pictures go on exactly the track they were dropped on
                        cmd = isVideo ? ["cmd": "add_clip", "path": url.path, "offset": t, "lane": l, "gain_db": UserDefaults.standard.double(forKey: "brollGainDb")] : ["cmd": "add_graphic", "path": url.path, "at": t, "lane": l]
                    case .audio, .alane:
                        // dropped on a sound track: just the sound, on that track
                        var a: [String: Any] = ["cmd": "add_audio", "path": url.path, "at": t]
                        if case .alane(let l) = row { a["lane"] = l }
                        cmd = a
                    default:
                        if isVideo { cmd = ["cmd": "add_clip", "path": url.path, "offset": t, "insert": true] }
                        else if isImage { cmd = ["cmd": "add_graphic", "path": url.path, "at": t] }
                        else { cmd = ["cmd": "add_audio", "path": url.path, "at": t] }
                    }
                    Task { @MainActor in
                        // dragged from the media library: only the part marked with I / O (or the saved range)
                        if !isImage, let (it, a, b) = MediaActions.current(), it.path == url.path, b - a > 0.05,
                           MediaState.shared.markIn != nil || MediaState.shared.markOut != nil || MediaState.shared.selected != it.path {
                            cmd["source_in"] = a; cmd["dur"] = b - a
                        }
                        _ = await editor.handle(cmd)
                    }
                }
            }
            return true
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let vp):
                TimelinePanel.hovering = true; editor.hoverX = vp.x
                let p = toContent(vp)
                if editor.skimming && session == nil { editor.skim(to: max(0, min(p.x / pps, editor.project.totalDuration))) }
                pointerKind = kind(at: p); lastHover = p
                if session == nil { showDb(at: p) }
                bladeLine = editor.tool == "blade" ? bladeRect(at: p) : nil
                if editor.live.hideSkimmer != (bladeLine != nil) { editor.live.hideSkimmer = bladeLine != nil }
            case .ended: dbLabel.text = nil; TimelinePanel.hovering = false; editor.hoverX = nil; editor.skim(to: nil); pointerKind = "arrow"; bladeLine = nil; editor.live.hideSkimmer = false
            }
        }
        .gesture(DragGesture(minimumDistance: 0).onChanged(changed).onEnded(ended))
        .onChange(of: editor.tool) { _, _ in if let p = lastHover, editor.hoverX != nil { pointerKind = kind(at: p) } }   // new tool = new pointer at once
        // (no .id(wfTick) here: resetting the view when a waveform / thumbnail arrives threw away clicks and drags in progress;
        //  wfTick is a property, so a new value already redraws the timeline)
    }

    func seek(_ t: Double) { editor.playhead = t; Task { _ = await editor.handle(["cmd": "seek", "time": t]) } }

    static let scissorsCursor: NSCursor = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let img = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) ?? NSImage()
        return NSCursor(image: img, hotSpot: NSPoint(x: img.size.width / 2, y: img.size.height / 2))
    }()
    static let zoomCursor: NSCursor = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let img = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) ?? NSImage()
        return NSCursor(image: img, hotSpot: NSPoint(x: 7, y: 7))
    }()
    /// where the blade preview line goes: over the item under the pointer, or the whole height with ⇧
    // MARK: volume line (Final Cut: drag the line up/down; ⌥-click adds a keyframe; Pen tool P: click adds a keyframe)
    struct VolTarget { var id: String; var offset: Double; var duration: Double; var gain: Double; var keys: [VolKey]; var rect: CGRect; var fadeIn = 0.0; var fadeOut = 0.0 }
    func volTarget(_ id: String) -> VolTarget? {
        if let c = editor.project.clips.first(where: { $0.id == id }), c.audioDetached != true {
            let pc = (editor.preview?.id == id ? editor.preview : nil) ?? c
            return VolTarget(id: id, offset: pc.offset, duration: pc.duration, gain: c.audio.gainDb, keys: c.audio.keys ?? [],
                             rect: CGRect(x: pc.offset * pps, y: panel.rowY(.audio) + 2, width: pc.duration * pps, height: panel.height(.audio) - 4),
                             fadeIn: c.audio.fadeIn ?? 0, fadeOut: c.audio.fadeOut ?? 0)
        }
        if let a0 = editor.project.audioClips?.first(where: { $0.id == id }) {
            let a = (audioPreview?.id == id ? audioPreview : nil) ?? a0
            return VolTarget(id: id, offset: a.offset, duration: a.duration, gain: a0.gainDb, keys: a0.keys ?? [],
                             rect: CGRect(x: a.offset * pps, y: panel.rowY(.alane(a.lane)) + 2, width: a.duration * pps, height: panel.height(a.lane <= 1 ? .audio : .alane(a.lane)) - 4),
                             fadeIn: a0.fadeIn ?? 0, fadeOut: a0.fadeOut ?? 0)
        }
        return nil
    }
    /// audio item under a content point (clip sound on A1 or an audio clip)
    func volTarget(at p: CGPoint) -> VolTarget? {
        guard p.y >= panel.rulerH, let r0 = panel.rowAt(p.y) else { return nil }
        let t = p.x / pps
        switch effRow(r0, t) {
        case .audio: return editor.project.clips.first { t >= $0.offset && t < $0.offset + $0.duration && $0.audioDetached != true }.flatMap { volTarget($0.id) }
        case .alane(let l): return editor.project.audioClips?.first { $0.lane == l && t >= $0.offset && t < $0.offset + $0.duration }.flatMap { volTarget($0.id) }
        default: return nil
        }
    }
    /// which fade handle (false = fade in, true = fade out) is at point p, if any
    func fadeHandle(_ v: VolTarget, _ p: CGPoint) -> Bool? {
        let r = v.rect, y = r.minY + 4
        guard r.width > 30, abs(p.y - y) <= 7 else { return nil }
        if abs(p.x - (r.minX + v.fadeIn * pps + 4)) <= 7 { return false }
        if abs(p.x - (r.maxX - v.fadeOut * pps - 4)) <= 7 { return true }
        return nil
    }
    static let dbTop = 12.0, dbBottom = -48.0
    func volY(_ db: Double, _ r: CGRect) -> Double {
        let n = max(0, min(1, (db - Self.dbBottom) / (Self.dbTop - Self.dbBottom)))
        return r.minY + 3 + (1 - n) * (r.height - 6)
    }
    func dbPerPoint(_ r: CGRect) -> Double { (Self.dbTop - Self.dbBottom) / max(1, r.height - 6) }
    /// the target with the drag in progress applied
    func applied(_ v: VolTarget) -> VolTarget {
        var v = v
        if let f = fadeDrag, f.id == v.id { if f.out { v.fadeOut = f.value } else { v.fadeIn = f.value } }
        guard let d = volDrag, d.id == v.id else { return v }
        var o = v
        if d.point, let k = d.keys?.first, o.keys.indices.contains(k) {
            let lo = k > 0 ? o.keys[k - 1].t : 0, hi = k + 1 < o.keys.count ? o.keys[k + 1].t : o.duration
            o.keys[k].t = max(lo, min(hi, o.keys[k].t + d.dt))
            o.keys[k].db = max(-96, min(Self.dbTop, o.keys[k].db + d.dDb))
        } else if let seg = d.keys, !o.keys.isEmpty {
            for k in seg where o.keys.indices.contains(k) { o.keys[k].db = max(-96, min(Self.dbTop, o.keys[k].db + d.dDb)) }
        } else if o.keys.isEmpty {
            o.gain = max(-96, min(Self.dbTop, o.gain + d.dDb))
        } else {
            o.keys = o.keys.map { VolKey(t: $0.t, db: max(-96, min(Self.dbTop, $0.db + d.dDb))) }
        }
        return o
    }
    func keyString(_ k: [VolKey]) -> String { k.map { String(format: "%.4f:%.2f", $0.t, $0.db) }.joined(separator: ",") }

    /// snapping: t sticks to the nearest snap point within 10 px (shows a snap line); off = unchanged
    static let snapPx = 10.0
    func snapT(_ t: Double, _ ex: Set<String>) -> (Double, Bool) {
        guard editor.snapping else { return (t, false) }
        var best = t, bd = Self.snapPx / pps
        for c in editor.snapPoints(excluding: ex) where abs(c - t) < bd { bd = abs(c - t); best = c }
        return (best, best != t)
    }
    /// moving item [start, start+d): snap whichever edge is nearer to a snap point
    func snapMove(_ raw: Double, _ d: Double, _ ex: Set<String>) -> Double {
        let (a, sa) = snapT(raw, ex), (b0, sb) = snapT(raw + d, ex), b = b0 - d
        var r = raw
        if sa && (!sb || abs(a - raw) <= abs(b - raw)) { r = a; snapX = a * pps } else if sb { r = b; snapX = b0 * pps } else { snapX = nil }
        return max(0, r)
    }
    func snapEdge(_ t: Double, _ ex: Set<String>) -> Double {
        let (r, s) = snapT(t, ex); snapX = s ? r * pps : nil; return r
    }

    nonisolated(unsafe) static var committing = false
    /// apply an edit; the dragged item stays drawn where it was dropped until the timeline has the new positions (no jump back)
    func commit(_ cmd: [String: Any]) {
        TimelineCanvas.committing = true
        Task { _ = await editor.handle(cmd); editor.preview = nil; editor.overlayPreview = nil; audioPreview = nil; volDrag = nil; fadeDrag = nil; upPreview = nil }
    }
    nonisolated(unsafe) static var rightClick: ((CGPoint) -> NSMenu?)?

    /// small frame-rate label on clips recorded at another rate than the project ("60"), green when used for slow motion
    func fpsBadge(_ ctx: inout GraphicsContext, _ c: Clip, _ r: CGRect) {
        // warnings: the file is missing (red outline + "Missing"), or it has no picture (sound file on a video track)
        if editor.revision > 0, editor.mediaDuration[c.asset] == nil {
            ctx.stroke(Path(r.insetBy(dx: 1, dy: 1)), with: .color(.red), lineWidth: 2)
            if r.width > 50 {
                let br = CGRect(x: r.minX + 3, y: r.maxY - 14, width: 46, height: 11)
                ctx.fill(Path(roundedRect: br, cornerRadius: 2), with: .color(.red))
                ctx.draw(Text("Missing").font(.system(size: 8, weight: .bold)).foregroundColor(.white), at: CGPoint(x: br.midX, y: br.midY))
            }
            return
        }
        if editor.mediaDuration[c.asset] != nil, editor.assetFormat[c.asset] == nil, r.width > 30 {
            ctx.fill(Path(r), with: .color(Color.orange.opacity(0.18)))
            if r.width > 70 {
                let br = CGRect(x: r.minX + 3, y: r.maxY - 14, width: 66, height: 11)
                ctx.fill(Path(roundedRect: br, cornerRadius: 2), with: .color(.orange))
                ctx.draw(Text("Sound only").font(.system(size: 8, weight: .bold)).foregroundColor(.black), at: CGPoint(x: br.midX, y: br.midY))
            }
        }
        guard r.width > 40, let f = editor.assetFormat[c.asset], abs(f.fps - editor.project.settings.fps) > 0.05 else { return }
        let slow = abs(c.sp * f.fps - editor.exactFPS) < 0.05
        let t = Text(Editor.fpsName(f.fps) + (slow ? " slow" : "")).font(.system(size: 8, weight: .bold)).foregroundColor(.black)
        let w = slow ? 40.0 : 22.0
        let br = CGRect(x: r.maxX - w - 3, y: r.minY + 3, width: w, height: 11)
        ctx.fill(Path(roundedRect: br, cornerRadius: 2), with: .color(slow ? .green : .orange))
        ctx.draw(t, at: CGPoint(x: br.midX, y: br.midY))
    }
    /// times (from the clip's start) where the clip has keyframes: transform, zoom, slide
    static func clipKeyTimes(_ c: Clip) -> [Double] {
        var ts = (c.xf?.keys ?? [:]).values.flatMap { $0.map(\.t) } + (c.zoom ?? []).map(\.t) + (c.motion ?? []).map(\.t)
        ts = ts.filter { $0 >= -0.001 && $0 <= c.duration + 0.001 }
        return Array(Set(ts.map { ($0 * 1000).rounded() / 1000 })).sorted()
    }
    /// small diamonds along the bottom of a clip for its keyframes (Final Cut style); drag one to move it in time
    func keyDiamonds(_ ctx: inout GraphicsContext, _ c: Clip, _ r: CGRect) {
        var ts = Self.clipKeyTimes(c)
        guard !ts.isEmpty, r.width > 12 else { return }
        if let k = keyDrag, k.id == c.id { ts = ts.map { abs($0 - k.from) < 0.0015 ? k.to : $0 } }
        let y = r.maxY - 6, sel = editor.selection.contains(c.id)
        for t in ts {
            let x = r.minX + t * pps
            guard x >= r.minX - 1, x <= r.maxX + 1 else { continue }
            let d = Path { p in p.move(to: CGPoint(x: x, y: y - 4)); p.addLine(to: CGPoint(x: x + 4, y: y)); p.addLine(to: CGPoint(x: x, y: y + 4)); p.addLine(to: CGPoint(x: x - 4, y: y)); p.closeSubpath() }
            ctx.fill(d, with: .color(sel ? .yellow : Color.white.opacity(0.75)))
            ctx.stroke(d, with: .color(.black.opacity(0.6)), lineWidth: 0.8)
        }
    }
    /// a keyframe diamond of a selected clip under the pointer: (clip id, time in the clip, timeline time)
    func clipKeyHit(_ st: CGPoint) -> (String, Double, Double)? {
        for c in editor.project.clips + (editor.project.upperClips ?? []) where editor.selection.contains(c.id) {
            let row: TimelinePanel.Row = (c.lane ?? 0) >= 1 ? .lane(c.lane!) : .video
            let y = panel.rowY(row) + 2 + panel.height(row) - 4 - 6
            guard abs(st.y - y) <= 7 else { continue }
            for t in Self.clipKeyTimes(c) where abs(c.offset * pps + t * pps - st.x) <= 6 { return (c.id, t, c.offset + t) }
        }
        return nil
    }
    static let groupColors: [Color] = [.pink, .orange, .mint, .cyan, .purple, .yellow]
    /// coloured band along the top of an item that is in a group
    func groupBand(_ ctx: inout GraphicsContext, _ id: String, _ r: CGRect) {
        guard let g = editor.project.groups?.first(where: { $0.members.contains(id) }) else { return }
        var c = ctx; c.clip(to: Path(roundedRect: r, cornerRadius: 4))
        c.fill(Path(CGRect(x: r.minX, y: r.minY, width: r.width, height: 3)), with: .color(Self.groupColors[g.color % Self.groupColors.count]))
    }
    /// a clip's name: one line along its top, cut off at the clip's right edge (never spills out or wraps)
    func clipName(_ ctx: inout GraphicsContext, _ t: Text, _ r: CGRect) {
        var c = ctx
        c.clip(to: Path(r.insetBy(dx: 3, dy: 0)))
        c.draw(t, at: CGPoint(x: r.minX + 4, y: r.minY + 8), anchor: .leading)
    }
    /// every item with its time span and track (row number, top to bottom)
    func itemSpans() -> [(id: String, a: Double, b: Double, row: Int)] {
        let rows = panel.rows, p = editor.project
        func ri(_ r: TimelinePanel.Row) -> Int { rows.firstIndex(of: r) ?? 0 }
        var out: [(String, Double, Double, Int)] = []
        for c in p.clips { out.append((c.id, c.offset, c.offset + c.duration, ri(.video))); if c.audioDetached != true { out.append((c.id, c.offset, c.offset + c.duration, ri(.audio))) } }
        for c in p.upperClips ?? [] { out.append((c.id, c.offset, c.offset + c.duration, ri(.lane(c.lane ?? 1)))) }
        for o in p.overlays ?? [] { out.append((o.id, o.offset, o.offset + o.duration, ri(.lane(o.lane)))) }
        for a in p.audioClips ?? [] { out.append((a.id, a.offset, a.offset + a.duration, ri(a.lane <= 1 ? .audio : .alane(a.lane)))) }
        return out.map { (id: $0.0, a: $0.1, b: $0.2, row: $0.3) }
    }
    /// ⇧-click range: from one item to another, over the time between them and the tracks between them
    func rangeBetween(_ x: String, _ y: String) -> Set<String>? {
        let all = itemSpans()
        let xs = all.filter { $0.id == x }, ys = all.filter { $0.id == y }
        guard !xs.isEmpty, !ys.isEmpty else { return nil }
        let t0 = min(xs.map { $0.a }.min()!, ys.map { $0.a }.min()!), t1 = max(xs.map { $0.b }.max()!, ys.map { $0.b }.max()!)
        let rs = xs.map { $0.row } + ys.map { $0.row }, r0 = rs.min()!, r1 = rs.max()!
        return Set(all.filter { $0.row >= r0 && $0.row <= r1 && $0.a < t1 - 0.001 && $0.b > t0 + 0.001 }.map { $0.id }).filter { editor.lockedTrack(of: $0) == nil }
    }
    /// frames by which a sound sits off its video clip (nil = not tied to one)
    func syncOffset(_ a: AudioClip) -> Double? {
        guard let vid = a.link ?? a.syncWith, let v = (editor.project.clips + (editor.project.upperClips ?? [])).first(where: { $0.id == vid }), a.asset == (v.audioSource?.asset ?? v.asset) else { return nil }
        let want = v.offset - (v.audioSource?.sourceIn ?? v.sourceIn) + a.sourceIn
        return (a.offset - want) * (editor.project.settings.fps > 0 ? editor.project.settings.fps : 25)
    }
    /// A1 holds the clips' own sound and also free audio clips moved up to A1: treat A1 as "audio track 1" where one of those is
    func effRow(_ r: TimelinePanel.Row, _ t: Double, edge: Double = 0) -> TimelinePanel.Row {
        if r == .audio, (editor.project.audioClips ?? []).contains(where: { $0.lane <= 1 && t >= $0.offset - edge && t < $0.offset + $0.duration + edge }) { return .alane(1) }
        return r
    }

    /// filmstrip of picture thumbnails inside a video clip (only when the track is tall enough to see them)
    func drawThumbs(_ ctx: inout GraphicsContext, path: String, sourceIn: Double, speed: Double = 1, rect r: CGRect, visible: ClosedRange<Double>) {
        let h = r.height - 14                       // leave the name line on top
        guard h >= 22, !path.isEmpty else { return }
        let w = h * 16 / 9
        var c2 = ctx
        c2.clip(to: Path(roundedRect: r, cornerRadius: 4))
        let q = max(0.5, (w / pps / 0.5).rounded() * 0.5)       // reuse thumbnails when zoomed out
        // half a screen either side is asked for too (not drawn), so thumbnails are ready before they scroll into view
        let span = visible.upperBound - visible.lowerBound
        let lo = max(r.minX, visible.lowerBound - span / 2), hi = min(r.maxX, visible.upperBound + span / 2)
        var x0 = r.minX + floor((lo - r.minX) / w) * w
        while x0 < hi {
            let t = sourceIn + (x0 - r.minX) / pps * speed
            let img = Thumbs.shared.image(path, at: (t / q).rounded() * q)
            if let img, x0 + w >= visible.lowerBound, x0 <= visible.upperBound {
                c2.draw(Image(decorative: img, scale: 1), in: CGRect(x: x0, y: r.minY + 13, width: w, height: h))
            }
            x0 += w
        }
    }

    /// item under a view point: ("clip"|"gfx"|"aud", id, row)
    func item(at vp: CGPoint) -> (kind: String, id: String, row: TimelinePanel.Row)? {
        let p = toContent(vp), t = p.x / pps
        guard p.y >= panel.rulerH, let r0 = panel.rowAt(p.y) else { return nil }
        let r = effRow(r0, t)
        switch r {
        case .video, .audio: return editor.project.clips.first { t >= $0.offset && t < $0.offset + $0.duration && !(r == .audio && $0.audioDetached == true) }.map { ("clip", $0.id, r) }
        case .lane(let l):
            if let u = editor.project.upperClips?.first(where: { ($0.lane ?? 1) == l && t >= $0.offset && t < $0.offset + $0.duration }) { return ("vup", u.id, r) }
            return editor.project.overlays?.first { $0.lane == l && t >= $0.offset && t < $0.offset + $0.duration }.map { ("gfx", $0.id, r) }
        case .alane(let l): return editor.project.audioClips?.first { $0.lane == l && t >= $0.offset && t < $0.offset + $0.duration }.map { ("aud", $0.id, r) }
        }
    }

    /// Right-click menu (Final Cut style): acts on the item under the pointer (selecting it first if it is not selected).
    func contextMenu(at vp: CGPoint) -> NSMenu? {
        let ed = editor, t = max(0, toContent(vp).x / pps)
        let m = NSMenu(), hit = item(at: vp)
        func add(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = [], enabled: Bool = true, _ f: @escaping () -> Void) {
            let it = ClosureMenuItem(title: title, action: f); it.keyEquivalent = key; it.keyEquivalentModifierMask = mods; it.isEnabled = enabled; m.addItem(it)
        }
        func run(_ c: [String: Any]) { Task { _ = await ed.handle(c) } }
        if let h = hit {
            if !ed.selection.contains(h.id) {
                ed.selection = [h.id]
                if h.kind == "clip" { ed.selectedClip = h.id; ed.selectedOverlay = nil } else if h.kind == "gfx" { ed.selectedOverlay = h.id; ed.selectedClip = nil }
            }
            if h.kind == "clip" || h.kind == "vup" {
                let sm = NSMenu()
                for (n, sp) in [("25 % (slow motion)", 0.25), ("50 %", 0.5), ("75 %", 0.75), ("Normal (100 %)", 1.0), ("125 %", 1.25), ("150 %", 1.5), ("200 %", 2.0), ("400 %", 4.0)] {
                    sm.addItem(ClosureMenuItem(title: n) { run(["cmd": "set_speed", "clip": h.id, "speed": sp]) })
                }
                let it = NSMenuItem(title: "Speed", action: nil, keyEquivalent: ""); it.submenu = sm; m.addItem(it)
                if let cl = (ed.project.clips + (ed.project.upperClips ?? [])).first(where: { $0.id == h.id }), let f = ed.assetFormat[cl.asset], f.fps > ed.exactFPS * 1.05 {
                    add("Use for slow motion (\(Int((ed.exactFPS / f.fps * 100).rounded())) %, every frame)") { run(["cmd": "slow_motion", "clip": h.id]) }
                }
                // many keyframes (a zoom written as small steps): keep the few that shape the move, with easing between them
                if let cl = (ed.project.clips + (ed.project.upperClips ?? [])).first(where: { $0.id == h.id }), TimelineCanvas.clipKeyTimes(cl).count > 4 {
                    let ids = ed.selection.contains(h.id) ? ed.selection.sorted() : [h.id]
                    add(ids.count > 1 ? "Simplify keyframes (\(ids.count) clips)" : "Simplify keyframes (\(TimelineCanvas.clipKeyTimes(cl).count) now)") {
                        run(["cmd": "simplify_keys", "ids": ids.joined(separator: ",")])
                    }
                }
            }
            // Link / Unlink: the same on every track. Linked = sound inside the clip (V1 / A1) or a linked sound clip.
            let acs = ed.project.audioClips ?? [], vs = ed.project.clips + (ed.project.upperClips ?? [])
            let isLinked = ed.selection.contains { id in vs.contains { $0.id == id && $0.audioDetached != true } || acs.contains { $0.id == id && $0.link != nil } }
            add(isLinked ? "Unlink" : "Link", "l", [.command]) { run(["cmd": "toggle_link"]) }
            add("Turn clip off / on", "v", []) { run(["cmd": "toggle_enabled"]) }
            if h.kind == "aud", let a = acs.first(where: { $0.id == h.id }), let off = syncOffset(a), abs(off) >= 0.5 {
                add("Put back in sync") { run(["cmd": "resync_audio", "id": a.id]) }
            }
            if h.kind == "clip" || h.kind == "aud", let v = volTarget(h.id), !v.keys.isEmpty {
                add("Remove volume keyframes") { run(["cmd": "set_volume", "id": h.id, "keys": ""]) }
            }
            add("Sync with audio", "g", [.command, .option]) { TimelinePanel.syncAudio(ed) }
            m.addItem(.separator())
            let grp = ed.project.groups?.first { $0.members.contains(h.id) }
            if ed.selection.count > 1 { add("Group", "g", [.command]) { run(["cmd": "group"]) } }
            if let grp {
                add("Ungroup \(grp.name)", "g", [.command, .shift]) { run(["cmd": "ungroup", "ids": h.id]) }
                add("Rename group…") { if let n = TimelinePanel.askText("Group name", grp.name) { run(["cmd": "rename_group", "id": grp.id, "name": n]) } }
            }
            add("Select everything to the right") { run(["cmd": "select_forward", "at": t]) }
            add("Blade here") { run(["cmd": "blade_selected", "at": t, "ids": h.id]) }
            m.addItem(.separator())
            add("Cut", "x", [.command]) { run(["cmd": "cut"]) }
            add("Copy", "c", [.command]) { run(["cmd": "copy"]) }
            add("Paste at playhead", "v", [.command], enabled: ed.clipboard != nil) { run(["cmd": "paste", "at": ed.playhead]) }
            if let src = ed.attrClip, (ed.project.clips + (ed.project.upperClips ?? [])).contains(where: { $0.id == h.id }) {
                // the look of the clip copied with ⌘C onto this clip (or the selected clips)
                let ids = (ed.selection.contains(h.id) ? ed.selection.sorted() : [h.id]).joined(separator: ",")
                let sm = NSMenu()
                func part(_ title: String, _ p: String) { sm.addItem(ClosureMenuItem(title: title) { run(["cmd": "paste_attrs", "ids": ids, "parts": p]) }) }
                part("Everything", "all"); sm.addItem(.separator())
                part("Position, scale, rotation, opacity", "transform"); part("Zoom", "zoom"); part("Crop", "crop"); part("Drop shadow", "shadow"); part("Colour", "color")
                let name = ed.project.assets.first { $0.id == src.asset }.map { ($0.path as NSString).lastPathComponent } ?? src.id
                let it = NSMenuItem(title: "Paste attributes from \(name) (⇧⌘V = everything)", action: nil, keyEquivalent: "")
                it.submenu = sm; m.addItem(it)
            }
            add("Duplicate here (after this item)") {
                let end = ed.project.clips.first { $0.id == h.id }.map { $0.offset + $0.duration }
                    ?? ed.project.overlays?.first { $0.id == h.id }.map { $0.offset + $0.duration }
                    ?? ed.project.audioClips?.first { $0.id == h.id }.map { $0.offset + $0.duration } ?? t
                Task { _ = await ed.handle(["cmd": "copy"]); _ = await ed.handle(["cmd": "paste", "at": end]) }
            }
            m.addItem(.separator())
            if h.kind == "clip" || h.kind == "vup" || h.kind == "aud" {
                let cl = (ed.project.clips + (ed.project.upperClips ?? [])).first { $0.id == h.id }
                let assetId = cl?.asset ?? ed.project.audioClips?.first { $0.id == h.id }?.asset
                if let aid = assetId, let u = ed.project.resolve(aid, base: ed.base) {
                    add("Show media in Finder", "r", [.command, .shift], enabled: FileManager.default.fileExists(atPath: u.path)) { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                }
                add("Effects") { ed.inspectorTab = "clip" }
                if h.kind != "aud" { add("Colour") { ed.inspectorTab = "color" } }
                add("Audio") { ed.inspectorTab = "audio" }
                if cl != nil { add("Graph editor (keyframes)", "g", [.command, .shift]) { NotificationCenter.default.post(name: .toggleGraph, object: nil) } }
                if let c = cl {
                    let rs = NSMenu()
                    rs.addItem(ClosureMenuItem(title: "Position, scale, rotation, opacity") { ed.liveUpper([c.id]) { x in x.position = nil; x.scale = nil; x.rotation = nil; x.opacity = nil; for p in ["position", "scale", "rotation", "opacity"] { x.keys?[p] = nil } }; ed.commitLive() })
                    rs.addItem(ClosureMenuItem(title: "Crop") { ed.liveUpper([c.id]) { $0.crop = nil; $0.keys?["crop"] = nil }; ed.commitLive() })
                    if ed.project.clips.contains(where: { $0.id == c.id }) {
                        rs.addItem(ClosureMenuItem(title: "Zoom") { ed.liveZoom(c.id) { $0 = [] }; ed.commitLive() })
                    }
                    let ri = NSMenuItem(title: "Reset", action: nil, keyEquivalent: ""); ri.submenu = rs; m.addItem(ri)
                }
                m.addItem(.separator())
            }
            add("Delete", "\u{8}") { run(["cmd": "delete_selected", "ripple": ed.magnetic]) }
            add("Delete and leave gap", "\u{8}", [.shift]) { run(["cmd": "delete_selected", "ripple": false]) }
            m.addItem(.separator())
            add("Add marker here", "m") { run(["cmd": "add_marker", "at": t]) }
        } else {
            add("Paste here", "v", [.command], enabled: ed.clipboard != nil) { run(["cmd": "paste", "at": t]) }
            add("Add marker here", "m") { run(["cmd": "add_marker", "at": t]) }
            add("Select everything to the right") { run(["cmd": "select_forward", "at": t]) }
            m.addItem(.separator())
            add("New audio track") { run(["cmd": "add_track", "kind": "audio"]) }
            add("New video track") { run(["cmd": "add_track", "kind": "graphics"]) }
        }
        return m
    }

    /// dB under the pointer while hovering a sound clip's volume line (or anywhere on a sound clip with the Pen tool)
    func showDb(at p: CGPoint) {
        guard let v = volTarget(at: p), pointerKind == "updown" || editor.tool == "pen" else { dbLabel.text = nil; return }
        if editor.tool == "pen", pointerKind != "updown" {
            dbLabel.set(p, max(-96, min(Self.dbTop, Self.dbTop - (p.y - v.rect.minY - 3) * dbPerPoint(v.rect))))   // where a click would put the keyframe
        } else {
            dbLabel.set(p, Volume.level(gain: v.gain, keys: v.keys.isEmpty ? nil : v.keys, at: p.x / pps - v.offset))
        }
    }

    func renameMarker(_ id: String) { MarkerNaming.ask(editor, id: id) }

    /// view point -> timeline content point (rows scroll vertically, the ruler does not)
    func toContent(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x + editor.scrollX, y: p.y < panel.rulerH ? p.y : p.y + editor.scrollY)
    }

    func bladeRect(at p: CGPoint) -> CGRect? {
        let t = p.x / pps
        if NSEvent.modifierFlags.contains(.shift) { return CGRect(x: p.x, y: panel.rulerH, width: 0, height: panel.totalH - panel.rulerH) }
        guard p.y >= panel.rulerH, let r0 = panel.rowAt(p.y) else { return nil }
        let r = effRow(r0, t)
        switch r {
        case .video, .audio:
            guard let hc = editor.project.clips.first(where: { t > $0.offset && t < $0.offset + $0.duration }), !(r == .audio && hc.audioDetached == true) else { return nil }
            if hc.audioDetached == true { return CGRect(x: p.x, y: panel.rowY(.video), width: 0, height: panel.height(.video)) }
            // a clip has a picture lane and a sound lane: cover both
            let y0 = panel.rowY(.video), y1 = panel.rowY(.audio) + panel.height(.audio)
            return r == .video ? CGRect(x: p.x, y: y0, width: 0, height: panel.height(.video)) : CGRect(x: p.x, y: panel.rowY(.audio), width: 0, height: y1 - panel.rowY(.audio))
        case .lane(let l):
            guard (editor.project.overlays ?? []).contains(where: { $0.lane == l && t > $0.offset && t < $0.offset + $0.duration })
                    || (editor.project.upperClips ?? []).contains(where: { ($0.lane ?? 1) == l && t > $0.offset && t < $0.offset + $0.duration }) else { return nil }
            return CGRect(x: p.x, y: panel.rowY(r), width: 0, height: panel.height(r))
        case .alane(let l):
            guard (editor.project.audioClips ?? []).contains(where: { $0.lane == l && t > $0.offset && t < $0.offset + $0.duration }) else { return nil }
            return CGRect(x: p.x, y: panel.rowY(r), width: 0, height: panel.height(r))
        }
    }

    /// pointer shape for the current tool / position (scissors, magnifier, trim arrows, normal)
    func kind(at p: CGPoint) -> String {
        switch editor.tool {
        case "blade": return "blade"
        case "hand": return "hand"
        case "zoom": return NSEvent.modifierFlags.contains(.option) ? "zoomout" : "zoom"
        case "pen": return "pen"
        case "trim":
            let t = p.x / pps, edge = 7.0 / pps
            if let r = panel.rowAt(p.y), r == .video || r == .audio {
                let cs = editor.project.clips
                if let c = cs.first(where: { abs($0.offset - t) <= edge || abs($0.offset + $0.duration - t) <= edge }) {
                    let at = abs(c.offset - t) <= edge ? c.offset : c.offset + c.duration
                    let both = cs.contains(where: { abs($0.offset + $0.duration - at) < 0.01 }) && cs.contains(where: { abs($0.offset - at) < 0.01 })
                    return both ? "roll" : (at == c.offset ? "trimStart" : "trimEnd")
                }
                if cs.contains(where: { t >= $0.offset && t < $0.offset + $0.duration }) { return NSEvent.modifierFlags.contains(.option) ? "slide" : "slip" }
            }
            return "roll"          // Trim tool is on: show its pointer everywhere (like Final Cut)
        default:
            if let v = volTarget(at: p), fadeHandle(v, p) != nil { return "fade" }
            if let v = volTarget(at: p) {
                if v.keys.contains(where: { abs(v.rect.minX + $0.t * pps - p.x) <= 5 && abs(volY(v.gain + $0.db, v.rect) - p.y) <= 5 }) { return "updown" }
                if abs(volY(Volume.level(gain: v.gain, keys: v.keys.isEmpty ? nil : v.keys, at: p.x / pps - v.offset), v.rect) - p.y) <= 4 { return "updown" }
            }
            let t = p.x / pps, edge = 7.0 / pps
            if let r0 = panel.rowAt(p.y), p.y >= panel.rulerH {
                let r = effRow(r0, t, edge: edge)
                let spans: [(Double, Double)]
                switch r {
                case .video, .audio: spans = editor.project.clips.map { ($0.offset, $0.offset + $0.duration) }
                case .lane(let l): spans = (editor.project.overlays ?? []).filter { $0.lane == l }.map { ($0.offset, $0.offset + $0.duration) }
                    + (editor.project.upperClips ?? []).filter { ($0.lane ?? 1) == l }.map { ($0.offset, $0.offset + $0.duration) }
                case .alane(let l): spans = (editor.project.audioClips ?? []).filter { $0.lane == l }.map { ($0.offset, $0.offset + $0.duration) }
                }
                // which edge: the item under the pointer decides (its start or its end), like the drag does
                if let sp = spans.first(where: { t >= $0.0 && t < $0.1 }) {
                    if t - sp.0 <= edge && (sp.1 - sp.0) * pps > 24 { return "trimStart" }
                    if sp.1 - t <= edge && (sp.1 - sp.0) * pps > 24 { return "trimEnd" }
                } else if let sp = spans.first(where: { abs(t - $0.0) <= edge || abs(t - $0.1) <= edge }) {
                    return abs(t - sp.0) <= edge ? "trimStart" : "trimEnd"
                }
            }
            return "arrow"
        }
    }

    func changed(_ v: DragGesture.Value) {
        if editor.tool == "hand" {          // Hand tool: the timeline moves with the pointer, 1:1, both ways
            let last = panLast ?? v.startLocation
            editor.scrollBy(last.x - v.location.x, last.y - v.location.y)
            panLast = v.location; pointerKind = "grabbing"
            return
        }
        let loc = toContent(v.location)
        let t = max(0, loc.x / pps)
        if session == nil {
            let st = toContent(v.startLocation), ts = st.x / pps, edge = 6.0 / pps
            let mods = NSEvent.modifierFlags
            let additive = mods.contains(.shift) || mods.contains(.command)
            var s: (kind: String, id: String, mode: DragMode?, startX: Double) = ("scrub", "", nil, st.x)
            if st.y >= panel.rulerH, let r0 = panel.rowAt(st.y) {
                let r = effRow(r0, ts, edge: edge)
                switch r {
                case .video, .audio:
                    let pool = r == .audio ? editor.project.clips.filter { $0.audioDetached != true } : editor.project.clips
                    if let c = pool.first(where: { ts >= $0.offset && ts < $0.offset + $0.duration }) ?? pool.first(where: { ts >= $0.offset - edge && ts <= $0.offset + $0.duration + edge }) {
                        let m: DragMode = c.duration * pps > 24 && ts <= c.offset + edge ? .trimStart : c.duration * pps > 24 && ts >= c.offset + c.duration - edge ? .trimEnd : .move
                        s = ("clip", c.id, m, st.x)
                    }
                case .lane(let l):
                    let ups = (editor.project.upperClips ?? []).filter { ($0.lane ?? 1) == l }
                    if let u = ups.first(where: { ts >= $0.offset && ts < $0.offset + $0.duration }) ?? ups.first(where: { ts >= $0.offset - edge && ts <= $0.offset + $0.duration + edge }) {
                        let m: DragMode = u.duration * pps > 24 && ts <= u.offset + edge ? .trimStart : u.duration * pps > 24 && ts >= u.offset + u.duration - edge ? .trimEnd : .move
                        s = ("vup", u.id, m, st.x)
                    } else if let o = editor.project.overlays?.first(where: { $0.lane == l && ts >= $0.offset && ts < $0.offset + $0.duration }) ?? editor.project.overlays?.first(where: { $0.lane == l && ts >= $0.offset - edge && ts <= $0.offset + $0.duration + edge }) {
                        let m: DragMode = o.duration * pps > 24 && ts <= o.offset + edge ? .trimStart : o.duration * pps > 24 && ts >= o.offset + o.duration - edge ? .trimEnd : .move
                        s = ("gfx", o.id, m, st.x)
                    }
                case .alane(let l):
                    let ac = editor.project.audioClips ?? []
                    if let a = ac.first(where: { $0.lane == l && ts >= $0.offset && ts < $0.offset + $0.duration }) ?? ac.first(where: { $0.lane == l && ts >= $0.offset - edge && ts <= $0.offset + $0.duration + edge }) {
                        let m: DragMode = a.duration * pps > 24 && ts <= a.offset + edge ? .trimStart : a.duration * pps > 24 && ts >= a.offset + a.duration - edge ? .trimEnd : .move
                        s = ("aud", a.id, m, st.x)
                    }
                }
            }
            startRow = st.y >= panel.rulerH ? panel.rowAt(st.y) : nil
            if let r = startRow, (editor.project.unsynced ?? []).contains(panel.name(r)), editor.tool != "zoom" {
                editor.lastMessage = "\(panel.name(r)) is locked - unlock it (lock icon) to change it"
                session = ("done", "", nil, st.x); return
            }
            if editor.tool == "select", let hit = clipKeyHit(st) {
                // a keyframe diamond on a selected clip: jump there; dragging moves the keyframe in time
                seek(hit.2)
                session = ("ckey", hit.0, nil, st.x); keyDrag = (hit.0, hit.1, hit.1); return
            }
            if editor.tool == "select", let v = volTarget(at: st), let side = fadeHandle(v, st) {
                session = ("fade", v.id, nil, st.x); fadeDrag = (v.id, side, side ? v.fadeOut : v.fadeIn); return
            }
            if editor.tool == "select" || editor.tool == "pen", let v = volTarget(at: st) {
                let r = v.rect, rel = ts - v.offset
                let lineY = volY(Volume.level(gain: v.gain, keys: v.keys.isEmpty ? nil : v.keys, at: rel), r)
                if let ki = v.keys.firstIndex(where: { abs(r.minX + $0.t * pps - st.x) <= 5 && abs(volY(v.gain + $0.db, r) - st.y) <= 5 }) {
                    s = ("vkey", v.id, nil, st.x); volDrag = (v.id, [ki], true, 0, 0)          // drag one keyframe
                } else if abs(lineY - st.y) <= 5 {
                    // drag the piece of line under the pointer: between two keyframes only that piece (Premiere / Final Cut)
                    var seg: [Int]? = nil
                    if !v.keys.isEmpty {
                        if let i = v.keys.firstIndex(where: { $0.t > rel }) { seg = i == 0 ? [0] : [i - 1, i] } else { seg = [v.keys.count - 1] }
                    }
                    s = ("vol", v.id, nil, st.x); volDrag = (v.id, seg, false, 0, 0)
                } else if editor.tool == "pen" {
                    // Pen tool click off the line: keyframe at the clicked height
                    let db = max(-96, min(Self.dbTop, Self.dbTop - (st.y - r.minY - 3) * dbPerPoint(r)))
                    var k = v.keys; k.append(VolKey(t: rel, db: db - v.gain)); k.sort { $0.t < $1.t }
                    commit(["cmd": "set_volume", "id": v.id, "keys": keyString(k)]); s.kind = "done"
                }
                if s.kind == "vol" || s.kind == "vkey" || s.kind == "done" { session = (s.kind, s.id, nil, st.x); volStartY = st.y; volStartT = rel; return }
            }
            dupDrag = mods.contains(.option) && editor.tool == "select" && s.mode == .move
            if editor.tool == "trim", s.kind == "clip", let c = editor.project.clips.first(where: { $0.id == s.id }) {
                // Trim tool: on a cut between two clips = roll; in the middle = slip; ⌥ in the middle = slide
                let nearEnd = abs(ts - (c.offset + c.duration)) * pps <= 7, nearStart = abs(ts - c.offset) * pps <= 7
                if nearEnd || nearStart {
                    let at = nearEnd ? c.offset + c.duration : c.offset
                    let cs = editor.project.clips, f = editor.frameLength * 0.6
                    if cs.contains(where: { abs($0.offset + $0.duration - at) < f }) && cs.contains(where: { abs($0.offset - at) < f }) {
                        s = ("roll", String(at), nil, st.x)
                    }
                } else { s = (mods.contains(.option) ? "slide" : "slip", c.id, nil, st.x) }
                if !s.kind.hasPrefix("clip") { editor.selection = [c.id]; editor.selectedClip = c.id }
            }
            if editor.tool == "blade" && (mods.contains(.shift) || s.kind == "clip" || s.kind == "gfx" || s.kind == "aud" || s.kind == "vup") {
                // Blade tool: cut the item under the pointer; with ⇧ cut every lane at that point (no selection needed)
                let at = (ts * 1000).rounded() / 1000
                if mods.contains(.shift) {
                    Task { _ = await editor.handle(["cmd": "blade_all", "at": at]) }
                } else {
                    Task { _ = await editor.handle(["cmd": "blade_selected", "at": at, "ids": s.id]) }   // cut only, nothing gets selected
                }
                s.kind = "done"; s.mode = nil
            } else if editor.tool == "zoom" && st.y >= panel.rulerH {
                seek(min(ts, editor.project.totalDuration))
                editor.smoothZoom(to: NSEvent.modifierFlags.contains(.option) ? pps / 1.6 : pps * 1.6, atPointer: true)
                s.kind = "done"
            } else if s.kind == "scrub" && st.y >= panel.rulerH {
                // empty timeline space: click = move playhead; drag = selection box (marquee)
                s.kind = "marquee"
                marqueeBase = additive ? editor.selection : []
                if !additive { editor.selection = []; editor.selectedClip = nil; editor.selectedOverlay = nil }
                editor.skim(to: nil)
                seek(min(ts, editor.project.totalDuration))
            } else if s.kind == "scrub", st.y < panel.rulerH,
                      let m = editor.project.markers?.min(by: { abs($0.time - ts) < abs($1.time - ts) }), abs(m.time - ts) * pps <= 7 {
                // marker on the ruler: select it and jump there; dragging moves it; double-click renames
                if v.startLocation == lastMarkerClick.p && Date().timeIntervalSince(lastMarkerClick.t) < 0.4 { renameMarker(m.id) }
                lastMarkerClick = (v.startLocation, Date())
                editor.selectedMarker = m.id
                seek(m.time)
                s = ("marker", m.id, nil, st.x)
            } else if s.kind == "scrub" {
                // ruler: move the playhead (and clear the selection unless ⇧/⌘ is held)
                if !additive { editor.selection = []; editor.selectedClip = nil; editor.selectedOverlay = nil }
                editor.skim(to: nil)
                seek(min(ts, editor.project.totalDuration))
            } else if mods.contains(.shift), let a = selAnchor, a != s.id, let r = rangeBetween(a, s.id) {
                // ⇧-click: everything from the last clicked clip to this one (time and tracks in between)
                editor.selection = r
                s.mode = nil
            } else if additive {
                // ⌘-click (or ⇧-click with nothing to start from): add or remove just this one
                editor.pickSingle = true
                if editor.selection.contains(s.id) { editor.selection.remove(s.id) } else { editor.selection.insert(s.id) }
                editor.pickSingle = false
                selAnchor = s.id
                s.mode = nil
            } else {
                // plain click on an item: select it (the playhead does NOT move)
                selAnchor = s.id
                if mods.contains(.option) { editor.pickSingle = true; editor.selection = [s.id]; editor.pickSingle = false }   // ⌥-click: just this one, even in a group
                else if !editor.selection.contains(s.id) || editor.selection.count == 1 { editor.selection = [s.id] }
                if s.kind == "clip" { editor.selectedClip = s.id; editor.selectedOverlay = nil } else { editor.selectedOverlay = s.id; editor.selectedClip = nil }
            }
            session = s
        }
        guard let s = session else { return }
        let dt = (loc.x - s.startX) / pps
        if s.mode == .move, !dupDrag, editor.tool == "select", editor.selection.count > 1, editor.selection.contains(s.id),
           ["clip", "vup", "gfx", "aud"].contains(s.kind) {
            // several items selected (a group, linked sound, select-to-the-right...): they all move together
            let all = editor.project.clips.map { ($0.id, $0.offset) } + (editor.project.upperClips ?? []).map { ($0.id, $0.offset) }
                + (editor.project.overlays ?? []).map { ($0.id, $0.offset) } + (editor.project.audioClips ?? []).map { ($0.id, $0.offset) }
            let first = all.filter { editor.selection.contains($0.0) }.map { $0.1 }.min() ?? 0
            // the group snaps too: its first start or last end sticks to other edges, markers and the playhead
            let ends = (editor.project.clips + (editor.project.upperClips ?? [])).filter { editor.selection.contains($0.id) }.map { $0.offset + $0.duration }
                + (editor.project.overlays ?? []).filter { editor.selection.contains($0.id) }.map { $0.offset + $0.duration }
                + (editor.project.audioClips ?? []).filter { editor.selection.contains($0.id) }.map { $0.offset + $0.duration }
            let span = (ends.max() ?? first) - first
            let moved = max(0, first + dt)
            groupDt = snapMove(moved, span, editor.selection) - first
            return
        }
        switch s.kind {
        case "clip":
            if let m = s.mode {
                if m == .move, let l = panel.videoLaneAt(loc.y), startRow == .video, !dupDrag, var u = editor.project.clips.first(where: { $0.id == s.id }) {
                    // V1 clip dragged up onto a video track: show it there
                    u.lane = l; u.offset = snapMove(max(0, ((u.offset + dt) * editor.exactFPS).rounded() / editor.exactFPS), u.duration, [u.id])
                    upPreview = u; editor.preview = nil
                    trimHint = loc.y < panel.rulerH ? (u.offset * pps, "New track V\(l + 1)") : nil
                    return
                }
                upPreview = nil
                editor.preview = editor.dragResult(m, clip: s.id, delta: dt, magnetRange: editor.snapping ? Self.snapPx / pps : 0)
                if let pv = editor.preview, editor.snapping {
                    let pts = editor.snapPoints(excluding: [s.id])
                    snapX = [pv.offset, pv.offset + pv.duration].first { e in pts.contains { abs($0 - e) < 0.0005 } }.map { $0 * pps }
                }
                // magnetic move: show where the clip will drop in (the other clips close up around it)
                if m == .move && editor.magnetic && !dupDrag && !(startRow == .audio && { if case .alane? = panel.rowAt(loc.y) { return true }; return false }()) {
                    trimHint = (editor.magneticDropTime(s.id, delta: dt) * pps, "Drop here")
                }
            }
        case "vup":
            guard let m = s.mode, var u = editor.project.upperClips?.first(where: { $0.id == s.id }) else { return }
            let md = editor.mediaDuration[u.asset] ?? .infinity
            switch m {
            case .move:
                u.offset = snapMove(max(0, ((u.offset + dt) * editor.exactFPS).rounded() / editor.exactFPS), u.duration, [u.id])
                switch panel.rowAt(loc.y) {
                case .video?: u.lane = nil; trimHint = (u.offset * pps, "Insert into V1 here")
                default: if let l = panel.videoLaneAt(loc.y) { u.lane = l }
                }
                if u.lane != nil { trimHint = loc.y < panel.rulerH ? (u.offset * pps, "New track V\((u.lane ?? 1) + 1)") : nil }
            case .trimStart:
                let d = max(-u.sourceIn / u.sp, -u.offset, min(snapEdge(u.offset + dt, [u.id]) - u.offset, u.duration - 0.05)); u.offset += d; u.sourceIn += d * u.sp; u.duration -= d
            case .trimEnd: u.duration = max(0.05, min(snapEdge(u.offset + u.duration + dt, [u.id]) - u.offset, (md - u.sourceIn) / u.sp))
            }
            upPreview = u
        case "gfx":
            guard let m = s.mode, var o = editor.project.overlays?.first(where: { $0.id == s.id }) else { return }
            func snap(_ t: Double) -> Double { snapEdge(t, [o.id]) }
            switch m {
            case .move:
                o.offset = snapMove(max(0, o.offset + dt), o.duration, [o.id])
                if case .lane(let l)? = panel.rowAt(loc.y) { o.lane = l }   // drag up/down to another video track
            case .trimStart: let ns = min(snap(o.offset + dt), o.offset + o.duration - 0.05); o.duration += o.offset - ns; o.offset = ns
            case .trimEnd: o.duration = max(0.05, snap(o.offset + o.duration + dt) - o.offset)
            }
            editor.overlayPreview = o
        case "aud":
            guard let m = s.mode, var a = editor.project.audioClips?.first(where: { $0.id == s.id }) else { return }
            func snap(_ t: Double) -> Double { snapEdge(t, [a.id]) }
            switch m {
            case .move:
                a.offset = snapMove(max(0, a.offset + dt), a.duration, [a.id])
                switch panel.rowAt(loc.y) {   // drag up/down to another audio track (A1 included)
                case .alane(let l)?: a.lane = l
                case .audio?: a.lane = 1
                default: break
                }
            case .trimStart:
                let ns = max(a.offset - a.sourceIn, min(snap(a.offset + dt), a.offset + a.duration - 0.05))
                a.sourceIn += ns - a.offset; a.duration -= ns - a.offset; a.offset = ns
            case .trimEnd: a.duration = max(0.05, snap(a.offset + a.duration + dt) - a.offset)
            }
            audioPreview = a
        case "fade":
            guard var f = fadeDrag, let v = volTarget(f.id) else { return }
            let raw = f.out ? (v.rect.maxX - loc.x) / pps : (loc.x - v.rect.minX) / pps
            f.value = max(0, min(v.duration - (f.out ? v.fadeIn : v.fadeOut), raw))
            fadeDrag = f
        case "vol", "vkey":
            guard var d = volDrag, let v = volTarget(d.id) else { return }
            let fine = NSEvent.modifierFlags.contains(.command) ? 0.1 : 1      // ⌘ = fine adjustment
            d.dDb = -(loc.y - volStartY) * dbPerPoint(v.rect) * fine
            d.dt = d.point ? dt : 0
            volDrag = d
            // live dB next to the pointer: the dragged keyframe's level, else the line's level under the pointer
            let a = applied(v)
            let lvl = d.point ? d.keys?.first.flatMap { a.keys.indices.contains($0) ? a.gain + a.keys[$0].db : nil } ?? a.gain
                : Volume.level(gain: a.gain, keys: a.keys.isEmpty ? nil : a.keys, at: loc.x / pps - a.offset)
            dbLabel.set(loc, lvl)
        case "roll":
            trimHint = (loc.x, String(format: "Roll %+.2f s", dt))
        case "slip":
            trimHint = (loc.x, String(format: "Slip %+.2f s", dt))
        case "slide":
            trimHint = (loc.x, String(format: "Slide %+.2f s", dt))
        case "marker": markerDrag = (s.id, max(0, t))
        case "ckey":
            if let k = keyDrag, let c = (editor.project.clips + (editor.project.upperClips ?? [])).first(where: { $0.id == k.id }) {
                let to = (max(0, min(c.duration, k.from + dt)) * editor.exactFPS).rounded() / editor.exactFPS
                keyDrag = (k.id, k.from, to)
            }
        case "marquee":
            let sp = toContent(v.startLocation)
            let r = CGRect(x: min(s.startX, loc.x), y: min(sp.y, loc.y), width: abs(loc.x - s.startX), height: abs(loc.y - sp.y))
            marquee = r
            guard r.width > 3 || r.height > 3 else { return }
            var hit = marqueeBase
            for c in editor.project.clips {
                for row in c.audioDetached == true ? [TimelinePanel.Row.video] : [TimelinePanel.Row.video, .audio] {
                    let cr = CGRect(x: c.offset * pps, y: panel.rowY(row), width: c.duration * pps, height: panel.height(row))
                    if cr.intersects(r) { hit.insert(c.id) }
                }
            }
            for u in editor.project.upperClips ?? [] {
                let row = TimelinePanel.Row.lane(u.lane ?? 1)
                if CGRect(x: u.offset * pps, y: panel.rowY(row), width: u.duration * pps, height: panel.height(row)).intersects(r) { hit.insert(u.id) }
            }
            for a in editor.project.audioClips ?? [] {
                if CGRect(x: a.offset * pps, y: panel.rowY(.alane(a.lane)), width: a.duration * pps, height: panel.height(a.lane <= 1 ? .audio : .alane(a.lane))).intersects(r) { hit.insert(a.id) }
            }
            for o in editor.project.overlays ?? [] {
                let orr = CGRect(x: o.offset * pps, y: panel.rowY(.lane(o.lane)), width: o.duration * pps, height: panel.height(.lane(o.lane)))
                if orr.intersects(r) { hit.insert(o.id) }
            }
            editor.selection = hit.filter { editor.lockedTrack(of: $0) == nil }     // locked tracks are never selected
        default: if s.kind == "scrub" { seek(min(t, editor.project.totalDuration)) }
        }
    }

    func ended(_ v: DragGesture.Value) {
        if editor.tool == "hand" { panLast = nil; pointerKind = "hand"; return }
        TimelineCanvas.committing = false
        dbLabel.text = nil
        defer {
            session = nil; marquee = nil; trimHint = nil; dupDrag = false; snapX = nil; groupDt = nil
            if !TimelineCanvas.committing { editor.preview = nil; editor.overlayPreview = nil; audioPreview = nil; volDrag = nil; fadeDrag = nil; upPreview = nil }
        }
        if let g = groupDt {
            if abs(g * pps) >= 2 { commit(["cmd": "move_items", "delta": g]) }
            return
        }
        if let s = session, s.kind == "fade", let f = fadeDrag {
            commit(["cmd": "set_fade", "id": s.id, f.out ? "out" : "in": f.value]); return
        }
        if let s = session, s.kind == "vol" || s.kind == "vkey", let d = volDrag, let v0 = volTarget(d.id) {
            let v = applied(v0)
            if abs(d.dDb) <= 0.01 && abs(d.dt) <= 0.001 {
                if editor.tool == "pen" && s.kind == "vol" {   // Pen tool click on the line: keyframe right on the line
                    var k = v0.keys; k.append(VolKey(t: volStartT, db: Volume.level(gain: v0.gain, keys: v0.keys.isEmpty ? nil : v0.keys, at: volStartT) - v0.gain)); k.sort { $0.t < $1.t }
                    commit(["cmd": "set_volume", "id": v.id, "keys": keyString(k)])
                }
                return
            }
            commit(v.keys.isEmpty ? ["cmd": "set_volume", "id": v.id, "gain_db": v.gain] : ["cmd": "set_volume", "id": v.id, "keys": keyString(v.keys)])
            return
        }
        if let s = session, ["roll", "slip", "slide"].contains(s.kind) {
            let dt = (toContent(v.location).x - s.startX) / pps
            guard abs(dt * pps) >= 2 else { return }
            let cmd: [String: Any] = s.kind == "roll" ? ["cmd": "roll", "at": Double(s.id) ?? 0, "delta": dt]
                : ["cmd": s.kind, "clip": s.id, "delta": s.kind == "slip" ? -dt : dt]   // slip: drag right = earlier part of the media, like Final Cut
            commit(cmd)
            return
        }
        if let s = session, s.kind == "clip", s.mode == .move, startRow == .audio, case .alane(let l)? = panel.rowAt(toContent(v.location).y) {
            // dragging a clip's sound from A1 down to an audio track: detach it there (Final Cut needs Detach Audio first)
            let dt = (toContent(v.location).x - s.startX) / pps
            Task {
                let r = await editor.handle(["cmd": "detach_audio", "clip": s.id])
                if let id = (r["audio_clips"] as? [String])?.first, let a = editor.project.audioClips?.first(where: { $0.id == id }) {
                    _ = await editor.handle(["cmd": "audio_edit", "id": id, "lane": l, "offset": max(0, a.offset + dt)])
                }
            }
            return
        }
        if dupDrag, let s = session, ["clip", "gfx", "aud"].contains(s.kind) {
            // ⌥-drag: copy the item(s) and drop the copy where the pointer is, original stays
            let dt = (toContent(v.location).x - s.startX) / pps
            guard abs(dt * pps) >= 2 else { return }
            let start = editor.project.clips.first { $0.id == s.id }?.offset ?? editor.project.overlays?.first { $0.id == s.id }?.offset ?? editor.project.audioClips?.first { $0.id == s.id }?.offset ?? 0
            if !editor.selection.contains(s.id) { editor.selection = [s.id] }
            Task { _ = await editor.handle(["cmd": "copy"]); _ = await editor.handle(["cmd": "paste", "at": max(0, start + dt)]) }
            return
        }
        if let s = session, s.kind == "vup" || s.kind == "clip", let u = upPreview {
            if s.kind == "clip" { commit(["cmd": "to_lane", "clip": u.id, "lane": u.lane ?? 1, "at": u.offset]); return }
            guard let o = editor.project.upperClips?.first(where: { $0.id == u.id }), u != o else { return }
            if s.mode == .move { commit(["cmd": "to_lane", "clip": u.id, "lane": u.lane ?? 0, "at": u.offset]) }
            else if s.mode == .trimStart { commit(["cmd": "upper_trim", "clip": u.id, "trim_start": u.offset - o.offset]) }
            else { commit(["cmd": "upper_trim", "clip": u.id, "duration": u.duration]) }
            return
        }
        if session?.kind == "aud", let p = audioPreview, let o = editor.project.audioClips?.first(where: { $0.id == p.id }), p != o {
            var cmd: [String: Any] = ["cmd": "audio_edit", "id": p.id]
            if p.sourceIn != o.sourceIn { cmd["trim_start"] = p.offset - o.offset } else { cmd["offset"] = p.offset; cmd["duration"] = p.duration; cmd["lane"] = p.lane }
            commit(cmd)
            return
        }
        if session?.kind == "marquee" { return }
        if session?.kind == "ckey" {
            if let k = keyDrag, abs(k.to - k.from) > 0.0005 { commit(["cmd": "move_clip_key", "id": k.id, "from": k.from, "to": k.to]) }
            keyDrag = nil; return
        }
        if session?.kind == "marker", let md = markerDrag, abs(toContent(v.location).x - (session?.startX ?? 0)) >= 3 {
            commit(["cmd": "move_marker", "id": md.0, "at": md.1]); markerDrag = nil; return
        }
        markerDrag = nil
        let loc = toContent(v.location)
        guard let s = session, abs(loc.x - s.startX) >= 2 || (s.kind == "gfx" && editor.overlayPreview.map { p in editor.project.overlays?.first { $0.id == p.id }?.lane != p.lane } == true) else { return }
        let dt = (loc.x - s.startX) / pps
        if s.kind == "clip", let m = s.mode {
            commit(["cmd": "drag_edit", "clip": s.id, "mode": m.rawValue, "delta": dt, "magnet_range": editor.snapping ? Self.snapPx / pps : 0])
        } else if s.kind == "gfx", let o = editor.project.overlays?.first(where: { $0.id == s.id }), let p = editor.overlayPreview {
            if abs(p.duration - o.duration) < 1e-6 && (abs(p.offset - o.offset) > 1e-6 || p.lane != o.lane) {
                commit(["cmd": "overlay_edit", "id": s.id, "offset": p.offset, "lane": p.lane])
            } else if abs(p.offset - o.offset) > 1e-6 {
                commit(["cmd": "overlay_edit", "id": s.id, "trim_start": p.offset - o.offset])
            } else {
                commit(["cmd": "overlay_edit", "id": s.id, "duration": p.duration])
            }
        }
    }
}

// Only these small views follow the playhead / clock, so the timeline itself is not redrawn while playing.
struct TimecodeLabel: View {
    @ObservedObject var live: LiveState
    let frame: Double
    var total: Double = 0
    static func tc(_ t: Double, _ frame: Double) -> String {
        let fps = 1 / max(frame, 0.001), f = Int((t * fps).rounded()), r = Int(fps.rounded())
        return String(format: "%02d:%02d:%02d:%02d", f / r / 3600, f / r / 60 % 60, f / r % 60, f % r)
    }
    var body: some View {
        // where the playhead is, then the whole timeline's length (Premiere style "now / total")
        HStack(spacing: 4) {
            Text(Self.tc(live.playhead, frame)).font(.system(size: 13, weight: .medium).monospacedDigit())
            Text("/ " + Self.tc(total, frame)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
        }.lineLimit(1).help("Playhead position / length of the whole timeline")
    }
}

struct PlayheadLayer: View {
    @ObservedObject var live: LiveState
    let pps: Double, height: Double, scrollX: Double
    var body: some View {
        let x = live.playhead * pps - scrollX
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.white).frame(width: 1.5, height: height).offset(x: x - 0.75)
            Path { p in p.move(to: CGPoint(x: x - 6, y: 0)); p.addLine(to: CGPoint(x: x + 6, y: 0)); p.addLine(to: CGPoint(x: x, y: 9)); p.closeSubpath() }
                .fill(Color.white)
            if let sk = live.skim, !live.hideSkimmer {   // skimmer: follows the mouse (hidden while the blade preview is on a clip)
                Rectangle().fill(Color(red: 1, green: 0.1, blue: 0.1)).frame(width: 1, height: height).offset(x: sk * pps - scrollX)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

// Pointer shape for the timeline: scissors (Blade), magnifier (Zoom), trim arrows near edges, normal arrow.
struct PointerStyleMod: ViewModifier {
    let kind: String
    // Blade pointer: white vertical scissors with a dark outline and a thin vertical cut line (hot spot = the line).
    static let bladeImage: NSImage = {
        let size = NSSize(width: 20, height: 28)
        return NSImage(size: size, flipped: false) { r in
            let cx = r.midX
            // scissors rotated so the blades point down, drawn as outline (black) then fill (white)
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            guard let sym = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return true }
            func tinted(_ c: NSColor) -> NSImage {
                let im = NSImage(size: sym.size, flipped: false) { rr in sym.draw(in: rr); c.set(); rr.fill(using: .sourceAtop); return true }
                return im
            }
            let w = sym.size.width, h = sym.size.height
            func drawRotated(_ im: NSImage, dx: CGFloat, dy: CGFloat) {
                NSGraphicsContext.saveGraphicsState()
                let t = NSAffineTransform()
                t.translateX(by: cx + dx, yBy: r.midY + dy)
                t.rotate(byDegrees: 90)           // blades pointing up, like Final Cut
                t.concat()
                im.draw(in: NSRect(x: -w / 2, y: -h / 2, width: w, height: h))
                NSGraphicsContext.restoreGraphicsState()
            }
            let dark = tinted(.black), light = tinted(.white)
            for (dx, dy) in [(-1.0, 0.0), (1.0, 0.0), (0.0, -1.0), (0.0, 1.0)] { drawRotated(dark, dx: dx, dy: dy) }
            drawRotated(light, dx: 0, dy: 0)
            return true
        }
    }()
    // one view, only the style value changes (switching between different views here could cancel a click in progress)
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(style)
        } else { content }
    }
    @available(macOS 15.0, *)
    var style: PointerStyle {
        switch kind {
        case "blade": return .image(Image(nsImage: PointerStyleMod.bladeImage), hotSpot: UnitPoint(x: 0.5, y: 0.5))
        case "zoom": return .zoomIn
        case "hand": return .grabIdle
        case "grabbing": return .grabActive
        case "zoomout": return .zoomOut
        case "trim": return .columnResize
        case "trimStart": return .image(Image(nsImage: Cursors.trimStart), hotSpot: UnitPoint(x: 0.5, y: 0.5))
        case "trimEnd": return .image(Image(nsImage: Cursors.trimEnd), hotSpot: UnitPoint(x: 0.5, y: 0.5))
        case "roll": return .image(Image(nsImage: Cursors.roll), hotSpot: UnitPoint(x: 0.5, y: 0.5))
        case "slip": return .image(Image(nsImage: Cursors.slip), hotSpot: UnitPoint(x: 0.5, y: 0.5))
        case "slide": return .image(Image(nsImage: Cursors.slide), hotSpot: UnitPoint(x: 0.5, y: 0.5))
        case "updown": return .rowResize
        case "fade": return .columnResize
        case "pen": return .image(Image(nsImage: Cursors.pen), hotSpot: UnitPoint(x: 0.08, y: 0.92))
        default: return .default
        }
    }
}

// Instant tooltip right at the hovered button.
struct HoverTip: ViewModifier {
    let tip: String
    @ObservedObject var editor: Editor
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .onHover { on = $0 }
            .overlay(alignment: .top) {
                if on {
                    Text(tip).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.22)).shadow(radius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.15)))
                        .fixedSize().offset(y: -30).allowsHitTesting(false)
                }
            }
            .zIndex(on ? 10 : 0)
    }
}

// All editing keys in one place (Final Cut layout). Works wherever the focus is in the window, except while typing in a text field.
enum KeyHandler {
    nonisolated(unsafe) static var monitor: Any?
    @MainActor static func install(_ v: ContentView) {
        if let m = monitor { NSEvent.removeMonitor(m) }
        _ = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { e in
            let ms = MediaState.shared
            // typing in a text box (search...) and clicking anywhere else: the keyboard goes back to the editor's shortcuts
            if let w = e.window, let ed = w.firstResponder as? NSText, let cv = w.contentView {
                let hit = cv.hitTest(cv.convert(e.locationInWindow, from: nil))
                let field = ed.delegate as? NSView
                let inside = hit.map { h in h === ed || h.isDescendant(of: ed) || (field.map { f in h === f || h.isDescendant(of: f) } ?? false) } ?? false
                if !inside { MediaState.searchClicked = false; DispatchQueue.main.async { w.makeFirstResponder(nil) } }
            }
            if ms.sourceActive, let cv = e.window?.contentView {
                let p = CGPoint(x: e.locationInWindow.x, y: cv.bounds.height - e.locationInWindow.y)
                if !ms.panelRect.contains(p) && !ms.viewerRect.contains(p) { ms.leaveSource() }
            }
            return e
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e0 in
            if let r = e0.window?.firstResponder as? NSTextView, r.isFieldEditor, e0.keyCode == 53, e0.window?.sheetParent == nil {
                // Esc in a panel number box: stop typing there, keys go back to the timeline
                let w = e0.window; DispatchQueue.main.async { w?.makeFirstResponder(nil) }; return e0
            }
            if let r = e0.window?.firstResponder, r is NSText { return e0 }       // typing in a text field
            let e = CustomKeys.translate(e0)                                     // your own keys (Shortcuts ▸ My keys)
            if e.window?.sheetParent != nil || (e.window?.attachedSheet != nil) { return e }
            if e.keyCode == 53, e.window === FullscreenPlayer.window { return e }   // Esc leaves full screen   // a window like Export is open: its keys (Esc...) are its own
            let ed = v.editor
            // media keys: while the monitor shows a media clip, or the pointer is over the media panel with a clip selected
            let ms = MediaState.shared
            if ms.sourceActive || ((ms.selected != nil || ms.hoverEntry != nil || !ms.path.isEmpty) && ms.pointer(in: ms.panelRect)), MediaActions.key(e, ed) { return nil }
            if e.keyCode == 18, e.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command] {
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "mediaShown"), forKey: "mediaShown"); return nil
            }
            let f = e.modifierFlags.intersection([.command, .shift, .option, .control])
            let ch = (e.charactersIgnoringModifiers ?? "").lowercased()
            let t = ed.playhead, fr = ed.frameLength
            func run(_ c: [String: Any]) { Task { _ = await ed.handle(c) } }
            switch (e.keyCode, f) {
            case (49, []): run(["cmd": ed.player.rate == 0 ? "play" : "pause"])
            case (123, []): v.seek(t - fr)
            case (124, []): v.seek(t + fr)
            case (123, [.shift]): v.seek(t - 10 * fr)
            case (124, [.shift]): v.seek(t + 10 * fr)
            case (126, []): v.jump(forward: false)
            case (125, []): v.jump(forward: true)
            case (115, _): v.seek(0)
            case (119, _): v.seek(ed.project.totalDuration)
            case (51, []), (117, []):
                if let m = ed.selectedMarker, ed.selection.isEmpty { run(["cmd": "delete_marker", "id": m]) } else { v.deleteSelected(ripple: true) }
            case (51, [.shift]), (117, [.shift]):
                if ed.selection.count > 1 { run(["cmd": "delete_selected", "ripple": false]) }
                else if let o = ed.selectedOverlay { run(["cmd": "overlay_delete", "id": o]) }
                else if let c = ed.selectedClip { run(["cmd": "delete", "clip": c, "magnetic": false]) }
            case (53, _): ed.selectedClip = nil; ed.selectedOverlay = nil; ed.selection = []
            default:
                switch (ch, f) {
                case ("m", []): run(["cmd": "add_marker"])
                case ("m", [.option]):
                    Task { let r = await ed.handle(["cmd": "add_marker"]); if let id = r["id"] as? String { MarkerNaming.ask(ed, id: id) } }
                case ("'", [.control]): run(["cmd": "next_marker"])
                case (";", [.control]): run(["cmd": "previous_marker"])
                case ("j", []): v.shuttle(-1)
                case ("k", []): v.shuttle(0)
                case ("l", []): v.shuttle(1)
                case (",", []): run(["cmd": "nudge", "frames": -1])
                case (".", []): run(["cmd": "nudge", "frames": 1])
                case (",", [.shift]), ("<", [.shift]): run(["cmd": "nudge", "frames": -10])
                case (".", [.shift]), (">", [.shift]): run(["cmd": "nudge", "frames": 10])
                case ("c", []): v.selectUnderPlayhead()
                case ("v", []): run(["cmd": "toggle_enabled"])
                case ("t", []): ed.tool = "trim"
                case ("w", []): TimelinePanel.chooseVideo(ed, append: false)
                case ("e", []): TimelinePanel.chooseVideo(ed, append: true)
                case ("c", [.command]): run(["cmd": "copy"])
                case ("x", [.command]): run(["cmd": "cut"])
                case ("v", [.command]): run(["cmd": "paste", "at": t])
                case ("v", [.command, .shift]): run(["cmd": "paste_attrs", "parts": "all"])     // Paste Attributes (Final Cut ⇧⌘V)
                case ("s", [.control, .shift]): run(["cmd": "toggle_link"])
                case ("g", [.command, .option]): TimelinePanel.syncAudio(ed)
                case ("g", [.command]): run(["cmd": "group"])
                case ("g", [.command, .shift]): run(["cmd": "ungroup"])
                case ("l", [.command]): run(["cmd": "toggle_link"])
                case ("a", []): ed.tool = "select"
                case ("b", []): ed.tool = "blade"
                case ("z", []): ed.tool = "zoom"
                case ("h", []): ed.tool = "hand"
                case ("s", []): ed.skimming.toggle(); if !ed.skimming { ed.skim(to: nil) }
                case ("n", []): ed.snapping.toggle()
                case ("p", []): ed.tool = "pen"
                case ("p", [.option]): ed.magnetic.toggle()
                case ("b", [.command]): run(["cmd": "blade_selected", "at": t])
                case ("b", [.command, .shift]): run(["cmd": "blade_all", "at": t])
                case ("b", [.shift]): run(["cmd": "blade_all", "at": t])     // ⇧B: cut every track at the skimmer / playhead
                case ("a", [.command]): run(["cmd": "select_items", "all": true])
                case ("[", [.option]), ("]", [.option]), ("“", []), ("‘", []), ("“", [.option]), ("‘", [.option]):
                    // ⌥[ / ⌥] (Final Cut): trim the start / end of the clip under the skimmer (or playhead) to that point;
                    // with Magnetic on the rest closes up. The selected V1 clip wins if it spans that point.
                    let at = ed.live.skim ?? t
                    let isStart = ch == "[" || ch == "“"
                    let inside: (Clip) -> Bool = { at > $0.offset + fr * 0.5 && at < $0.offset + $0.duration - fr * 0.5 }
                    let target = ed.project.clips.first { $0.id == ed.selectedClip && inside($0) } ?? ed.project.clips.first(where: inside)
                    if let c = target {
                        run(["cmd": "drag_edit", "clip": c.id, "mode": isStart ? "trim_start" : "trim_end",
                             "delta": isStart ? at - c.offset : at - (c.offset + c.duration), "magnet_range": 0])
                    } else { ed.lastMessage = "Put the skimmer or playhead inside a clip to trim it" }
                case ("=", [.command]), ("+", [.command]), ("=", [.command, .shift]): ed.smoothZoom(to: ed.pxPerSec * 1.5)
                case ("-", [.command]): ed.smoothZoom(to: ed.pxPerSec / 1.5)
                case ("z", [.shift]):
                    // ⇧Z: fits whatever the pointer is over - the viewer picture, or the timeline
                    let mp = e.window.map { w in CGPoint(x: w.mouseLocationOutsideOfEventStream.x, y: (w.contentView?.bounds.height ?? 0) - w.mouseLocationOutsideOfEventStream.y) }
                    if let mp, ViewerZoom.frameInWindow.contains(mp) { ViewerZoom.shared.set(nil) } else { ed.fitTick += 1 }
                default: return e
                }
            }
            return nil
        }
    }
}

// Small name prompt for markers.
enum MarkerNaming {
    @MainActor static func ask(_ ed: Editor, id: String) {
        let cur = ed.project.markers?.first { $0.id == id }?.name ?? ""
        let a = NSAlert(); a.messageText = "Marker name"; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); f.stringValue = cur; a.accessoryView = f
        a.window.initialFirstResponder = f
        if a.runModal() == .alertFirstButtonReturn { Task { _ = await ed.handle(["cmd": "rename_marker", "id": id, "name": f.stringValue]) } }
    }
}

// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    let fn: () -> Void
    init(title: String, action f: @escaping () -> Void) { fn = f; super.init(title: title, action: #selector(go), keyEquivalent: ""); target = self }
    required init(coder: NSCoder) { fatalError() }
    @objc func go() { fn() }
}

// Final Cut-style pointers, drawn white with a black outline so they show on any clip colour.
enum Cursors {
    /// shapes are designed on a 32x26 grid and drawn at 60% (about the size of the system pointers), thin white line, fine dark edge
    static let k: CGFloat = 0.6
    static func make(_ w: CGFloat = 32, _ h: CGFloat = 26, _ draw: @escaping (NSBezierPath) -> Void) -> NSImage {
        NSImage(size: NSSize(width: w * k, height: h * k), flipped: false) { _ in
            let p = NSBezierPath(); draw(p)
            let t = AffineTransform(scale: k); p.transform(using: t)
            p.lineJoinStyle = .round; p.lineCapStyle = .round
            NSColor.black.withAlphaComponent(0.85).setStroke(); p.lineWidth = 2.6; p.stroke()
            NSColor.white.setStroke(); p.lineWidth = 1.1; p.stroke()
            return true
        }
    }
    static func arrow(_ p: NSBezierPath, from x0: CGFloat, to x1: CGFloat, y: CGFloat) {
        p.move(to: NSPoint(x: x0, y: y)); p.line(to: NSPoint(x: x1, y: y))
        let d: CGFloat = x1 > x0 ? -4.5 : 4.5
        p.move(to: NSPoint(x: x1 + d, y: y + 4.5)); p.line(to: NSPoint(x: x1, y: y)); p.line(to: NSPoint(x: x1 + d, y: y - 4.5))
    }
    /// ripple trim of a clip's end:  <-> ]   (the bracket is the edge, the arrows show it moves)
    static let trimEnd = make { p in
        p.move(to: NSPoint(x: 13, y: 22)); p.line(to: NSPoint(x: 18, y: 22)); p.line(to: NSPoint(x: 18, y: 4)); p.line(to: NSPoint(x: 13, y: 4))
        arrow(p, from: 16, to: 4, y: 13); arrow(p, from: 20, to: 29, y: 13)
    }
    static let trimStart = make { p in
        p.move(to: NSPoint(x: 19, y: 22)); p.line(to: NSPoint(x: 14, y: 22)); p.line(to: NSPoint(x: 14, y: 4)); p.line(to: NSPoint(x: 19, y: 4))
        arrow(p, from: 16, to: 28, y: 13); arrow(p, from: 12, to: 3, y: 13)
    }
    /// roll: ][  with arrows both ways
    static let roll = make { p in
        p.move(to: NSPoint(x: 10, y: 22)); p.line(to: NSPoint(x: 14, y: 22)); p.line(to: NSPoint(x: 14, y: 4)); p.line(to: NSPoint(x: 10, y: 4))
        p.move(to: NSPoint(x: 22, y: 22)); p.line(to: NSPoint(x: 18, y: 22)); p.line(to: NSPoint(x: 18, y: 4)); p.line(to: NSPoint(x: 22, y: 4))
        arrow(p, from: 9, to: 2, y: 13); arrow(p, from: 23, to: 30, y: 13)
    }
    /// slip: [<->]
    static let slip = make { p in
        p.move(to: NSPoint(x: 7, y: 22)); p.line(to: NSPoint(x: 3, y: 22)); p.line(to: NSPoint(x: 3, y: 4)); p.line(to: NSPoint(x: 7, y: 4))
        p.move(to: NSPoint(x: 25, y: 22)); p.line(to: NSPoint(x: 29, y: 22)); p.line(to: NSPoint(x: 29, y: 4)); p.line(to: NSPoint(x: 25, y: 4))
        arrow(p, from: 16, to: 8, y: 13); arrow(p, from: 16, to: 24, y: 13)
    }
    /// slide: <-[ ]->
    static let slide = make { p in
        p.move(to: NSPoint(x: 13, y: 20)); p.line(to: NSPoint(x: 10, y: 20)); p.line(to: NSPoint(x: 10, y: 6)); p.line(to: NSPoint(x: 13, y: 6))
        p.move(to: NSPoint(x: 19, y: 20)); p.line(to: NSPoint(x: 22, y: 20)); p.line(to: NSPoint(x: 22, y: 6)); p.line(to: NSPoint(x: 19, y: 6))
        arrow(p, from: 8, to: 2, y: 13); arrow(p, from: 24, to: 30, y: 13)
    }
    /// pen nib pointing down-left (the tip is the hot spot)
    /// pen nib pointing down-left (the tip is the hot spot), 17 px
    static let pen: NSImage = NSImage(size: NSSize(width: 17, height: 17), flipped: false) { _ in
        let body = NSBezierPath()
        body.move(to: NSPoint(x: 1.5, y: 1.5)); body.line(to: NSPoint(x: 4, y: 8)); body.line(to: NSPoint(x: 12.5, y: 16)); body.line(to: NSPoint(x: 16, y: 12.5))
        body.line(to: NSPoint(x: 8, y: 4)); body.close()
        body.lineJoinStyle = .round
        NSColor.black.withAlphaComponent(0.85).setStroke(); body.lineWidth = 1.6; body.stroke()
        NSColor.white.setFill(); body.fill()
        let slit = NSBezierPath(); slit.move(to: NSPoint(x: 1.5, y: 1.5)); slit.line(to: NSPoint(x: 6, y: 6))
        slit.move(to: NSPoint(x: 4, y: 8)); slit.line(to: NSPoint(x: 8, y: 4))
        NSColor.black.setStroke(); slit.lineWidth = 0.9; slit.stroke()
        return true
    }
}

// Track header (left of each track): colour band (blue = video, green = audio), readable name, and controls.
// The sync lock shows on hover, or always when it is OFF (the exception you need to see). Tall tracks also show hide / mute.
// Right-click for everything.
// redrawn only when its own track changed (not on every edit: a project with 40 graphic tracks has 45 of these)
struct TrackHeader: View, Equatable {
    let editor: Editor
    let name: String, isVideo: Bool, height: Double, synced: Bool, hidden: Bool, canLock: Bool
    var soundOff = false
    let resetHeight: () -> Void
    static func == (a: TrackHeader, b: TrackHeader) -> Bool {
        a.name == b.name && a.isVideo == b.isVideo && a.height == b.height && a.synced == b.synced && a.hidden == b.hidden && a.canLock == b.canLock && a.soundOff == b.soundOff
    }
    @State private var hover = false
    func run(_ c: [String: Any]) { Task { _ = await editor.handle(c) } }
    var lockButton: some View {        // synced == not locked
        Button { run(["cmd": "sync_lock", "track": name, "on": !synced]) } label: {
            Image(systemName: synced ? "lock.open" : "lock.fill").font(.system(size: 10)).foregroundStyle(synced ? Color.secondary : Color.orange)
        }.buttonStyle(.borderless)
        .help(synced ? "Lock \(name): nothing on it can be selected, moved, cut, deleted or changed" : "\(name) is locked (click to unlock)")
    }
    var hideButton: some View {
        Button { run(["cmd": "track_hidden", "track": name, "on": !hidden]) } label: {
            Image(systemName: isVideo ? (hidden ? "eye.slash" : "eye") : (hidden ? "speaker.slash.fill" : "speaker.wave.2.fill"))
                .font(.system(size: 10)).foregroundStyle(hidden ? Color.orange : Color.secondary)
        }.buttonStyle(.borderless).help(isVideo ? (hidden ? "Show \(name)" : "Hide \(name) in the picture") : (hidden ? "Unmute \(name)" : "Mute \(name)"))
    }
    /// V2+: switch the sound of all its clips off / on in one click (B-roll room noise)
    var soundButton: some View {
        Button { run(["cmd": "track_hidden", "track": "\(name) SOUND", "on": !soundOff]) } label: {
            Image(systemName: soundOff ? "speaker.slash.fill" : "speaker.wave.2").font(.system(size: 10)).foregroundStyle(soundOff ? Color.orange : Color.secondary)
        }.buttonStyle(.borderless).help(soundOff ? "Turn on the sound of \(name) clips" : "Turn off the sound of \(name) clips")
    }
    // video tracks only hide / show; their sound lives on the audio tracks (A2...), which have their own mute
    var hasSoundToggle: Bool { false }
    var body: some View {
        let tall = height >= 44
        HStack(spacing: 0) {
            Rectangle().fill(isVideo ? Color(red: 0.3, green: 0.5, blue: 0.9) : Color(red: 0.25, green: 0.7, blue: 0.5)).frame(width: 3)
            if tall {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(hidden ? .tertiary : .secondary)
                    HStack(spacing: 6) { if canLock { lockButton }; hideButton; if hasSoundToggle { soundButton } }
                }.padding(.leading, 6)
                Spacer(minLength: 0)
            } else {
                Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(hidden ? .tertiary : .secondary).padding(.leading, 6)
                Spacer(minLength: 0)
                if isVideo { hideButton.padding(.trailing, 2) }
                else if hidden { Image(systemName: "speaker.slash.fill").font(.system(size: 9)).foregroundStyle(.orange) }
                if canLock { lockButton.padding(.trailing, 4) }
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            if canLock { Button(synced ? "Lock track" : "Unlock track") { run(["cmd": "sync_lock", "track": name, "on": !synced]) } }
            Button(isVideo ? (hidden ? "Show track" : "Hide track") : (hidden ? "Unmute track" : "Mute track")) { run(["cmd": "track_hidden", "track": name, "on": !hidden]) }
            if hasSoundToggle { Button(soundOff ? "Turn on clip sound" : "Turn off clip sound") { run(["cmd": "track_hidden", "track": "\(name) SOUND", "on": !soundOff]) } }
            Divider()
            Button("Make taller") { editor.setTrackHeight(name, height + 30) }
            Button("Make slimmer") { editor.setTrackHeight(name, height - 30) }
            Button("Reset height") { resetHeight() }
            Divider()
            Button("New video track") { run(["cmd": "add_track", "kind": "graphics"]) }
            Button("New audio track") { run(["cmd": "add_track", "kind": "audio"]) }
            Button("Remove empty tracks at the top") { run(["cmd": "remove_empty_tracks"]) }
        }
    }
}

/// tiny dB readout that follows the pointer
final class PointerLabel: ObservableObject {
    @Published var text: String? = nil
    @Published var pt = CGPoint.zero
    func set(_ p: CGPoint, _ db: Double) {
        let t = db <= -95 ? "-∞ dB" : String(format: "%+.1f dB", db)
        if t != text || abs(p.x - pt.x) > 0.5 || abs(p.y - pt.y) > 0.5 { text = t; pt = p }
    }
}
struct PointerLabelView: View {
    @ObservedObject var label: PointerLabel
    let scrollX: Double, scrollY: Double, rulerH: Double
    var body: some View {
        if let t = label.text {
            Text(t).font(.system(size: 10, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.8)))
                .foregroundStyle(.yellow)
                .fixedSize()
                .offset(x: label.pt.x - scrollX + 14, y: label.pt.y - scrollY - 22)
                .allowsHitTesting(false)
        }
    }
}


// Moves the playhead with the picture, 60 times a second, outside SwiftUI (an .onReceive timer made the view graph
// update every tick). The playhead value only changes when the frame changes, so the timecode, playhead line and
// handles redraw at the video's frame rate, not the screen's.
@MainActor
enum PlaybackDriver {
    private static var timer: Timer?
    static func start(_ editor: Editor) {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak editor] _ in
            MainActor.assumeIsolated { if let editor { step(editor) } }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    static func step(_ editor: Editor) {
        if editor.swapping { editor.updateMeter(); return }
        let t = editor.player.currentTime().seconds
        let half = editor.frameLength * 0.5
        func setHead(_ v: Double) { if abs(v - editor.playhead) >= half { editor.playhead = v } }
        if t.isFinite {
            if editor.player.rate != 0 {
                // playing: the playhead always follows the picture (a skimmer left over from before Play is dropped)
                if editor.live.skim != nil { editor.live.skim = nil }
                setHead(t)
                // the timeline turns the page when the playhead reaches the right edge (Final Cut style), never mid-drag
                let px = t * editor.pxPerSec - editor.scrollX
                if editor.player.rate > 0, px > editor.viewportW * 0.92 || px < 0 { editor.scrollX = t * editor.pxPerSec - editor.viewportW * 0.08; editor.clampScroll() }
            } else if editor.live.skim == nil, abs(t - editor.playhead) > 0.0001, abs(t - editor.playhead) >= half || editor.player.timeControlStatus == .paused {
                editor.playhead = t
            }
        }
        editor.updateMeter()      // the level meter beside the timeline is always on screen
    }
}


struct ViewerZoomMenu: View {
    @ObservedObject var vz = ViewerZoom.shared
    var body: some View {
        Menu {
            Button((vz.zoom == nil ? "✓ " : "   ") + "Fit  (⇧Z over the viewer)") { vz.set(nil) }
            Divider()
            ForEach(ViewerZoom.presets, id: \.self) { z in
                Button((vz.zoom.map { abs($0 - z) < 0.001 } == true ? "✓ " : "   ") + "\(Int(z * 100))%") { vz.zoom = nil; vz.pan = .zero; vz.set(z) }
            }
        } label: { Text(vz.label).font(.system(size: 10, weight: .medium).monospacedDigit()) }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Viewer zoom - pinch or ⌘-scroll over the picture to zoom, scroll to move around")
    }
}
