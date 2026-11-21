import AppKit
import AVFoundation
import Combine
import QuartzCore
import ImageIO
import Foundation
import CoreGraphics

/// tiny "something is being dragged" signal: views that must follow a drag live observe this instead of the whole editor
public final class DragState: ObservableObject {
    @Published public var tick = 0
    public init() {}
}

/// the level meter's numbers, on their own so a meter update redraws only the meter (not the playhead, viewer handles...).
/// Views are told to redraw only when a value changed enough to see (0.5 dB) - silence and steady sound cost nothing.
public final class MeterState: ObservableObject {
    public private(set) var meterDb = -90.0, rmsDb = -90.0, momentaryLUFS = -90.0, peakHoldDb = -90.0, maxPeakDb = -90.0
    public private(set) var overload = false
    public init() {}
    func update(peak: Double, rms: Double, lufs: Double, hold: Double, max mx: Double, over: Bool) {
        func q(_ v: Double) -> Double { v <= -89 ? -90 : (v * 2).rounded() / 2 }
        let n = (q(peak), q(rms), q(lufs), q(hold), q(mx), over)
        guard n != (meterDb, rmsDb, momentaryLUFS, peakHoldDb, maxPeakDb, overload) else { return }
        objectWillChange.send()
        (meterDb, rmsDb, momentaryLUFS, peakHoldDb, maxPeakDb, overload) = n
    }
}

public final class DragPreview: ObservableObject {
    @Published public var clip: Clip?
    @Published public var overlay: Overlay?
    public init() {}
}

/// timeline zoom and scroll (watched only by the timeline)
public final class ViewportState: ObservableObject {
    @Published public var pxPerSec = 8.0
    @Published public var scrollX = 0.0
    @Published public var scrollY = 0.0
    public init() {}
}

public final class LiveState: ObservableObject {
    @Published public var playhead = 0.0
    @Published public var skim: Double? = nil
    @Published public var hideSkimmer = false        // blade preview is showing on a clip: hide the skimmer line        // skimmer position (mouse over the timeline), nil = not skimming
    public init() {}
}

@MainActor
public final class Editor: ObservableObject {
    @Published public var project = Project()
    /// short note under the viewer (problems only); clears itself after a few seconds
    @Published public var titleTick = 0                    // saved titles changed (menus redraw)
    @Published public var lastMessage = "" { didSet { if !lastMessage.isEmpty { let m = lastMessage
        Log.write("message: \(m)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in if self?.lastMessage == m { self?.lastMessage = "" } } } } }
    @Published public var revision = 0
    // fast-changing values live in their own object so the whole editor (timeline!) does not redraw 20x a second
    public let live = LiveState()
    public var playhead: Double { get { live.playhead } set { live.playhead = newValue } }
    @Published public var selectedClip: String?
    @Published public var displayGamma = 0.91          // on-screen window only: brightness curve fitted to Final Cut's viewer (1.0 = none)
    @Published public var inspectorTab = "color"
    @Published public var selectedOverlay: String?
    @Published public var selectedMarker: String?
    @Published public var selection: Set<String> = [] {   // multi-selection: clip ids and graphic ids
        didSet {
            // a V2+ clip and its linked sound are selected together (Premiere-style linked clips)
            // ...and so is everything in a group (⌥-click picks just one: pickSingle)
            if pickSingle { return }
            let ac = project.audioClips ?? []
            var x = selection
            for g in project.groups ?? [] where g.members.contains(where: { x.contains($0) }) { x.formUnion(g.members) }
            for a in ac { if let l = a.link { if x.contains(a.id) { x.insert(l) } } }
            for a in ac { if let l = a.link, x.contains(l) { x.insert(a.id) } }
            if x != selection { selection = x }
        }
    }
    var noReconcile = false                       // one edit that sets a linked sound's place itself (Put back in sync)
    public var pickSingle = false                 // set while ⌥-clicking one item inside a group
    @Published public var tool = "select"          // select | blade | zoom (Final Cut A / B / Z)
    @Published public var hint = ""
    @Published public var fitTick = 0             // bump to fit the timeline
    public var zoomDebug = ""
    public var timelineFrame = CGRect.zero        // testing aid: timeline area in window points
    public var uiScroll: (@MainActor (CGPoint, Double, [String]) -> Bool)?
    public var uiKey: (@MainActor (String, [String]) -> Bool)?                 // what the hovered button does
    @Published public var skimming = true           // preview the frame under the mouse (Final Cut S)
    @Published public var magnetic = true           // primary storyline closes gaps / ripples, like Final Cut
    @Published public var snapping = true           // dragged edges stick to nearby edges and the playhead
    public var overlayPreview: Overlay? { get { dragPreview.overlay } set { dragPreview.overlay = newValue } }
    /// zoom and scroll live in their own object: scrolling redraws only the timeline, not the whole window
    public let viewport = ViewportState()
    public var pxPerSec: Double { get { viewport.pxPerSec } set { viewport.pxPerSec = newValue; rememberView() } }   // timeline zoom
    public var scrollX: Double { get { viewport.scrollX } set { viewport.scrollX = newValue; rememberView() } }      // timeline scroll position (points)
    /// each project reopens at the zoom / scroll it was left at (never auto-fit; ⇧Z fits on request)
    var rememberPending = false
    /// the view (zoom, scroll) is saved for the project half a second after it stops changing, not on every scroll step
    func rememberView() {
        guard !restoringView, projectURL != nil, !rememberPending else { return }
        rememberPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rememberPending = false
                if let k = self.projectURL?.path { UserDefaults.standard.set([self.pxPerSec, self.scrollX], forKey: "view:" + k) }
            }
        }
    }
    var restoringView = false
    public var scrollY: Double { get { viewport.scrollY } set { viewport.scrollY = newValue } }
    public var viewportW = 1000.0, viewportH = 300.0, contentH = 300.0
    public var hoverX: Double?                      // pointer x inside the timeline view, nil when not over it
    /// any jump of the playhead (keys, keyframe buttons, markers, menus) turns the timeline page so it stays in view (Final Cut)
    public func revealPlayhead(_ t: Double) {
        let px = t * pxPerSec - scrollX
        guard viewportW > 0, px < 0 || px > viewportW - 8 else { return }
        scrollX = px < 0 ? t * pxPerSec - viewportW * 0.9 : t * pxPerSec - viewportW * 0.1
        clampScroll()
    }
    public func clampScroll() {
        let maxX = max(0, max(project.totalDuration, 1) * pxPerSec + 80 - viewportW)
        let maxY = max(0, contentH - 60)   // like Final Cut: the tracks can be scrolled up until only the last row is left
        if scrollX < 0 || scrollX > maxX { scrollX = min(max(scrollX, 0), maxX) }
        if scrollY < 0 || scrollY > maxY { scrollY = min(max(scrollY, 0), maxY) }
    }
    /// mouse-wheel notches glide to where they point instead of jumping (trackpads already move smoothly and use scrollBy)
    public var glideTarget: (x: Double, y: Double)?
    var glideTimer: Timer?
    public func glideBy(_ dx: Double, _ dy: Double) {
        let base = glideTarget ?? (scrollX, scrollY)
        glideTarget = (max(0, base.x + dx), max(0, base.y + dy))
        guard glideTimer == nil else { return }
        glideTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] tm in
            MainActor.assumeIsolated {
                guard let self, let g = self.glideTarget else { tm.invalidate(); self?.glideTimer = nil; return }
                let ex = g.x - self.scrollX, ey = g.y - self.scrollY
                if abs(ex) < 0.5 && abs(ey) < 0.5 {
                    self.scrollBy(ex, ey); self.glideTarget = nil; tm.invalidate(); self.glideTimer = nil; return
                }
                let before = (self.scrollX, self.scrollY)
                self.scrollBy(ex * 0.28, ey * 0.28)      // ease out: a fraction of what is left, every frame
                if before == (self.scrollX, self.scrollY) { self.glideTarget = nil; tm.invalidate(); self.glideTimer = nil }   // reached an edge
            }
        }
    }
    public func scrollBy(_ dx: Double, _ dy: Double) {
        scrollX += dx; scrollY += dy; clampScroll()
        // the skimmer follows whatever is now under the pointer
        if let hx = hoverX, live.skim != nil, skimming { skim(to: max(0, min((hx + scrollX) / pxPerSec, project.totalDuration))) }
    }
    /// zoom keeping the moment under the pointer where it is (wheel, pinch, zoom tool), or the playhead where it is (keys, slider)
    public func zoom(to z: Double, atPointer: Bool = true) {
        let nz = min(max(z, 0.5), 400)
        let t: Double, vx: Double
        if atPointer, let hx = hoverX { vx = hx; t = (hx + scrollX) / pxPerSec }
        else {
            t = playhead
            let px = playhead * pxPerSec - scrollX
            vx = px >= 0 && px <= viewportW ? px : viewportW / 2          // playhead stays put on screen (centred if it was off screen)
        }
        pxPerSec = nz
        scrollX = t * nz - vx
        clampScroll()
        if let hx = hoverX, live.skim != nil, skimming { skim(to: max(0, min((hx + scrollX) / pxPerSec, project.totalDuration))) }
    }
    var zoomAnim: Timer?
    /// the same, eased over ~0.15 s (keys and buttons: no jump)
    public func smoothZoom(to z: Double, atPointer: Bool = false) {
        zoomAnim?.invalidate()
        let from = log(pxPerSec), to = log(min(max(z, 0.5), 400))
        var i = 0; let n = 9
        zoomAnim = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] tm in
            MainActor.assumeIsolated {
                guard let self else { tm.invalidate(); return }
                i += 1
                let u = Double(i) / Double(n), e = 1 - pow(1 - u, 3)
                self.zoom(to: exp(from + (to - from) * e), atPointer: atPointer)
                if i >= n { tm.invalidate() }
            }
        }
    }
    public let meter = MeterState()
    var meterHist: [(e: Double, k: Double, n: Int, p: Double, t: Double)] = []
    public func resetMeter() { let m = meter; m.update(peak: m.meterDb, rms: m.rmsDb, lufs: m.momentaryLUFS, hold: m.peakHoldDb, max: -90, over: false) }
    public func updateMeter() {
        let p = Double(AudioDebug.meter); AudioDebug.meter = 0
        let e = AudioDebug.sumSq, k = AudioDebug.kSumSq, n = AudioDebug.count
        AudioDebug.sumSq = 0; AudioDebug.kSumSq = 0; AudioDebug.count = 0
        let m = meter
        let over = m.overload || AudioDebug.overs > 0; AudioDebug.overs = 0
        guard player.rate != 0 else {
            meterHist = []
            m.update(peak: -90, rms: -90, lufs: -90, hold: -90, max: m.maxPeakDb, over: over); return
        }
        let now = CACurrentMediaTime()
        meterHist.append((e, k, n, p, now)); meterHist.removeAll { now - $0.t > 2.0 }
        func db(_ x: Double) -> Double { 20 * log10(max(x, 1e-6)) }
        let r = meterHist.filter { now - $0.t <= 0.3 }, mm = meterHist.filter { now - $0.t <= 0.4 }
        let rn = r.reduce(0) { $0 + $1.n }, mn = mm.reduce(0) { $0 + $1.n }
        let rms = rn > 0 ? 10 * log10(max(r.reduce(0) { $0 + $1.e } / Double(rn), 1e-12)) : -90
        let lufs = mn > 0 ? -0.691 + 10 * log10(max(mm.reduce(0) { $0 + $1.k } / Double(mn), 1e-12)) : -90
        let peak = db(p)
        m.update(peak: peak, rms: rms, lufs: lufs, hold: db(meterHist.map { $0.p }.max() ?? 0), max: max(m.maxPeakDb, peak), over: over)
    }
    @Published public var displayWarmth = 0.0          // on-screen window only: -10...+10, positive = warmer (more red, less blue)
    @Published public var gradeAllSameMedia = true     // grade changes apply to every clip that uses the same picture file
    var liveBase: Project?
    public var pointerImage: (@MainActor (String) -> Bool)?
    /// testing aids: open a window by name (export, new, browser, versions, shortcuts, settings) / picture of the front window or sheet
    public var uiOpen: ((String) -> Bool)?
    public var uiPNG: ((String) -> Bool)?
    public var uiWindowID: (() -> Int)?
    public var uiSize: ((Double, Double) -> Bool)?
    public var uiSplit: ((Double) -> Bool)?
    public var uiMouse: (@MainActor ([CGPoint], [String]) -> Bool)?   // set by the app: sends mouse events to its own window (testing)
    public var snapshotUI: (@MainActor (String, String) -> Bool)?     // set by the app: renders its own interface to a PNG
    var refreshing = false, refreshDirty = false
    /// what is being dragged, as it looks mid-drag: watched by the timeline only (a drag no longer redraws the whole window)
    public let dragPreview = DragPreview()
    public var preview: Clip? { get { dragPreview.clip } set { dragPreview.clip = newValue } }
    public var mediaDuration: [String: Double] = [:]
    var durByPath: [String: Double] = [:]
    var noFormat: Set<String> = []
    /// picture size and frame rate of each media file in the project (asset id), for the frame-rate badge and "Match this clip"
    @Published public var assetFormat: [String: MediaFormat] = [:]
    /// the first clip went into an empty project with a different format: the window offers to match it
    @Published public var offerMatch: MediaFormat?
    var cutAllTimes: [Double] = []      // where ⇧B cut through every track (deleting a V1 piece between two of these deletes that span everywhere)
    // clipboard for ⌘C / ⌘X / ⌘V (times are relative to the earliest copied item)
    public var clipboard: (clips: [Clip], overlays: [Overlay], audio: [AudioClip], start: Double)?
    /// the clip whose look was copied last (⌘C), for Paste Attributes (⇧⌘V)
    public var attrClip: Clip?
    public var dragSession: (mode: DragMode?, clip: String?)?
    public var frameLength: Double { frame }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public let player = AVPlayer()
    @Published public private(set) var projectURL: URL?
    var built: Built?
    public var playerOutput: AVPlayerItemVideoOutput?
    var undoStack: [Project] = []
    var redoStack: [Project] = []

    var changeWatch: AnyCancellable?
    public init() {
        // CUTGENIE_CHANGES=file: log who makes the whole window redraw (debugging playback CPU)
        if let path = ProcessInfo.processInfo.environment["CUTGENIE_CHANGES"] {
            changeWatch = objectWillChange.sink { _ in
                let st = Thread.callStackSymbols.prefix(8).joined(separator: " | ")
                if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write((st + "\n").data(using: .utf8)!); h.closeFile() }
            }
        }
    }

    public var base: URL? { projectURL?.deletingLastPathComponent() }

    // MARK: never save over someone else's changes
    // Each window remembers the file's last-changed time when it opened / saved it, and leaves a small ".lock" note
    // beside the file saying which Cutgenie has it open. A save never replaces a file that changed since (another window,
    // a test copy, a script...) or that another running Cutgenie has open: it goes to a copy next to it instead.
    var diskStamp: Date?
    var lockURL: URL?
    public private(set) var openElsewhere = false
    static func mtime(_ u: URL) -> Date? { (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }
    static func lockFile(_ u: URL) -> URL { u.deletingLastPathComponent().appendingPathComponent("." + u.lastPathComponent + ".lock") }
    /// another running Cutgenie holds this file
    static func heldElsewhere(_ u: URL) -> Bool {
        guard let s = try? String(contentsOf: lockFile(u), encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid != getpid() else { return false }
        return kill(pid, 0) == 0
    }
    func takeLock(_ u: URL) {
        releaseLock()
        openElsewhere = Self.heldElsewhere(u)
        if !openElsewhere { try? "\(getpid())".write(to: Self.lockFile(u), atomically: true, encoding: .utf8); lockURL = Self.lockFile(u) }
    }
    public func releaseLock() {
        if let l = lockURL, let s = try? String(contentsOf: l, encoding: .utf8), Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) == getpid() {
            try? FileManager.default.removeItem(at: l)
        }
        lockURL = nil
    }
    /// where a save of this project may go: the file itself, or a copy beside it when that would lose other changes
    func safeSaveURL(_ dest: URL) -> (URL, String?) {
        let same = dest.standardizedFileURL == projectURL?.standardizedFileURL
        let changed = same && FileManager.default.fileExists(atPath: dest.path) && diskStamp != nil && Self.mtime(dest) != diskStamp
        guard same, changed || openElsewhere || Self.heldElsewhere(dest) else { return (dest, nil) }
        let f = DateFormatter(); f.dateFormat = "HH-mm"
        let stem = dest.deletingPathExtension().deletingPathExtension().lastPathComponent
        let copy = dest.deletingLastPathComponent().appendingPathComponent("\(stem) (copy \(f.string(from: Date()))).cutgenie.json")
        let why = changed ? "the file was changed somewhere else since this window opened it" : "the project is open in another Cutgenie window"
        return (copy, why)
    }

    // MARK: autosave / recovery
    /// the project as last opened or saved; anything different is unsaved work
    var savedProject: Project?
    var autosaveTimer: Timer?
    /// set when a newer unsaved version of this project was found (from a crash or a quit without saving)
    @Published public var recoveryOffer: Date?
    /// earlier saved versions of this project (newest first)
    public func versionFiles() -> [URL] {
        guard let u = projectURL else { return [] }
        let d = Versions.folder(u)
        return ((try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasSuffix(".cutgenie.json") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    /// media files the project uses: (asset id, where the file is, does it exist)
    public func mediaFiles() -> [(id: String, url: URL, exists: Bool)] {
        project.assets.compactMap { a in project.resolve(a.id, base: base).map { (a.id, $0, FileManager.default.fileExists(atPath: $0.path)) } }
    }
    /// unsaved work waiting in Recovery: (project path, when)
    public static func recoveryItems() -> [(path: String, time: Date)] { Recovery.all() }
    public var hasUnsavedChanges: Bool { projectURL != nil && savedProject != nil && project != savedProject }
    func startAutosave() {
        guard autosaveTimer == nil else { return }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.autosave() } }
        RunLoop.main.add(t, forMode: .common); autosaveTimer = t
    }
    public func autosave() {
        guard let u = projectURL, hasUnsavedChanges else { return }
        Recovery.save(project, for: u.path)
    }

    private var opening = false
    public func open(_ path: String) async throws {
        // one open at a time: a second click while a project is still loading waits for it instead of mixing the two
        var waited = 0
        while opening && waited < 600 { try? await Task.sleep(nanoseconds: 50_000_000); waited += 1 }
        opening = true
        defer { opening = false }
        autosave()        // the project being left keeps its unsaved work in Recovery
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        project = try Project.load(from: url)
        diskStamp = Self.mtime(url)
        takeLock(url)
        if openElsewhere { lastMessage = "\(url.lastPathComponent) is also open in another Cutgenie window - your saves here will go to a copy, nothing gets overwritten" }
        project.liftBackgroundLanes()
        cutAllTimes = []
        // connect graphics that have no parent clip to the main-storyline clip under their start
        if var ov = project.overlays {
            for k in ov.indices where ov[k].connectedTo == nil {
                ov[k].connectedTo = project.clips.first { ov[k].offset >= $0.offset - 0.001 && ov[k].offset < $0.offset + $0.duration }?.id
            }
            project.overlays = ov
        }
        projectURL = url
        if let v = UserDefaults.standard.array(forKey: "view:" + url.path) as? [Double], v.count == 2 {
            restoringView = true; pxPerSec = v[0]; scrollX = v[1]; restoringView = false
        }
        undoStack = []; redoStack = []
        // nothing from the previous project stays selected (the panels would look for clips that are not here)
        selection = []; selectedClip = nil; selectedOverlay = nil; selectedMarker = nil; liveBase = nil; liveOv = nil; liveUp = nil; liveV1 = nil
        savedProject = project
        recoveryOffer = nil
        if let (rp, when) = Recovery.load(for: url.path) {
            if rp != project, when > (diskStamp ?? .distantPast) { recoveryOffer = when } else { Recovery.clear(for: url.path) }
        }
        startAutosave()
        Log.write("opened \(url.path) (\(project.clips.count) clips)")
        if ProcessInfo.processInfo.environment["CUTGENIE_PORT"].map({ $0 == "7878" }) ?? true { UserDefaults.standard.set(url.path, forKey: "lastProject") }
        try await rebuild(keepTime: false)
    }
    /// put back the unsaved work found on open (one undo step, so it can be taken back)
    public func restoreRecovery() async {
        guard let u = projectURL, let (rp, _) = Recovery.load(for: u.path) else { recoveryOffer = nil; return }
        undoStack.append(project); redoStack = []
        project = rp; recoveryOffer = nil
        try? await rebuild(keepTime: true)
        Log.write("restored unsaved changes for \(u.path)")
    }
    public func discardRecovery() {
        if let u = projectURL { Recovery.clear(for: u.path) }
        recoveryOffer = nil
    }

    /// Space pressed but the playhead does not move: rebuild the player where it was and start again (once per press)
    func watchPlayback() {
        let t0 = player.currentTime().seconds
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard player.rate != 0, abs(player.currentTime().seconds - t0) < 0.01, t0 < (built?.duration ?? 0) - 0.1 else { return }
            let at = (project.clips + (project.upperClips ?? [])).filter { t0 >= $0.offset && t0 < $0.offset + $0.duration }
                .map { c in "\(c.id) \(project.assets.first { $0.id == c.asset }.map { ($0.path as NSString).lastPathComponent } ?? c.asset)" }
            Log.write(String(format: "playback stuck at %.3f s in %@; clips there: %@", t0, projectURL?.lastPathComponent ?? "?", at.joined(separator: ", ")))
            lastMessage = "Playback got stuck - restarted the player"
            try? await rebuild(keepTime: true)
            player.rate = Float(playSpeed)
        }
    }
    /// true while the player item is being replaced (its time is not meaningful)
    public var swapping = false
    func rebuild(keepTime: Bool = true) async throws {
        let tStart = CACurrentMediaTime()
        let t = player.currentTime()
        var md: [String: Double] = [:]      // only files not measured before are opened (the rest are remembered by path)
        for a in project.assets {
            guard let u = project.resolve(a.id, base: base) else { continue }
            if let d = durByPath[u.path] { md[a.id] = d; continue }
            if let d = try? await MediaCache.asset(u)?.load(.duration).seconds { md[a.id] = d; durByPath[u.path] = d }
        }
        if md != mediaDuration { mediaDuration = md }
        // remembered per file path: another project may use the same short id ("a1") for a different file
        var af = assetFormat.filter { k, _ in project.assets.contains { $0.id == k } }
        for a in project.assets {
            guard let u = project.resolve(a.id, base: base) else { af[a.id] = nil; continue }
            if af[a.id]?.path == u.path { continue }
            af[a.id] = nil
            // files without a picture (sound, LUTs) are tried once per path, not on every edit
            guard !noFormat.contains(u.path) else { continue }
            if var f = await MediaFormat.read(u) { f.path = u.path; af[a.id] = f } else { noFormat.insert(u.path) }
        }
        if af != assetFormat { assetFormat = af }
        let t0 = CACurrentMediaTime()
        if let log = ProcessInfo.processInfo.environment["CUTGENIE_TIMING"], let h = FileHandle(forWritingAtPath: log) {
            h.seekToEndOfFile(); h.write(String(format: "before build %.0f ms\n", (t0 - tStart) * 1000).data(using: .utf8)!); h.closeFile()
        }
        let b = try await Renderer.build(project, base: base, scale: playbackScale)
        let t1 = CACurrentMediaTime()
        built = b
        let item = AVPlayerItem(asset: b.composition)
        item.audioTimePitchAlgorithm = .spectral      // natural pitch at 1.5x / 2x playback and in speed-changed clips
        item.videoComposition = b.videoComposition
        item.audioMix = b.audioMix
        let vo = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(vo); playerOutput = vo
        // while the new item is swapped in, the player briefly reports time 0: the playhead and the
        // timeline's page-follow must not jump to the start and back (that was the flicker on every rebuild)
        if keepTime { swapping = true }
        player.replaceCurrentItem(with: item)
        let t2 = CACurrentMediaTime()
        if keepTime { await player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero); swapping = false }
        revision += 1
        if let log = ProcessInfo.processInfo.environment["CUTGENIE_TIMING"] {
            let line = String(format: "build %.0f ms, item %.0f ms, seek %.0f ms\n", (t1 - t0) * 1000, (t2 - t1) * 1000, (CACurrentMediaTime() - t2) * 1000)
            if let h = FileHandle(forWritingAtPath: log) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
            else { try? line.write(toFile: log, atomically: true, encoding: .utf8) }
        }
    }

    // Exact frame rate (23.976 is really 24000/1001); every edit time is snapped to this frame grid.
    public var exactFPS: Double {
        let f = project.settings.fps
        for (a, b) in [(23.976, 24000.0/1001), (29.97, 30000.0/1001), (59.94, 60000.0/1001)] where abs(f - a) < 0.01 { return b }
        return f
    }
    func snap(_ t: Double) -> Double { (t * exactFPS).rounded() / exactFPS }
    nonisolated public static func exact(_ f: Double) -> Double {
        for (a, b) in [(23.976, 24000.0/1001), (29.97, 30000.0/1001), (59.94, 60000.0/1001)] where abs(f - a) < 0.01 { return b }
        return f
    }
    nonisolated public static func fpsName(_ f: Double) -> String {
        for (a, n) in [(23.976, "23.98"), (29.97, "29.97"), (59.94, "59.94")] where abs(f - a) < 0.01 { return n }
        return abs(f - f.rounded()) < 0.01 ? String(Int(f.rounded())) : String(format: "%.2f", f)
    }
    var frame: Double { 1 / exactFPS }

    func validate(_ p: Project) throws {
        let cs = p.clips.sorted { $0.offset < $1.offset }
        for c in cs where c.duration < frame * 0.5 { throw RenderError.message("clip \(c.id) would be shorter than one frame") }
        for c in cs where (c.audioSource?.sourceIn ?? 0) < -1e-6 { throw RenderError.message("clip \(c.id) would start before the start of its audio file") }
        for c in cs where c.sourceIn < -1e-6 { throw RenderError.message("clip \(c.id) would start before the start of its media") }
        for (a, b) in zip(cs, cs.dropFirst()) where b.offset < a.offset + a.duration - frame * 0.25 {
            throw RenderError.message("clips \(a.id) and \(b.id) would overlap (one video track)")
        }
    }

    /// What a drag would produce right now (used by the mouse for live preview and by `drag_edit`).
    public func dragResult(_ mode: DragMode, clip id: String, delta: Double, magnetRange: Double) -> Clip? {
        guard let c = project.clips.first(where: { $0.id == id }) else { return nil }
        if magnetic {
            // magnetic timeline: the clip follows the pointer freely (neighbours make room when it is dropped)
            if mode == .move { var m = c; m.offset = max(0, (( c.offset + delta) * exactFPS).rounded() / exactFPS); return m }
            return isolated(mode, c, delta: delta, magnetRange: magnetRange)
        }
        let magnets = snapPoints(excluding: [id])
        return TimelineEdit.apply(mode, clip: c, delta: delta, clips: project.clips, mediaDuration: mediaDuration[c.asset], audioMediaDuration: c.audioSource.flatMap { mediaDuration[$0.asset] },
                                  fps: exactFPS, magnets: magnets, magnetRange: magnetRange)
    }

    // MARK: live colour grading (no rebuild while a slider/wheel is being dragged)

    /// Clips the Color inspector edits: the selected clip (or the first one), plus every clip with the same picture file if requested.
    /// the Input LUT (camera conversion) the project already uses for footage of this kind, most used first
    func inputLUT(forHDR h: String) -> LUTSlot? {
        var count: [String: (Int, LUTSlot)] = [:]
        for cl in project.clips + (project.upperClips ?? []) where assetFormat[cl.asset]?.hdr == h {
            if let l = cl.color.luts?.first(where: { $0.slot == "input" }) { count[l.asset, default: (0, l)].0 += 1 }
        }
        return count.values.max { $0.0 < $1.0 }?.1
    }
    /// the clip the Color inspector shows (any video track)
    public var gradeClipID: String? { gradeTargets.first.flatMap { project.gradeClip($0)?.id } }
    /// colour targets are numbered: 0, 1, 2... = V1 clips; -1, -2... = clips on V2+ (upperClips[-1 - n]); see Project.gradeClip
    /// the clip whose values the colour panel shows (the first of gradeTargets, without listing all the others)
    public var gradePrimary: Int? {
        let picked = selection.sorted().first { project.gradeIndex(of: $0) != nil }
        let sel = (selectedClip.map { selection.contains($0) } ?? false) ? selectedClip : (picked ?? selectedClip)
        return sel.flatMap({ project.gradeIndex(of: $0) }) ?? (project.clips.isEmpty ? nil : 0)
    }
    public var gradeTargets: [Int] {
        // the video clip you clicked (any track) - the selection wins over an older "current clip"
        guard let i = gradePrimary else { return [] }
        guard gradeAllSameMedia, let a = project.gradeClip(i)?.asset else { return [i] }
        return [i] + project.gradeIndices.filter { $0 != i && project.gradeClip($0)?.asset == a }   // the clicked clip first: the panel shows its values
    }

    /// Changes the colour of `targets` right now. Undo is recorded when `commitLive()` is called (one step per drag).
    public func liveColor(_ targets: [Int], _ f: (inout ColorParams) -> Void) {
        if liveBase == nil { liveBase = project }
        for i in targets { project.editColor(i, f) }
        if let b = built {
            for i in targets {
                guard let c = project.gradeClip(i) else { continue }
                do {
                    let l = try Renderer.loadLUTs(c.color, project: project, base: base, clip: c.id)
                    if i <= Project.adjBase { if let o = project.overlays?.first(where: { $0.id == c.id }) { b.adjStore.set(o, luts: l) } }
                    else if i >= 0 { b.store.set(c.id, color: c.color, luts: l) } else { b.upperStore.set(c.id, color: c.color, luts: l) }
                } catch { lastMessage = "colour: \(error)" }
            }
        }
        refreshFrame()
    }

    // MARK: graphic layers (Effects panel): live while dragging, one undo step per drag (commitLive)
    /// working copy while dragging: the picture uses it at once; the timeline / panel get it at most every 50 ms (smooth drags)
    var liveOv: [Overlay]?
    public let drag = DragState()
    var livePublishPending = false
    public func liveLayers(_ ids: [String], _ f: (inout Overlay) -> Void) {
        guard var ov = liveOv ?? project.overlays else { return }
        if liveBase == nil { liveBase = project }
        for k in ov.indices where ids.contains(ov[k].id) && lockedTrack(of: ov[k].id) == nil { f(&ov[k]); built?.overlayStore.update(ov[k]) }
        liveOv = ov
        refreshFrame()
        drag.tick &+= 1          // only the viewer handles + Effects panel follow every move; the timeline catches up on release
    }
    /// value of a layer as it is right now (including a drag in progress)
    public func liveLayer(_ id: String) -> Overlay? { (liveOv ?? project.overlays)?.first { $0.id == id } }
    /// keyframe lists by name
    public static func keys(_ o: Overlay, _ prop: String) -> [Keyframe] {
        switch prop { case "position": return o.position; case "scale": return o.scale; case "opacity": return o.opacity; default: return o.rotation ?? [] }
    }
    public static func setKeys(_ o: inout Overlay, _ prop: String, _ k: [Keyframe]) {
        switch prop { case "position": o.position = k; case "scale": o.scale = k; case "opacity": o.opacity = k; default: o.rotation = k.isEmpty ? nil : k }
    }
    public static let defaults: [String: [Double]] = ["position": [0, 0], "scale": [1, 1], "opacity": [1], "rotation": [0]]
    public func layerValue(_ o: Overlay, _ prop: String, at t: Double) -> [Double] {
        KF.at(Editor.keys(o, prop), t - o.offset, Editor.defaults[prop]!)
    }
    /// set a property at timeline time t: not animated -> the one value; animated (2+ keyframes) -> keyframe at t (added or updated)
    public func setLayerValue(_ ids: [String], _ prop: String, _ v: [Double], at t: Double) {
        liveLayers(ids) { o in
            var k = Editor.keys(o, prop)
            let local = max(0, min(o.duration, t - o.offset))
            if k.count <= 1 { k = [Keyframe(t: 0, v: v)] }
            else if let i = k.firstIndex(where: { abs($0.t - local) < self.frame * 0.5 }) { k[i].v = v }
            else { k.append(Keyframe(t: local, v: v)); k.sort { $0.t < $1.t } }
            Editor.setKeys(&o, prop, k)
        }
    }
    /// keyframe button: add a keyframe at t (with the current value), or remove the one there
    public func toggleLayerKey(_ ids: [String], _ prop: String, at t: Double) {
        liveLayers(ids) { o in
            var k = Editor.keys(o, prop)
            let local = max(0, min(o.duration, t - o.offset))
            if let i = k.firstIndex(where: { abs($0.t - local) < self.frame * 0.5 }), k.count >= 2 { k.remove(at: i) }
            else {
                let cur = KF.at(k, local, Editor.defaults[prop]!)
                if k.count == 1 && abs(k[0].t - local) >= self.frame * 0.5 { k = [Keyframe(t: k[0].t, v: k[0].v)] }   // the old single value becomes a keyframe
                if k.isEmpty { k = [Keyframe(t: 0, v: cur)] }
                if !k.contains(where: { abs($0.t - local) < self.frame * 0.5 }) { k.append(Keyframe(t: local, v: cur)) }
                k.sort { $0.t < $1.t }
            }
            Editor.setKeys(&o, prop, k)
        }
        commitLive()
    }
    public var layerClipboard: Overlay?
    @Published public var playSpeed: Double = UserDefaults.standard.object(forKey: "playSpeed") as? Double ?? 1
    /// V2+ video clips: picture-in-picture edits, live (one undo step per drag via commitLive)
    var liveUp: [Clip]?
    var liveV1: [Clip]?
    /// V1 zoom (Clip.zoom keyframes, scale about the zoom anchor) changed live; the player is rebuilt on commit
    public func liveZoom(_ id: String, _ f: (inout [Keyframe]) -> Void) {
        if liveBase == nil { liveBase = project }
        var v1 = liveV1 ?? project.clips
        guard let k = v1.firstIndex(where: { $0.id == id }), lockedTrack(of: id) == nil else { return }
        var z = v1[k].zoom ?? []; f(&z); v1[k].zoom = z.isEmpty ? nil : z.sorted { $0.t < $1.t }
        liveV1 = v1
        built?.store.setZoom(id, v1[k].zoom ?? [])
        refreshFrame()
        drag.tick &+= 1
    }
    /// V1 slide aside (docked side panels): position keyframes in Final Cut units, separate from Transform
    public func liveMotion(_ id: String, _ f: (inout [Keyframe]) -> Void) {
        if liveBase == nil { liveBase = project }
        var v1 = liveV1 ?? project.clips
        guard let k = v1.firstIndex(where: { $0.id == id }), lockedTrack(of: id) == nil else { return }
        var m = v1[k].motion ?? []; f(&m); v1[k].motion = m.isEmpty ? nil : m.sorted { $0.t < $1.t }
        liveV1 = v1
        built?.store.setMotion(id, v1[k].motion ?? [])
        refreshFrame()
        drag.tick &+= 1
    }
    public func setClipMotion(_ id: String, _ index: Int, _ v: Double, at t: Double) {
        guard let c = liveUpperClip(id) else { return }
        let local = snap(t) - c.offset
        liveMotion(id) { m in
            var cur = KF.at(m, local, [0, 0]); cur[index] = v
            if m.isEmpty { m = [Keyframe(t: local, v: cur)]; return }
            if let i = m.firstIndex(where: { abs($0.t - local) < self.frame * 0.5 }) { m[i].v = cur }
            else if m.count == 1 { m[0].v = cur }
            else { m.append(Keyframe(t: local, v: cur)) }
        }
    }
    public func toggleMotionKey(_ id: String, at t: Double) {
        guard let c = liveUpperClip(id) else { return }
        let local = snap(t) - c.offset
        liveMotion(id) { m in
            if let i = m.firstIndex(where: { abs($0.t - local) < self.frame * 0.5 }) { m.remove(at: i) }
            else { m.append(Keyframe(t: local, v: KF.at(m, local, [0, 0]))) }
        }
        commitLive()
    }
    public func setClipZoom(_ id: String, _ v: Double, at t: Double) {
        guard let c = liveUpperClip(id) else { return }
        let local = snap(t) - c.offset
        liveZoom(id) { z in
            if z.isEmpty { z = [Keyframe(t: local, v: [v])]; return }
            if let i = z.firstIndex(where: { abs($0.t - local) < self.frame * 0.5 }) { z[i].v = [v] }
            else if z.count == 1 { z[0].v = [v] }        // one keyframe = a fixed zoom: change it
            else { z.append(Keyframe(t: local, v: [v])) }
        }
    }
    public func toggleZoomKey(_ id: String, at t: Double) {
        guard let c = liveUpperClip(id) else { return }
        let local = snap(t) - c.offset
        liveZoom(id) { z in
            if let i = z.firstIndex(where: { abs($0.t - local) < self.frame * 0.5 }) { z.remove(at: i) }
            else { z.append(Keyframe(t: local, v: [KF.at(z, local, [1])[0]])) }
        }
        commitLive()
    }
    public func setZoomEase(_ id: String, at t: Double, _ e: String) {
        guard let c = liveUpperClip(id) else { return }
        let local = snap(t) - c.offset
        liveZoom(id) { z in if let i = z.firstIndex(where: { abs($0.t - local) < self.frame * 0.5 }) { z[i].e = e == "linear" ? nil : e } }
        commitLive()
    }
    public func liveUpper(_ ids: [String], _ f: (inout ClipXf) -> Void) {
        if liveBase == nil { liveBase = project }
        // V1 clips get the same transform (crop / position / scale / shadow...)
        var v1 = liveV1 ?? project.clips
        if v1.contains(where: { ids.contains($0.id) }) {
            for k in v1.indices where ids.contains(v1[k].id) && lockedTrack(of: v1[k].id) == nil {
                var x = v1[k].xf ?? ClipXf(); f(&x); v1[k].xf = x.isIdentity ? nil : x; built?.upperXf.set(v1[k].id, v1[k].xf)
            }
            liveV1 = v1
        }
        guard var up = liveUp ?? project.upperClips else { refreshFrame(); drag.tick &+= 1; return }
        for k in up.indices where ids.contains(up[k].id) && lockedTrack(of: up[k].id) == nil {
            var x = up[k].xf ?? ClipXf(); f(&x); up[k].xf = x.isIdentity ? nil : x; built?.upperXf.set(up[k].id, up[k].xf)
        }
        liveUp = up
        refreshFrame()
        drag.tick &+= 1
    }
    /// set a clip transform property at the playhead: a keyframe there when the property is animated, else its fixed value
    public func setClipXf(_ ids: [String], _ p: String, _ v: [Double], at t: Double) {
        liveUpper(ids) { [self] x in
            guard var k = x.keys?[p], !k.isEmpty, let c = liveUpperClip(ids[0]) else { x.setValue(p, v); return }
            let local = snap(t) - c.offset
            if let i = k.firstIndex(where: { abs($0.t - local) < frame * 0.5 }) { k[i].v = v } else { k.append(Keyframe(t: local, v: v)); k.sort { $0.t < $1.t } }
            var ks = x.keys ?? [:]; ks[p] = k; x.keys = ks
        }
    }
    /// add a keyframe at the playhead (with the value there), or remove the one there
    public func toggleClipKey(_ ids: [String], _ p: String, at t: Double) {
        guard let c = liveUpperClip(ids[0]) else { return }
        let local = snap(t) - c.offset
        liveUpper(ids) { x in
            var ks = x.keys ?? [:]; var k = ks[p] ?? []
            let cur = x.value(p, at: local)
            if let i = k.firstIndex(where: { abs($0.t - local) < self.frame * 0.5 }) {
                k.remove(at: i)
                if k.isEmpty { x.setValue(p, cur) }        // last one gone: the property keeps that value, unanimated
            } else { k.append(Keyframe(t: local, v: cur)); k.sort { $0.t < $1.t } }
            ks[p] = k.isEmpty ? nil : k; x.keys = ks.isEmpty ? nil : ks
        }
        commitLive()
    }
    public func setClipKeyEase(_ ids: [String], _ p: String, at t: Double, _ e: String) {
        guard let c = liveUpperClip(ids[0]) else { return }
        let local = snap(t) - c.offset
        liveUpper(ids) { x in
            guard var k = x.keys?[p], let i = k.firstIndex(where: { abs($0.t - local) < self.frame * 0.5 }) else { return }
            k[i].e = e == "linear" ? nil : e; x.keys?[p] = k
        }
        commitLive()
    }
    /// every keyframe of a clip (transform, zoom, slide) at clip time `local`, or all of them when nil: set the easing into it
    public func setClipEaseAll(_ id: String, at local: Double?, _ e: String) {
        let ev: String? = e == "linear" ? nil : e
        func f(_ k: inout [Keyframe]) { for i in k.indices where i > 0 && (local == nil || abs(k[i].t - local!) < frame * 0.5) { k[i].e = ev } }
        liveUpper([id]) { x in for p in Array((x.keys ?? [:]).keys) { if var k = x.keys?[p] { f(&k); x.keys?[p] = k } } }
        if project.clips.contains(where: { $0.id == id }) { liveZoom(id) { f(&$0) }; liveMotion(id) { f(&$0) } }
        commitLive()
    }
    /// remove every keyframe of a clip at clip time `local` (transform, zoom, slide)
    public func deleteClipKeys(_ id: String, at local: Double) {
        func f(_ k: inout [Keyframe]) { k.removeAll { abs($0.t - local) < frame * 0.5 } }
        liveUpper([id]) { x in for p in Array((x.keys ?? [:]).keys) { if var k = x.keys?[p] { f(&k); x.keys?[p] = k.isEmpty ? nil : k } } }
        if project.clips.contains(where: { $0.id == id }) { liveZoom(id) { f(&$0) }; liveMotion(id) { f(&$0) } }
        commitLive()
    }
    public func liveUpperClip(_ id: String) -> Clip? { (liveUp ?? project.upperClips)?.first { $0.id == id } ?? (liveV1 ?? project.clips).first { $0.id == id } }
    /// path of a layer's image file
    public func layerPath(_ o: Overlay) -> String? { project.layerPath(o, base: base) }
    /// anchor on the visible graphic (instead of the frame centre); the layer does not move
    public func anchorOnGraphic(_ ids: [String]) {
        liveLayers(ids) { o in if let p = self.layerPath(o), let a = OverlayRender.visibleCentreOffset(path: p) { o.anchor = a } }
        commitLive()
    }
    /// easing for every keyframe of a layer (all animated properties): "linear", "in", "out", "s", "strong", "back", "bounce", "bez:..."
    public func setEase(_ ids: [String], _ e: String, commit: Bool = true) {
        liveLayers(ids) { o in
            for prop in ["position", "scale", "rotation", "opacity"] {
                // Final Cut bakes motion into a keyframe every couple of frames; an easing curve can only show between keyframes,
                // so first reduce them to the ones that shape the motion (start, stops, turns), then apply the curve
                let k = Editor.simplify(Editor.keys(o, prop), tol: ["position": 0.4, "scale": 0.01, "rotation": 0.5, "opacity": 0.02][prop]!)
                Editor.setKeys(&o, prop, k.map { var k = $0; k.e = e == "linear" ? nil : e; return k })
            }
        }
        if commit { commitLive() }
    }
    /// easing of one keyframe (the move INTO the keyframe at timeline time t) on one property; other keyframes keep theirs
    public func setKeyEase(_ ids: [String], _ prop: String, at t: Double, _ e: String) {
        liveLayers(ids) { o in
            let local = t - o.offset
            Editor.setKeys(&o, prop, Editor.keys(o, prop).map { k in
                var k = k; if abs(k.t - local) < self.frameLength * 0.5 { k.e = e }; return k })
        }
        commitLive()
    }
    /// fewest keyframes that still follow the motion within `tol` (Ramer-Douglas-Peucker on time / value); holds stay holds
    nonisolated public static func simplify(_ k: [Keyframe], tol: Double) -> [Keyframe] {
        guard k.count > 3 else { return k }
        var keep = Set([0, k.count - 1])
        func err(_ i: Int, _ a: Int, _ b: Int) -> Double {
            let u = k[b].t > k[a].t ? (k[i].t - k[a].t) / (k[b].t - k[a].t) : 0
            return zip(zip(k[a].v, k[b].v), k[i].v).map { abs($0.0 + ($0.1 - $0.0) * u - $1) }.max() ?? 0
        }
        func split(_ a: Int, _ b: Int) {
            guard b > a + 1 else { return }
            var worst = a, we = 0.0
            for i in (a + 1)..<b { let x = err(i, a, b); if x > we { we = x; worst = i } }
            if we > tol { keep.insert(worst); split(a, worst); split(worst, b) }
        }
        split(0, k.count - 1)
        // keep the first / last frame of every still stretch, so a hold is not turned into a slow drift
        for i in 1..<(k.count - 1) where k[i].v == k[i - 1].v || k[i].v == k[i + 1].v { keep.insert(i) }
        var out = keep.sorted().map { k[$0] }
        out = out.enumerated().filter { i, x in !(i > 0 && i < out.count - 1 && x.v == out[i - 1].v && x.v == out[i + 1].v) }.map { $0.1 }
        return out
    }
    /// fewest keyframes for a clip property, same shape (straight lines between kept keyframes, within `tol` of the original)
    nonisolated public static func simplifyEased(_ k0: [Keyframe], tol: Double) -> [Keyframe] {
        // easing that already exists on the kept keyframes stays; none is invented (that bent the move by up to 3 %)
        simplify(k0.sorted { $0.t < $1.t }, tol: tol)
    }
    /// easing currently used by a layer (first keyframe that has one)
    public static func ease(of o: Overlay) -> String {
        for prop in ["position", "scale", "rotation", "opacity"] { if let e = Editor.keys(o, prop).dropFirst().first(where: { $0.e != nil })?.e { return e } }
        return "linear"
    }
    // effect presets (saved for all projects)
    public struct FXPreset: Codable { public var effects: [LayerEffect]?; public var crop: [Double]?; public var blend: String?; public var fadeIn: Double?; public var fadeOut: Double?
        public var buildIn: Build?; public var buildOut: Build?; public var mask: MaskSpec?; public var behaviours: [Behaviour]? }
    public static var presetNames: [String] { (UserDefaults.standard.dictionary(forKey: "fxPresets") ?? [:]).keys.sorted() }
    public static func savePreset(_ name: String, from o: Overlay) {
        var d = UserDefaults.standard.dictionary(forKey: "fxPresets") ?? [:]
        d[name] = try? JSONEncoder().encode(FXPreset(effects: o.effects, crop: o.crop, blend: o.blend, fadeIn: o.fadeIn, fadeOut: o.fadeOut, buildIn: o.buildIn, buildOut: o.buildOut, mask: o.mask, behaviours: o.behaviours))
        UserDefaults.standard.set(d, forKey: "fxPresets")
    }
    public static func deletePreset(_ name: String) {
        var d = UserDefaults.standard.dictionary(forKey: "fxPresets") ?? [:]; d[name] = nil; UserDefaults.standard.set(d, forKey: "fxPresets")
    }
    public func applyPreset(_ name: String, to ids: [String]) {
        guard let data = (UserDefaults.standard.dictionary(forKey: "fxPresets") ?? [:])[name] as? Data, let p = try? JSONDecoder().decode(FXPreset.self, from: data) else { return }
        liveLayers(ids) { o in
            o.effects = p.effects.map { $0.map { var e = $0; e.id = UUID().uuidString; return e } }
            o.crop = p.crop; o.blend = p.blend; o.fadeIn = p.fadeIn; o.fadeOut = p.fadeOut
            o.buildIn = p.buildIn; o.buildOut = p.buildOut; o.mask = p.mask; o.behaviours = p.behaviours
        }
        commitLive()
    }

    public func commitLive() {
        if let o = liveOv { project.overlays = o; liveOv = nil }
        if let u = liveUp { project.upperClips = u; liveUp = nil }
        if let v = liveV1 { project.clips = v; liveV1 = nil }
        guard let b = liveBase else { return }
        if b != project { undoStack.append(b); redoStack = [] }
        liveBase = nil
    }

    /// Re-renders the frame on screen after a live change. Seeking to the same time is not enough (the player keeps its
    /// cached frame), so hand the player item a fresh copy of the video composition, which forces a re-render.
    public func refreshFramePublic() { refreshFrame() }
    /// set by the window: puts a finished picture on screen
    public var showFrame: (@Sendable (CVPixelBuffer) -> Void)?
    func refreshFrame() {
        // paused on the frame the compositor last made: redraw it directly (smooth, no seeking)
        if player.rate == 0, let show = showFrame, abs(LastFrame.time - player.currentTime().seconds) < frame * 0.6 {
            LastFrame.redraw(show); return
        }
        if refreshing { refreshDirty = true; return }
        refreshing = true
        Task { @MainActor in
            repeat {
                refreshDirty = false
                // step one frame away and back: forces the player to render the current frame again with the new grade
                let t = player.currentTime()
                let other = t.seconds > frame * 2 ? CMTimeSubtract(t, CMTime(seconds: frame, preferredTimescale: 6000)) : CMTimeAdd(t, CMTime(seconds: frame, preferredTimescale: 6000))
                await player.seek(to: other, toleranceBefore: .zero, toleranceAfter: .zero)
                await player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            } while refreshDirty
            refreshing = false
        }
    }

    /// Applies a colour edit to `idx`: live (no rebuild, undo on commit) or as one normal undoable step.
    func colorEdit(_ idx: [Int], live: Bool, _ f: @escaping (inout ColorParams) -> Void) async throws {
        if live { liveColor(idx, f); return }
        try await mutate { p in for i in idx { p.editColor(i, f) } }
    }

    // MARK: audio chain (live: no rebuild, audio picks up the change within one buffer)
    /// which audio track the Audio panel edits: "A1" (the main sound) or "A2", "A3"...
    @Published public var audioTrack = "A1"
    /// export in progress: 0...1, nil = none
    @Published public var exportProgress: Double?
    @Published public var exportingName: String?
    @Published public var lastExport: URL?
    let exportStop = Stop()
    public func cancelExport() { exportStop.flag = true }
    /// export from the window (the save panel already asked about replacing the file)
    /// Playback resolution of the viewer: 1 = full, 0.5 = half, 0.25 = quarter. Exports and frame renders are always full.
    @Published public var playbackScale: Double = { let v = UserDefaults.standard.double(forKey: "playbackScale"); return v > 0 ? v : 1 }() {
        didSet {
            guard playbackScale != oldValue else { return }
            UserDefaults.standard.set(playbackScale, forKey: "playbackScale")
            let playing = player.rate
            Task { try? await rebuild(keepTime: true); if playing != 0 { player.rate = playing } }
        }
    }
    /// the timeline built at full resolution (for exports), whatever the playback resolution
    func fullBuilt() async throws -> Built {
        let b = try need(built, "no project open")
        if playbackScale >= 0.999 { return b }
        return try await Renderer.build(project, base: base, scale: 1)
    }
    public func exportFile(_ out: URL, _ o: ExportOptions) async throws {
        let b = try await fullBuilt()
        exportingName = out.lastPathComponent; lastExport = nil
        defer { exportingName = nil }
        try await runExport(b, to: out, options: o, overwrite: true)
        lastExport = out
        Log.write("exported \(out.path)")
    }
    /// the one item the panels should show: a single selected item, or a clip selected together with its own linked sound
    public var primarySelection: String? {
        if selection.isEmpty { return selectedClip ?? selectedOverlay }
        if selection.count == 1 { return selection.first }
        let linkedSound = Set((project.audioClips ?? []).filter { a in selection.contains(a.id) && a.link.map { selection.contains($0) } == true }.map { $0.id })
        let rest = selection.subtracting(linkedSound)
        return rest.count == 1 ? rest.first : nil
    }
    /// start and end of the selected items (for "export selection")
    public var selectionSpan: (Double, Double)? {
        let ids = selection
        let sp = project.clips.filter { ids.contains($0.id) }.map { ($0.offset, $0.offset + $0.duration) }
            + (project.upperClips ?? []).filter { ids.contains($0.id) }.map { ($0.offset, $0.offset + $0.duration) }
            + (project.overlays ?? []).filter { ids.contains($0.id) }.map { ($0.offset, $0.offset + $0.duration) }
            + (project.audioClips ?? []).filter { ids.contains($0.id) }.map { ($0.offset, $0.offset + $0.duration) }
        guard let a = sp.map({ $0.0 }).min(), let b = sp.map({ $0.1 }).max(), b > a else { return nil }
        return (a, b)
    }
    public func runExport(_ b: Built, to out: URL, options o: ExportOptions, overwrite: Bool) async throws {
        guard exportProgress == nil else { throw RenderError.message("an export is already running") }
        exportStop.flag = false; exportProgress = 0
        defer { exportProgress = nil }
        let stop = exportStop
        var last = 0.0
        try await Renderer.export(b, to: out, options: o, overwrite: overwrite, progress: { p in
            guard p - last >= 0.005 || p >= 1 else { return }
            last = p
            Task { @MainActor [weak self] in if self?.exportProgress != nil { self?.exportProgress = p } }
        }, cancelled: { stop.flag })
    }
    /// a grade copied with Copy grade (Color panel), waiting to be pasted
    @Published public var gradeClipboard: SavedLook?
    /// bumps when saved looks / audio presets change, so menus re-read the folders
    @Published public var looksVersion = 0
    public var audioChain: AudioChain { chain(for: audioTrack) }
    public func chain(for track: String) -> AudioChain { track == "A1" ? (project.audioChain ?? AudioChain()) : (project.trackAudio?[track] ?? AudioChain()) }
    /// puts a track's effects into the project and into the playing sound at once
    func storeChain(_ c: AudioChain, track: String) {
        if track == "A1" { project.audioChain = c; built?.audioStore.set(c); return }
        var t = project.trackAudio ?? [:]; t[track] = c; project.trackAudio = t
        if let n = Int(track.dropFirst()) { built?.laneAudio[n]?.set(c) }
    }
    public func liveAudio(_ f: (inout AudioChain) -> Void) {
        if liveBase == nil { liveBase = project }
        var c = audioChain; f(&c); storeChain(c, track: audioTrack)
    }
    func audioEdit(live: Bool, _ f: (inout AudioChain) -> Void) {
        if live { liveAudio(f); return }
        let base = project
        var c = audioChain; f(&c); storeChain(c, track: audioTrack)
        if base != project { undoStack.append(base); redoStack = [] }
    }
    @Published public var lastLoudness: LoudnessResult?
    public struct LoudnessResult { public let lufs: Double; public let peakDb: Double }

    // MARK: skimming (show the frame under the mouse without moving the playhead)
    var skimBusy = false, skimPending: Double?
    public func skim(to t: Double?) {
        guard let t else {
            if live.skim != nil {
                live.skim = nil; skimPending = nil
                if player.rate != 0 { return }      // playing: the playhead owns the player, don't jump back
                let back = CMTime(seconds: playhead, preferredTimescale: 6000)
                Task { await player.seek(to: back, toleranceBefore: .zero, toleranceAfter: .zero) }
            }
            return
        }
        guard player.rate == 0 else { return }
        live.skim = t; skimPending = t; pumpSkim()
    }
    func pumpSkim() {
        guard !skimBusy, let t = skimPending else { return }
        skimBusy = true; skimPending = nil
        Task { @MainActor in
            await player.seek(to: CMTime(seconds: t, preferredTimescale: 6000), toleranceBefore: .zero, toleranceAfter: .zero)
            skimBusy = false; pumpSkim()
        }
    }

    // MARK: magnetic timeline helpers
    /// moves every graphic connected to `clip` by `d` seconds
    func shiftConnected(_ p: inout Project, clip: String, by d: Double) {
        if d != 0, var mk = p.markers { for k in mk.indices where mk[k].clip == clip { mk[k].time += d }; p.markers = mk }
        guard d != 0, var ov = p.overlays else { return }
        for k in ov.indices where ov[k].connectedTo == clip { ov[k].offset += d }
        p.overlays = ov
    }
    /// shifts everything that starts at or after `from` (clips, their graphics, loose graphics, titles), except `except`
    /// track height while dragging the line under a track name (view setting; saved with the project, not an undo step)
    public func setTrackHeight(_ name: String, _ h: Double) {
        let v = max(14, min(260, h.rounded())); guard project.trackHeights?[name] != v else { return }   // whole points, no redraw when unchanged
        var d = project.trackHeights ?? [:]; d[name] = v; project.trackHeights = d
    }
    /// sync lock: is this track following V1 ripple edits? (all tracks are, until you switch one off)
    // A LOCKED track is blocked entirely: nothing on it can be selected, moved, trimmed, cut, deleted or adjusted,
    // and V1 ripple edits leave it where it is. (Stored in project.unsynced.)
    func synced(_ p: Project, video lane: Int) -> Bool { !(p.unsynced ?? []).contains("V\(lane + 1)") }
    func synced(_ p: Project, audio lane: Int) -> Bool { !(p.unsynced ?? []).contains("A\(lane)") }
    /// tracks an item sits on (a V1 clip with its own sound is on V1 and A1)
    public func tracks(of id: String) -> [String] {
        if let c = project.clips.first(where: { $0.id == id }) { return c.audioDetached == true ? ["V1"] : ["V1", "A1"] }
        if let u = project.upperClips?.first(where: { $0.id == id }) { return ["V\((u.lane ?? 1) + 1)"] }
        if let o = project.overlays?.first(where: { $0.id == id }) { return ["V\(o.lane + 1)"] }
        if let a = project.audioClips?.first(where: { $0.id == id }) { return ["A\(a.lane)"] }
        return []
    }
    public func lockedTrack(of id: String) -> String? { tracks(of: id).first { (project.unsynced ?? []).contains($0) } }
    func refuseIfLocked(_ ids: [String]) throws {
        for id in ids { if let t = lockedTrack(of: id) { throw RenderError.message("\(t) is locked - unlock it to change it") } }
    }

    /// Magnetic delete of the V1 piece [a, b):
    /// - if both ends were ⇧B cuts through all tracks: everything between them on every track goes too;
    /// - otherwise nothing on other tracks is cut, shortened or deleted.
    /// Then everything after moves earlier by the gap (things that started inside the gap move to its start), on every track;
    /// anything that would now overlap something on its track moves up to the next free track.
    func rippleDelete(_ p: inout Project, _ a: Double, _ b: Double) {
        let e = frame * 0.5, gap = b - a
        let cutAll = cutAllTimes.contains { abs($0 - a) < e } && cutAllTimes.contains { abs($0 - b) < e }
        if cutAll {     // (never on locked tracks)
            let locked = Set(p.unsynced ?? [])
            p.overlays?.removeAll { $0.offset >= a - e && $0.offset + $0.duration <= b + e && !locked.contains("V\($0.lane + 1)") }
            p.audioClips?.removeAll { $0.offset >= a - e && $0.offset + $0.duration <= b + e && !locked.contains("A\($0.lane)") }
            p.upperClips?.removeAll { $0.offset >= a - e && $0.offset + $0.duration <= b + e && !locked.contains("V\(($0.lane ?? 1) + 1)") }
        }
        // option 3: whole clips only, never cut. Decided by where each clip on another track starts:
        // after the piece -> earlier by the gap; inside it -> to where it began; before it but running across it -> earlier by the gap too.
        // Clips that end before the piece, and tracks with sync lock off, stay where they are.
        func shift(_ off: Double, _ dur: Double) -> Double {
            if off >= b - e { return -gap }
            if off >= a - e { return -(off - a) }
            if off + dur > a + e { return -min(gap, off) }
            return 0
        }
        var movedV = Set<String>(), movedA = Set<String>()
        for k in p.clips.indices where p.clips[k].offset >= b - e { p.clips[k].offset -= gap }
        if var ov = p.overlays { for k in ov.indices where synced(p, video: ov[k].lane) { let d = shift(ov[k].offset, ov[k].duration); if d != 0 { ov[k].offset += d; movedV.insert(ov[k].id) } }; p.overlays = ov }
        if var up = p.upperClips { for k in up.indices where synced(p, video: up[k].lane ?? 1) { let d = shift(up[k].offset, up[k].duration); if d != 0 { up[k].offset += d; movedV.insert(up[k].id) } }; p.upperClips = up }
        if var ac = p.audioClips { for k in ac.indices where synced(p, audio: ac[k].lane) { let d = shift(ac[k].offset, ac[k].duration); if d != 0 { ac[k].offset += d; movedA.insert(ac[k].id) } }; p.audioClips = ac }
        for k in p.titles.indices { p.titles[k].at += shift(p.titles[k].at, p.titles[k].duration) }
        if var mk = p.markers { for k in mk.indices { mk[k].time += shift(mk[k].time, 0) }; p.markers = mk }
        // overlaps after the move: the moved item goes up a track until it fits (video V2+ / audio A2+)
        func hit(_ o1: Double, _ d1: Double, _ o2: Double, _ d2: Double) -> Bool { o1 < o2 + d2 - 0.001 && o2 < o1 + d1 - 0.001 }
        var vids: [(id: String, lane: Int, off: Double, dur: Double, up: Bool)] =
            (p.overlays ?? []).map { ($0.id, $0.lane, $0.offset, $0.duration, false) } + (p.upperClips ?? []).map { ($0.id, $0.lane ?? 1, $0.offset, $0.duration, true) }
        for i in vids.indices.sorted(by: { vids[$0].off < vids[$1].off }) where movedV.contains(vids[i].id) {
            while vids.indices.contains(where: { $0 != i && vids[$0].lane == vids[i].lane && hit(vids[$0].off, vids[$0].dur, vids[i].off, vids[i].dur) }) { vids[i].lane += 1 }
        }
        if var ov = p.overlays { for k in ov.indices { if let v = vids.first(where: { $0.id == ov[k].id && !$0.up }) { ov[k].lane = v.lane } }; p.overlays = ov }
        if var up = p.upperClips { for k in up.indices { if let v = vids.first(where: { $0.id == up[k].id && $0.up }) { up[k].lane = v.lane } }; p.upperClips = up }
        p.gfxLanes = max(p.gfxLanes ?? 0, vids.map { $0.lane }.max() ?? 0)
        if var ac = p.audioClips {
            for k in ac.indices.sorted(by: { ac[$0].offset < ac[$1].offset }) where movedA.contains(ac[k].id) {
                func busy() -> Bool {
                    ac.indices.contains { $0 != k && ac[$0].lane == ac[k].lane && hit(ac[$0].offset, ac[$0].duration, ac[k].offset, ac[k].duration) }
                    || (ac[k].lane == 1 && p.clips.contains { $0.audioDetached != true && hit($0.offset, $0.duration, ac[k].offset, ac[k].duration) })
                }
                while busy() { ac[k].lane += 1 }
            }
            p.audioClips = ac
            p.audioLanes = max(p.audioLanes ?? 0, (ac.map { $0.lane }.max() ?? 1) - 1)
        }
    }

    /// Removes the time range [a, b) from every layer, sound clip and V2+ clip that only partly overlaps it
    /// (head, tail or middle cut away), so after the ripple nothing hangs over the clip before the gap.
    func cutRange(_ p: inout Project, _ a: Double, _ b: Double) {
        let e = frame * 0.25
        func part(_ off: Double, _ dur: Double) -> (head: Double, tail: Double)? {   // seconds cut at the start / at the end of the item
            let end = off + dur
            guard off < b - e, end > a + e, !(off >= a - e && end <= b + e) else { return nil }
            if off >= a - e { return (b - off, 0) }           // starts inside: lose the head
            if end <= b + e { return (0, end - a) }           // ends inside: lose the tail
            return (0, b - a)                                  // spans it: lose the middle (shorter by the gap)
        }
        if var ov = p.overlays {
            for k in ov.indices { if let c = part(ov[k].offset, ov[k].duration) {
                if c.head > 0 { let h = c.head; ov[k].offset += h; ov[k].duration -= h
                    ov[k].position = ov[k].position.map { Keyframe(t: $0.t - h, v: $0.v) }; ov[k].scale = ov[k].scale.map { Keyframe(t: $0.t - h, v: $0.v) }
                    ov[k].opacity = ov[k].opacity.map { Keyframe(t: $0.t - h, v: $0.v) } }
                ov[k].duration -= c.tail
            } }
            p.overlays = ov
        }
        if var ac = p.audioClips {
            for k in ac.indices { if let c = part(ac[k].offset, ac[k].duration) {
                if c.head > 0 { ac[k].offset += c.head; ac[k].sourceIn += c.head; ac[k].duration -= c.head; ac[k].keys = ac[k].keys?.map { VolKey(t: $0.t - c.head, db: $0.db) } }
                ac[k].duration -= c.tail
            } }
            p.audioClips = ac
        }
        if var up = p.upperClips {
            for k in up.indices { if let c = part(up[k].offset, up[k].duration) {
                if c.head > 0 { let sh = c.head * up[k].sp; up[k].offset += c.head; up[k].sourceIn += sh; up[k].audioSource?.sourceIn += sh; up[k].duration -= c.head }
                up[k].duration -= c.tail
            } }
            p.upperClips = up
        }
    }

    /// Ripple: everything that starts at/after `from` moves by d, on EVERY track (V1, V2+, layers, sound clips, titles, markers),
    /// plus anything attached to a clip that moved. Nothing after the point is left behind to overlap earlier clips.
    func rippleAfter(_ p: inout Project, from: Double, by d: Double, except: String?) {
        guard d != 0 else { return }
        let eps = frame * 0.25
        var moved = Set<String>()
        for k in p.clips.indices where p.clips[k].id != except && p.clips[k].offset >= from - eps { p.clips[k].offset += d; moved.insert(p.clips[k].id) }
        if var up = p.upperClips {
            for k in up.indices where up[k].id != except && up[k].offset >= from - eps && synced(p, video: up[k].lane ?? 1) { up[k].offset += d; moved.insert(up[k].id) }
            p.upperClips = up
        }
        if var ov = p.overlays {
            for k in ov.indices where synced(p, video: ov[k].lane) && (ov[k].offset >= from - eps || (ov[k].connectedTo.map { moved.contains($0) } ?? false)) { ov[k].offset += d }
            p.overlays = ov
        }
        for k in p.titles.indices where p.titles[k].at >= from - eps { p.titles[k].at += d }
        if var ac = p.audioClips {
            for k in ac.indices where synced(p, audio: ac[k].lane) && (ac[k].offset >= from - eps || (ac[k].link.map { moved.contains($0) } ?? false)) { ac[k].offset += d }
            p.audioClips = ac
        }
        if var mk = p.markers {
            for k in mk.indices where mk[k].time >= from - eps || (mk[k].clip.map { moved.contains($0) } ?? false) { mk[k].time += d }
            p.markers = mk
        }
    }

    /// moves the sound linked to a V2+ clip by d seconds (onto a free audio track if its own is taken there)
    func followLinked(_ p: inout Project, _ id: String, offsetBy d: Double) {
        guard d != 0, var ac = p.audioClips else { return }
        for k in ac.indices where ac[k].link == id {
            ac[k].offset = max(0, ac[k].offset + d)
            p.audioClips = ac
            let me = ac[k]
            let clash = ac.contains { $0.id != me.id && $0.lane == me.lane && $0.offset < me.offset + me.duration - 0.001 && me.offset < $0.offset + $0.duration - 0.001 }
                || (me.lane == 1 && p.clips.contains { $0.audioDetached != true && $0.offset < me.offset + me.duration - 0.001 && me.offset < $0.offset + $0.duration - 0.001 })
            if clash { ac[k].lane = freeAudioLane(p, me.offset, me.duration, except: [me.id]) }
        }
        p.audioClips = ac
        p.audioLanes = max(p.audioLanes ?? 0, (ac.map { $0.lane }.max() ?? 1) - 1)
    }
    /// first audio track from A2 up with room for [t, t+d) (sound of clips on V2+; A1 stays for the main storyline)
    func freeAudioLane2(_ p: Project, _ t: Double, _ d: Double) -> Int {
        var lane = 2
        while (p.audioClips ?? []).contains(where: { $0.lane == lane && $0.offset < t + d - 0.001 && t < $0.offset + $0.duration - 0.001 }) { lane += 1 }
        return lane
    }
    /// first audio track (A1 first) with room for [t, t+d), ignoring `except`
    func freeAudioLane(_ p: Project, _ t: Double, _ d: Double, except: Set<String> = []) -> Int {
        var lane = 1
        func busy(_ l: Int) -> Bool {
            (p.audioClips ?? []).contains { !except.contains($0.id) && $0.lane == l && $0.offset < t + d - 0.001 && t < $0.offset + $0.duration - 0.001 }
            || (l == 1 && p.clips.contains { $0.audioDetached != true && $0.offset < t + d - 0.001 && t < $0.offset + $0.duration - 0.001 })
        }
        while busy(lane) { lane += 1 }
        return lane
    }
    /// everything an edge can snap to (Final Cut snapping): start of the timeline, playhead, markers, and the edges of
    /// every clip, layer and sound clip on every track, except the items being dragged (and sound linked to them)
    public func snapPoints(excluding ex: Set<String>) -> [Double] {
        var m: [Double] = [0, playhead]
        m += (project.markers ?? []).map { $0.time }
        for c in project.clips + (project.upperClips ?? []) where !ex.contains(c.id) { m += [c.offset, c.offset + c.duration] }
        for o in project.overlays ?? [] where !ex.contains(o.id) { m += [o.offset, o.offset + o.duration] }
        for a in project.audioClips ?? [] where !ex.contains(a.id) && !(a.link.map { ex.contains($0) } ?? false) { m += [a.offset, a.offset + a.duration] }
        return m
    }
    public func magneticDropTime(_ id: String, delta: Double) -> Double {
        guard let old = project.clips.first(where: { $0.id == id }) else { return 0 }
        let target = old.offset + delta
        let rest = project.clips.filter { $0.id != old.id }.sorted { $0.offset < $1.offset }
        let idx = rest.firstIndex { $0.offset + $0.duration / 2 > target } ?? rest.count
        return rest.prefix(idx).reduce(0) { $0 + $1.duration }
    }
    func isolated(_ m: DragMode, _ c: Clip, delta: Double, magnetRange: Double) -> Clip {
        let magnets = snapPoints(excluding: [c.id])
        return TimelineEdit.apply(m, clip: c, delta: delta, clips: [c], mediaDuration: mediaDuration[c.asset],
                                  audioMediaDuration: c.audioSource.flatMap { mediaDuration[$0.asset] }, fps: exactFPS, magnets: magnets, magnetRange: magnetRange)
    }

    func newClipID(_ p: Project) -> String {
        let all = p.clips + (p.upperClips ?? [])
        var n = all.count + 1
        while all.contains(where: { $0.id == "c\(n)" }) { n += 1 }
        return "c\(n)"
    }

    // Cut the clip that spans time t into two (no-op if t is already on a cut).
    /// Linked sound always stays with its picture, whatever the edit (any track): it keeps the same place relative to the clip's
    /// media, its own sound keeps the clip's exact length if it had it, and it goes when its picture is deleted.
    func reconcileLinks(_ p: inout Project, before: Project) {
        guard var ac = p.audioClips, ac.contains(where: { $0.link != nil }) else { return }
        let vNow = Dictionary((p.clips + (p.upperClips ?? [])).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let vOld = Dictionary((before.clips + (before.upperClips ?? [])).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let aOld = Dictionary((before.audioClips ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var gone = Set<String>()
        for k in ac.indices {
            guard let l = ac[k].link else { continue }
            guard let v = vNow[l] else { gone.insert(ac[k].id); continue }
            guard let v0 = vOld[l], let a0 = aOld[ac[k].id], abs(v.sp - 1) < 0.0001, abs(v0.sp - 1) < 0.0001 else { continue }
            let vIn = v.audioSource?.sourceIn ?? v.sourceIn, v0In = v0.audioSource?.sourceIn ?? v0.sourceIn
            let sameSpan = abs(a0.offset - v0.offset) < 0.002 && abs(a0.duration - v0.duration) < 0.002 && abs(a0.sourceIn - v0In) < 0.002
                && a0.asset == (v0.audioSource?.asset ?? v0.asset)
            if sameSpan {
                // its own sound, cut exactly like the picture: stays exactly like the picture
                let ds = vIn - a0.sourceIn
                ac[k].offset = v.offset; ac[k].sourceIn = vIn; ac[k].duration = v.duration
                if abs(ds) > 0.0001 { ac[k].keys = ac[k].keys?.map { VolKey(t: $0.t - ds, db: $0.db) } }
            } else {
                // other sound (or trimmed differently): keeps its place against the picture's media
                let anchor = (a0.offset - a0.sourceIn) - (v0.offset - v0In)
                ac[k].offset = max(0, anchor + v.offset - vIn + ac[k].sourceIn)
            }
        }
        if !gone.isEmpty { ac.removeAll { gone.contains($0.id) } }
        p.audioClips = ac
    }

    func splitAt(_ p: inout Project, _ t: Double) {
        guard let i = p.clips.firstIndex(where: { t > $0.offset + frame * 0.5 && t < $0.offset + $0.duration - frame * 0.5 }) else { return }
        var a = p.clips[i]; var b = a
        let d1 = t - a.offset
        a.duration = d1
        b.id = newClipID(p); b.sourceIn += d1 * a.sp; b.audioSource?.sourceIn += d1 * a.sp; b.offset = t; b.duration -= d1
        b.audio.keys = b.audio.keys?.map { VolKey(t: $0.t - d1, db: $0.db) }
        b.audio.fadeIn = nil; a.audio.fadeOut = nil
        (a.zoom, b.zoom) = KF.split(a.zoom, at: d1); (a.motion, b.motion) = KF.split(a.motion, at: d1)
        p.clips[i] = a; p.clips.insert(b, at: i + 1)
        if var ac = p.audioClips {
            for k in ac.indices.reversed() where ac[k].link == a.id {
                if t > ac[k].offset + 0.01 && t < ac[k].offset + ac[k].duration - 0.01 {
                    var x = ac[k], y = x; let dd = t - x.offset
                    x.duration = dd; x.fadeOut = nil
                    var n = ac.count + 1; while ac.contains(where: { $0.id == "au\(n)" }) { n += 1 }
                    y.id = "au\(n)"; y.offset = t; y.sourceIn += dd; y.duration -= dd; y.fadeIn = nil; y.link = b.id
                    y.keys = y.keys?.map { VolKey(t: $0.t - dd, db: $0.db) }
                    ac[k] = x; ac.insert(y, at: k + 1)
                } else if ac[k].offset >= t - 0.01 { ac[k].link = b.id }
            }
            p.audioClips = ac
        }
        if var ov = p.overlays {
            for k in ov.indices where ov[k].connectedTo == a.id && ov[k].offset >= t - frame * 0.25 { ov[k].connectedTo = b.id }
            p.overlays = ov
        }
    }

    /// Switch to project `n` without rebuilding the timeline when only things the renderer reads live have changed
    /// (graphic layers, picture-in-picture, clip colour, view-only track settings). Returns false if a rebuild is needed.
    func applySoft(from o: Project, to n: Project) -> Bool {
        guard let b = built else { return false }
        func core(_ p: Project) -> Project {
            var x = p
            x.overlays = nil; x.trackHeights = nil; x.unsynced = nil; x.gfxLanes = nil
            x.upperClips = p.upperClips?.map { var c = $0; c.xf = nil; c.color = ColorParams(); return c }
            x.clips = p.clips.map { var c = $0; c.color = ColorParams(); c.xf = nil; c.zoom = nil; return c }
            return x
        }
        guard core(o) == core(n) else { return false }
        // adjustment layers: a grade change is live; moving / trimming / adding one rebuilds
        let adjPlace: (Project) -> [Overlay] = { p in (p.overlays ?? []).filter { $0.adjust != nil }.map { var x = $0; x.adjust = ColorParams(); x.opacity = []; return x } }
        guard adjPlace(o) == adjPlace(n) else { return false }
        for a in n.overlays ?? [] where a.adjust != nil && o.overlays?.first(where: { $0.id == a.id }) != a {
            guard b.adjStore.has(a.id), let luts = try? Renderer.loadLUTs(a.adjust!, project: n, base: base, clip: a.id) else { return false }
            b.adjStore.set(a, luts: luts)
        }
        if o.overlays != n.overlays {
            b.overlayStore.replaceAll((n.overlays ?? []).filter { $0.disabled != true }.compactMap { ov in n.layerPath(ov, base: base).map { OverlayRender.Snap(o: ov, path: $0) } }.sorted { $0.o.lane < $1.o.lane })
        }
        for c in n.clips + (n.upperClips ?? []) { b.upperXf.set(c.id, c.xf) }
        for c in n.clips { b.store.setZoom(c.id, c.zoom ?? []) }
        for (a, c) in zip(o.upperClips ?? [], n.upperClips ?? []) where a.color != c.color {   // grades on V2+
            guard let luts = try? Renderer.loadLUTs(c.color, project: n, base: base, clip: c.id) else { return false }
            b.upperStore.set(c.id, color: c.color, luts: luts)
        }
        for (a, c) in zip(o.clips, n.clips) where a.color != c.color {
            guard let luts = try? Renderer.loadLUTs(c.color, project: n, base: base, clip: c.id) else { return false }
            b.store.set(c.id, color: c.color, luts: luts)
        }
        return true
    }
    /// sound-only change (volume, volume keyframes, fades, mute): make a new audio mix and hand it to the playing item - the picture
    /// is untouched (no player reload, no blink)
    func applyAudioSoft(from o: Project, to n: Project) async -> Bool {
        guard let b = built, let item = player.currentItem else { return false }
        func core(_ p: Project) -> Project {
            var x = p
            x.clips = p.clips.map { var c = $0; c.audio = AudioParams(); return c }
            x.upperClips = p.upperClips?.map { var c = $0; c.audio = AudioParams(); return c }
            x.audioClips = p.audioClips?.map { var a = $0; a.gainDb = 0; a.keys = nil; a.fadeIn = nil; a.fadeOut = nil; return a }
            x.overlays = nil; x.trackHeights = nil; x.unsynced = nil; x.gfxLanes = nil
            return x
        }
        guard core(o) == core(n) else { return false }
        // adjustment layers change the picture: never a sound-only change
        guard (o.overlays ?? []).filter({ $0.adjust != nil }) == (n.overlays ?? []).filter({ $0.adjust != nil }) else { return false }
        // A1 (the clips' own sound): the audio processor applies it - just hand it the new numbers, live
        b.audioStore.setVolume(Renderer.a1Volume(n))
        // other tracks (A2..., V2+ clip sound): new mix for the playing item (same layout -> same track numbers)
        let others: (Project) -> [String] = { p in (p.audioClips ?? []).map { "\($0.id) \($0.gainDb) \(String(describing: $0.keys)) \(String(describing: $0.fadeIn)) \(String(describing: $0.fadeOut))" }
            + (p.upperClips ?? []).map { "\($0.id) \($0.audio)" } }
        if others(o) != others(n) {
            guard let nb = try? await Renderer.build(n, base: base, scale: playbackScale) else { return false }
            nb.audioStore.set(b.audioStore.get().0); nb.audioStore.setVolume(Renderer.a1Volume(n))
            item.audioMix = nb.audioMix
            built?.audioMix = nb.audioMix; built?.audioStore = nb.audioStore; built?.laneAudio = nb.laneAudio
        }
        return true
    }
    func mutate(_ f: (inout Project) throws -> Void) async throws {
        let before = project
        var p = project
        let m0 = CACurrentMediaTime()
        try f(&p)
        let m1 = CACurrentMediaTime()
        if !noReconcile { reconcileLinks(&p, before: before) }
        let m2 = CACurrentMediaTime()
        try validate(p)
        let m3 = CACurrentMediaTime()
        project = p
        let ms = CACurrentMediaTime()
        defer { if let log = ProcessInfo.processInfo.environment["CUTGENIE_TIMING"], let h = FileHandle(forWritingAtPath: log) {
            h.seekToEndOfFile(); h.write(String(format: "mutate after edit %.0f ms\n", (CACurrentMediaTime() - ms) * 1000).data(using: .utf8)!); h.closeFile() } }
        if let log = ProcessInfo.processInfo.environment["CUTGENIE_TIMING"], let h = FileHandle(forWritingAtPath: log) {
            h.seekToEndOfFile(); h.write(String(format: "edit %.0f, reconcile %.0f, validate %.0f ms\n", (m1 - m0) * 1000, (m2 - m1) * 1000, (m3 - m2) * 1000).data(using: .utf8)!); h.closeFile()
        }
        if applySoft(from: before, to: p) { refreshFrame(); undoStack.append(before); redoStack = []; return }
        if await applyAudioSoft(from: before, to: p) { undoStack.append(before); redoStack = []; return }
        do { try await rebuild() } catch { project = before; throw error }
        undoStack.append(before); redoStack = []
    }

    // MARK: control commands (the same ones the HTTP server, CLI and MCP wrapper call)
    public func handle(_ cmd: [String: Any]) async -> [String: Any] {
        let name = (cmd["cmd"] as? String) ?? ""
        do {
            let t0 = CACurrentMediaTime()
            var out = try await run(name, cmd)
            out["ok"] = true
            if let log = ProcessInfo.processInfo.environment["CUTGENIE_TIMING"], let h = FileHandle(forWritingAtPath: log) {
                h.seekToEndOfFile(); h.write(String(format: "%@ total %.0f ms\n", name, (CACurrentMediaTime() - t0) * 1000).data(using: .utf8)!); h.closeFile()
            }
            return out          // success: nothing to say (no "… ok" chatter in the window)
        } catch {
            Log.write("command \(name) failed: \(error)")
            lastMessage = "\(error)"          // only problems are shown, in plain words
            return ["ok": false, "error": "\(error)"]
        }
    }

    func num(_ c: [String: Any], _ k: String) -> Double? {
        if let d = c[k] as? Double { return d }
        if let i = c[k] as? Int { return Double(i) }
        if let s = c[k] as? String { return Double(s) }
        return nil
    }
    func str(_ c: [String: Any], _ k: String) -> String? {
        if let s = c[k] as? String { return s }
        if let n = c[k] as? NSNumber { return n.stringValue }
        return nil
    }
    func flag(_ c: [String: Any], _ k: String) -> Bool {
        if let b = c[k] as? Bool { return b }
        if let s = c[k] as? String { return ["1", "true", "yes"].contains(s.lowercased()) }
        return false
    }
    func need<T>(_ v: T?, _ what: String) throws -> T {
        guard let v else { throw RenderError.message("missing or invalid: \(what)") }
        return v
    }
    func clipIndex(_ c: [String: Any]) throws -> Int {
        if let id = str(c, "clip") {
            return try need(project.clips.firstIndex { $0.id == id }, "clip '\(id)' not found")
        }
        return try need(project.clips.isEmpty ? nil : 0, "project has no clips")
    }

    /// clip=<id> (default: first clip), or same_media_as=<id> for every clip that uses the same picture file.
    func colorTargets(_ c: [String: Any]) throws -> [Int] {
        if let ref = str(c, "same_media_as") {
            if let k = project.gradeIndex(of: ref), k <= Project.adjBase { return [k] }    // an adjustment layer has no "same file"
            let r = try need(project.gradeIndex(of: ref).flatMap { project.gradeClip($0) }, "clip '\(ref)' not found")
            return project.gradeIndices.filter { project.gradeClip($0)?.asset == r.asset }
        }
        if let id = str(c, "clip") { return [try need(project.gradeIndex(of: id), "clip '\(id)' not found")] }
        return [try clipIndex(c)]
    }

    func run(_ name: String, _ c: [String: Any]) async throws -> [String: Any] {
        // locked tracks: refuse any edit of something on them
        if ["trim", "move", "delete", "ripple_delete", "drag_edit", "overlay_edit", "overlay_delete", "detach_audio", "slip", "slide",
            "set_fade", "set_volume", "to_lane", "upper_trim", "audio_edit", "rename_marker"].contains(name) {
            try refuseIfLocked([str(c, "clip"), str(c, "id")].compactMap { $0 })
            if name == "to_lane", let l = num(c, "lane") { let tr = Int(l) == 0 ? "V1" : "V\(Int(l) + 1)"; if (project.unsynced ?? []).contains(tr) { throw RenderError.message("\(tr) is locked") } }
            if name == "audio_edit", let l = num(c, "lane"), (project.unsynced ?? []).contains("A\(Int(l))") { throw RenderError.message("A\(Int(l)) is locked") }
        }
        if name == "roll", let at = num(c, "at") {
            try refuseIfLocked(project.clips.filter { abs($0.offset - at) < frame || abs($0.offset + $0.duration - at) < frame }.map { $0.id })
        }
        if name == "nudge" { try refuseIfLocked(Array(selection)) }
        switch name {
        case "status":
            return ["project": project.name, "path": projectURL?.path ?? "", "clips": project.clips.count,
                    "titles": project.titles.count, "duration": built?.duration ?? 0,
                    "time": player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0,
                    "playing": player.rate != 0, "canUndo": !undoStack.isEmpty, "canRedo": !redoStack.isEmpty]
        case "get_project":
            let d = try JSONEncoder().encode(project)
            return ["project": try JSONSerialization.jsonObject(with: d)]
        case "inspector_tab": if let t = str(c, "tab") { inspectorTab = t }; return [:]       // testing aid: clip | color | audio
        case "paste_attrs":
            // ids= parts=all|transform,zoom,crop,shadow,color : the copied clip's look onto these clips (Final Cut Paste Attributes)
            guard let src = attrClip else { throw RenderError.message("Copy a clip first (⌘C), then paste its attributes") }
            let ids = Set((str(c, "ids") ?? selection.joined(separator: ",")).split(separator: ",").map(String.init)).subtracting([src.id])
            guard !ids.isEmpty else { throw RenderError.message("Select the clips to paste onto") }
            try refuseIfLocked(Array(ids))
            let parts = Set((str(c, "parts") ?? "all").split(separator: ",").map(String.init))
            func want(_ p: String) -> Bool { parts.contains("all") || parts.contains(p) }
            let sx = src.xf ?? ClipXf()
            func apply(_ d: inout Clip) {
                var x = d.xf ?? ClipXf()
                var ks = x.keys ?? [:]
                if want("transform") {
                    x.position = sx.position; x.scale = sx.scale; x.rotation = sx.rotation; x.opacity = sx.opacity
                    for p in ["position", "scale", "rotation", "opacity"] { ks[p] = sx.keys?[p] }
                }
                if want("crop") { x.crop = sx.crop; ks["crop"] = sx.keys?["crop"] }
                if want("shadow") { x.shadow = sx.shadow; ks["shadow"] = sx.keys?["shadow"] }
                ks = ks.filter { !$0.value.isEmpty }
                x.keys = ks.isEmpty ? nil : ks
                d.xf = x.isIdentity ? nil : x
                if want("zoom"), d.lane == nil { d.zoom = src.zoom?.filter { $0.t <= d.duration + 0.001 }; d.zoomAnchor = src.zoomAnchor }
                if want("color") { d.color = src.color }
            }
            var n = 0
            try await mutate { p in
                for i in p.clips.indices where ids.contains(p.clips[i].id) { apply(&p.clips[i]); n += 1 }
                if var up = p.upperClips { for i in up.indices where ids.contains(up[i].id) { apply(&up[i]); n += 1 }; p.upperClips = up }
            }
            lastMessage = "Pasted attributes onto \(n) clip\(n == 1 ? "" : "s")"
            return ["clips": n]
        case "simplify_keys":
            // ids= (or all=true): keep only the keyframes that shape each move (zoom and transform), easing between them
            let all = (c["all"] as? Bool) == true || str(c, "all") == "true"
            let ids = Set(all ? (project.clips + (project.upperClips ?? [])).map(\.id) : (str(c, "ids") ?? "").split(separator: ",").map(String.init))
            try refuseIfLocked(Array(ids))
            var before = 0, after = 0
            try await mutate { p in
                func count(_ c: Clip) -> Int { (c.zoom?.count ?? 0) + (c.xf?.keys ?? [:]).values.reduce(0) { $0 + $1.count } }
                func fix(_ c: inout Clip) {
                    before += count(c)
                    if let z = c.zoom, z.count > 2 { c.zoom = Editor.simplifyEased(z, tol: 0.006) }
                    if var x = c.xf, let ks = x.keys {
                        let tol = ["position": 0.4, "scale": 0.006, "rotation": 0.5, "opacity": 0.02, "crop": 0.004, "shadow": 0.02]
                        x.keys = Dictionary(uniqueKeysWithValues: ks.map { ($0.key, $0.value.count > 2 ? Editor.simplifyEased($0.value, tol: tol[$0.key] ?? 0.01) : $0.value) })
                        c.xf = x
                    }
                    after += count(c)
                }
                for i in p.clips.indices where ids.contains(p.clips[i].id) { fix(&p.clips[i]) }
                if var up = p.upperClips { for i in up.indices where ids.contains(up[i].id) { fix(&up[i]) }; p.upperClips = up }
            }
            lastMessage = "Keyframes simplified: \(before) → \(after)"
            return ["before": before, "after": after]
        case "move_clip_key":
            // id= from= to= : every keyframe of the clip at time `from` (transform and zoom) moves to `to` (seconds in the clip)
            let id = try need(str(c, "id"), "id"), from = try need(num(c, "from"), "from"), to = try need(num(c, "to"), "to")
            try refuseIfLocked([id])
            func mv(_ k: [Keyframe]?) -> [Keyframe]? {
                guard var k else { return nil }
                for i in k.indices where abs(k[i].t - from) < 0.002 { k[i].t = to }
                k.removeAll { $0.t != to && abs($0.t - to) < 0.002 }          // dropped onto another keyframe: the moved one wins
                return k.sorted { $0.t < $1.t }
            }
            try await mutate { p in
                if let i = p.clips.firstIndex(where: { $0.id == id }) {
                    p.clips[i].zoom = mv(p.clips[i].zoom); p.clips[i].motion = mv(p.clips[i].motion)
                    if var x = p.clips[i].xf, let ks = x.keys { x.keys = ks.mapValues { mv($0) ?? [] }; p.clips[i].xf = x }
                } else if var up = p.upperClips, let i = up.firstIndex(where: { $0.id == id }) {
                    if var x = up[i].xf, let ks = x.keys { x.keys = ks.mapValues { mv($0) ?? [] }; up[i].xf = x }
                    p.upperClips = up
                }
            }
            return [:]
        case "relink_folder":
            // dir= [all=true] : missing media files (or, with all, every file) are looked for by name in that folder and its sub-folders
            let dir = URL(fileURLWithPath: ((try need(str(c, "dir"), "dir")) as NSString).expandingTildeInPath)
            let all = flag(c, "all")
            let want = project.assets.filter { a in all || !FileManager.default.fileExists(atPath: project.resolve(a.id, base: base)?.path ?? "") }
            guard !want.isEmpty else { return ["found": 0, "missing": 0] }
            var byName: [String: String] = [:]
            let names = Set(want.map { (($0.path as NSString).lastPathComponent).lowercased() })
            if let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let u as URL in en where names.contains(u.lastPathComponent.lowercased()) && byName[u.lastPathComponent.lowercased()] == nil { byName[u.lastPathComponent.lowercased()] = u.path }
            }
            var found = 0
            try await mutate { p in
                for i in p.assets.indices where want.contains(where: { $0.id == p.assets[i].id }) {
                    if let np = byName[(p.assets[i].path as NSString).lastPathComponent.lowercased()] { p.assets[i].path = np; found += 1 }
                }
            }
            Log.write("relink in \(dir.path): \(found) of \(want.count) found")
            return ["found": found, "missing": want.count - found]
        case "set_asset_paths":
            // paths={asset id: new path} (after Collect media copied the files)
            guard let m = c["paths"] as? [String: String] else { throw RenderError.message("missing paths") }
            try await mutate { p in for i in p.assets.indices { if let np = m[p.assets[i].id] { p.assets[i].path = np } } }
            return ["changed": m.count]
        case "restore_version":
            // file= : an earlier saved version replaces the timeline (one undo step; nothing is saved until you save)
            let f = URL(fileURLWithPath: try need(str(c, "file"), "file"))
            let old = try Project.load(from: f)
            try await mutate { p in let name = p.name; p = old; p.name = name }
            return [:]
        case "restore_recovery": await restoreRecovery(); return [:]
        case "discard_recovery": discardRecovery(); return [:]
        case "autosave_now": autosave(); return ["unsaved": hasUnsavedChanges, "offer": recoveryOffer.map { $0.timeIntervalSince1970 } ?? 0]
        case "open":
            try await open(try need(str(c, "path"), "path"))
            return ["duration": built?.duration ?? 0]
        case "save":
            let url = str(c, "path").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            let dest = try need(url ?? projectURL, "path (project has no file yet)")
            if let old = base, dest.deletingLastPathComponent().standardizedFileURL != old.standardizedFileURL {
                // saved somewhere else (Save As): files named relative to the old place get their full path, so nothing goes missing
                for i in project.assets.indices where !project.assets[i].path.hasPrefix("/") {
                    project.assets[i].path = old.appendingPathComponent(project.assets[i].path).standardizedFileURL.path
                }
                if c["name"] == nil { project.name = dest.deletingPathExtension().deletingPathExtension().lastPathComponent }
            }
            let (target, why) = safeSaveURL(dest)
            if target == dest { Versions.keep(dest) }        // the file being replaced is kept (last 10 versions)
            try project.save(to: target)
            savedProject = project
            if let u = projectURL { Recovery.clear(for: u.path) }
            Recovery.clear(for: target.path); recoveryOffer = nil
            if target != dest {
                projectURL = target; takeLock(target)
                lastMessage = "Saved as \(target.lastPathComponent) because \(why ?? "") - the original was left as it is"
            } else if projectURL?.standardizedFileURL != dest.standardizedFileURL { projectURL = dest; takeLock(dest) }
            diskStamp = Self.mtime(target)
            var r: [String: Any] = ["saved": target.path]; if let why { r["conflict"] = why }
            return r
        case "play":
            // a player that died (sound device switched, decoder error...) gets a fresh one instead of staying silent and frozen
            if player.currentItem == nil || player.currentItem?.status == .failed { try await rebuild(keepTime: true) }
            player.rate = Float(playSpeed); watchPlayback(); return [:]
        case "play_speed":
            // speed= : how fast the viewer plays (0.5, 1, 1.25, 1.5, 2, 3, 4...). Does not change the edit.
            playSpeed = max(0.25, min(8, try need(num(c, "speed"), "speed")))
            UserDefaults.standard.set(playSpeed, forKey: "playSpeed")
            if player.rate != 0 { player.rate = Float(playSpeed) }
            return ["speed": playSpeed]
        case "set_speed":
            // clip=<V1 or V2+ clip> speed=<0.1...8> : retime the clip (2 = twice as fast, half as long). The rest moves to make room.
            let id = try need(str(c, "clip"), "clip"); try refuseIfLocked([id])
            let ns = max(0.1, min(8, try need(num(c, "speed"), "speed")))
            let inV1 = project.clips.contains { $0.id == id }
            guard let old = (project.clips + (project.upperClips ?? [])).first(where: { $0.id == id }) else { throw RenderError.message("no clip \(id)") }
            if old.audioDetached == true, (project.audioClips ?? []).contains(where: { $0.link == id || abs($0.offset - old.offset) < frame && abs($0.duration - old.duration) < frame }) {
                throw RenderError.message("This clip's sound is on its own track - change the speed before detaching, or speed up the sound clip separately")
            }
            let nd = snap(old.duration * old.sp / ns)
            let k = nd / old.duration
            try await mutate { p in
                func upd(_ x: inout Clip) {
                    x.speed = abs(ns - 1) < 0.0001 ? nil : ns; x.duration = nd
                    x.audio.keys = x.audio.keys?.map { VolKey(t: $0.t * k, db: $0.db) }
                    x.audio.fadeIn = x.audio.fadeIn.map { min($0, nd) }; x.audio.fadeOut = x.audio.fadeOut.map { min($0, nd) }
                }
                if inV1, let i = p.clips.firstIndex(where: { $0.id == id }) {
                    upd(&p.clips[i])
                    self.rippleAfter(&p, from: old.offset + old.duration, by: nd - old.duration, except: id)
                } else if let i = p.upperClips?.firstIndex(where: { $0.id == id }) {
                    upd(&p.upperClips![i])
                    let me = p.upperClips![i]
                    if p.upperClips!.contains(where: { $0.id != id && $0.lane == me.lane && $0.offset < me.offset + me.duration - 0.001 && me.offset < $0.offset + $0.duration - 0.001 }) {
                        throw RenderError.message("Not enough room on V\((me.lane ?? 1) + 1) for the slower clip")
                    }
                }
            }
            return ["clip": id, "speed": ns, "duration": nd]
        case "pause": player.pause(); return [:]
        case "seek":
            let t = try need(num(c, "time"), "time")
            playhead = t
            revealPlayhead(t)
            await player.seek(to: CMTime(seconds: t, preferredTimescale: 6000), toleranceBefore: .zero, toleranceAfter: .zero)
            return ["time": t]
        case "add_lower_third":
            let lt = LowerThird(id: "lt\(project.titles.count + 1)", at: try need(num(c, "at"), "at"),
                                duration: num(c, "dur") ?? 4, tag: str(c, "tag") ?? "",
                                title: try need(str(c, "title"), "title"), sub: str(c, "sub") ?? "")
            try await mutate { $0.titles.append(lt) }
            return ["id": lt.id]
        case "set_audio":
            let i = try clipIndex(c)
            let g = try need(num(c, "gain_db"), "gain_db")
            try await mutate { $0.clips[i].audio.gainDb = g }
            return ["clip": project.clips[i].id, "gain_db": g]
        case "set_color":
            let idx = try colorTargets(c)
            let keys = ["exposure", "contrast", "saturation", "temperature", "tint", "hue"]
            let space = str(c, "source_space")
            if let sp = space, sp != "auto", !ColorSpaces.all.contains(where: { $0.id == sp }) { throw RenderError.message("source_space must be auto or one of: \(ColorSpaces.all.map { $0.id }.joined(separator: ", "))") }
            guard space != nil || keys.contains(where: { num(c, $0) != nil }) else {
                throw RenderError.message("give at least one of: \(keys.joined(separator: ", ")), source_space")
            }
            let vals = Dictionary(uniqueKeysWithValues: keys.compactMap { k in num(c, k).map { (k, $0) } })
            try await colorEdit(idx, live: flag(c, "live")) { col in
                if let v = vals["exposure"] { col.exposure = v }
                if let v = vals["contrast"] { col.contrast = v }
                if let v = vals["saturation"] { col.saturation = v }
                if let v = vals["temperature"] { col.temperature = v }
                if let v = vals["tint"] { col.tint = v }
                if let v = vals["hue"] { col.hue = v }
                if let sp = space { col.sourceSpace = sp == "auto" ? nil : sp }
            }
            return ["clips": idx.compactMap { project.gradeClip($0)?.id }]
        case "set_wheels":
            // clip= or same_media_as=  wheel=global|shadows|midtones|highlights  hue= amount= saturation= brightness= r= g= b=
            // [preserve_luma=true|false] [mix=0..1] [live=true]
            let idx = try colorTargets(c)
            let wheel = str(c, "wheel")
            if wheel == nil && c["preserve_luma"] == nil && c["mix"] == nil { throw RenderError.message("give wheel=global|shadows|midtones|highlights, preserve_luma= or mix=") }
            if let w = wheel, !["global", "shadows", "midtones", "highlights"].contains(w) { throw RenderError.message("wheel must be global, shadows, midtones or highlights") }
            let hue = num(c, "hue"), amount = num(c, "amount"), sat = num(c, "saturation"), bri = num(c, "brightness")
            let rgb: [Double]? = (num(c, "r") != nil && num(c, "g") != nil && num(c, "b") != nil) ? [num(c, "r")!, num(c, "g")!, num(c, "b")!] : nil
            let preserve: Bool? = c["preserve_luma"] == nil ? nil : flag(c, "preserve_luma")
            let mix = num(c, "mix")
            try await colorEdit(idx, live: flag(c, "live")) { col in
                var ws = col.wheels ?? Wheels()
                if let p = preserve { ws.preserveLuma = p }
                if let m = mix { ws.mix = m }
                if let w = wheel {
                    var x: WheelParams = w == "global" ? ws.global : w == "shadows" ? ws.shadows : w == "midtones" ? ws.midtones : ws.highlights
                    if let v = hue { x.hue = v; x.rgb = nil }
                    if let v = amount { x.amount = v; x.rgb = nil }
                    if let v = sat { x.saturation = v }
                    if let v = bri { x.brightness = v }
                    if let r = rgb { x.rgb = r }
                    switch w { case "global": ws.global = x; case "shadows": ws.shadows = x; case "midtones": ws.midtones = x; default: ws.highlights = x }
                }
                col.wheels = ws
            }
            return ["clips": idx.compactMap { project.gradeClip($0)?.id }]
        case "add_adjustment":
            // [at=] [dur=]: an adjustment layer on a track above everything there (default: over the selection, or 10 s from the playhead)
            let ids = selection
            let spans = project.clips.filter { ids.contains($0.id) }.map { ($0.offset, $0.offset + $0.duration) }
                + (project.upperClips ?? []).filter { ids.contains($0.id) }.map { ($0.offset, $0.offset + $0.duration) }
                + (project.overlays ?? []).filter { ids.contains($0.id) }.map { ($0.offset, $0.offset + $0.duration) }
            var at = snap(num(c, "at") ?? spans.map { $0.0 }.min() ?? playhead)
            var dur = num(c, "dur") ?? (spans.isEmpty ? 10 : spans.map { $0.1 }.max()! - at)
            at = max(0, at); dur = snap(max(frame, dur))
            let ov = project.overlays ?? [], upc = project.upperClips ?? []
            let used = ov.filter { $0.offset < at + dur && at < $0.offset + $0.duration }.map { $0.lane }
                + upc.filter { $0.offset < at + dur && at < $0.offset + $0.duration }.map { $0.lane ?? 1 }
            let lane = max(1, (used.max() ?? 0) + 1)
            var n = ov.count + 1; while ov.contains(where: { $0.id == "g\(n)" }) { n += 1 }
            var o = Overlay(id: "g\(n)", name: "Adjustment layer", asset: "", lane: lane, offset: at, duration: dur)
            o.adjust = ColorParams()
            try await mutate { p in p.overlays = (p.overlays ?? []) + [o]; p.gfxLanes = max(p.gfxLanes ?? 0, lane) }
            selection = [o.id]; selectedOverlay = o.id; selectedClip = nil; inspectorTab = "color"
            return ["id": o.id, "lane": lane, "offset": at, "duration": dur]
        case "copy_grade":
            // clip= (default: the clip shown in the Color panel): remembers its whole grade (sliders, wheels, LUTs)
            let i = try need(str(c, "clip").flatMap { project.gradeIndex(of: $0) } ?? gradeTargets.first, "no clip to copy from")
            let col = try need(project.gradeClip(i)?.color, "no clip")
            gradeClipboard = lookOf(col, name: "")
            return ["copied": project.gradeClip(i)!.id]
        case "paste_grade":
            // ids= (default: selected clips): gives them the copied grade (replaces theirs). One undo step.
            let l = try need(gradeClipboard, "copy a grade first (Copy grade)")
            return try await applyLook(l, c)
        case "save_look":
            // name= [clip=]: saves the grade for every project (Color panel > Looks)
            let name = try need(str(c, "name"), "name").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains("/") else { throw RenderError.message("give the look a name") }
            let i = try need(str(c, "clip").flatMap { project.gradeIndex(of: $0) } ?? gradeTargets.first, "no clip selected")
            let l = lookOf(try need(project.gradeClip(i)?.color, "no clip"), name: name)
            try FileManager.default.createDirectory(at: Editor.looksDir, withIntermediateDirectories: true)
            try JSONEncoder().encode(l).write(to: Editor.looksDir.appendingPathComponent(name + ".json"))
            looksVersion += 1
            return ["saved": name]
        case "apply_look":
            // name= [ids=]: gives the selected clips that look
            let name = try need(str(c, "name"), "name")
            let l = try JSONDecoder().decode(SavedLook.self, from: Data(contentsOf: Editor.looksDir.appendingPathComponent(name + ".json")))
            return try await applyLook(l, c)
        case "list_looks":
            return ["looks": Editor.savedLooks()]
        case "delete_look":
            let name = try need(str(c, "name"), "name")
            try FileManager.default.trashItem(at: Editor.looksDir.appendingPathComponent(name + ".json"), resultingItemURL: nil)
            looksVersion += 1
            return ["deleted": name]
        case "audio_track":
            // track=A1|A2...: which track the Audio panel edits
            let t = try need(str(c, "track"), "track")
            guard t.hasPrefix("A"), let n = Int(t.dropFirst()), n >= 1 else { throw RenderError.message("track must be A1, A2...") }
            audioTrack = t
            return ["track": t]
        case "save_audio_preset":
            // name= [track=]: saves a track's effects for every project (Audio panel > Presets)
            let name = try need(str(c, "name"), "name").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains("/") else { throw RenderError.message("give the preset a name") }
            try FileManager.default.createDirectory(at: Editor.audioPresetsDir, withIntermediateDirectories: true)
            try JSONEncoder().encode(chain(for: str(c, "track") ?? audioTrack)).write(to: Editor.audioPresetsDir.appendingPathComponent(name + ".json"))
            looksVersion += 1
            return ["saved": name]
        case "apply_audio_preset":
            // name= [tracks=A1,A2] (default: the track shown in the Audio panel)
            let name = try need(str(c, "name"), "name")
            var ch = try JSONDecoder().decode(AudioChain.self, from: Data(contentsOf: Editor.audioPresetsDir.appendingPathComponent(name + ".json")))
            let tracks = (str(c, "tracks") ?? audioTrack).split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            let before = project
            for t in tracks {
                if t == "A1" { ch.targetLUFS = audioChain.targetLUFS }
                storeChain(ch, track: t)
            }
            if before != project { undoStack.append(before); redoStack = [] }
            return ["tracks": tracks]
        case "list_audio_presets":
            return ["presets": Editor.savedAudioPresets()]
        case "delete_audio_preset":
            let name = try need(str(c, "name"), "name")
            try FileManager.default.trashItem(at: Editor.audioPresetsDir.appendingPathComponent(name + ".json"), resultingItemURL: nil)
            looksVersion += 1
            return ["deleted": name]
        case "toggle_enabled":
            // ids= (default: selection): switch clips / graphics / sound off or back on (Final Cut "V"). Off = not seen / heard, kept on the timeline
            let ids = str(c, "ids").map { Set($0.split(separator: ",").map(String.init)) } ?? selection
            guard !ids.isEmpty else { throw RenderError.message("select a clip first") }
            let all = project.clips.filter { ids.contains($0.id) }.map { $0.disabled == true } + (project.upperClips ?? []).filter { ids.contains($0.id) }.map { $0.disabled == true }
                + (project.overlays ?? []).filter { ids.contains($0.id) }.map { $0.disabled == true } + (project.audioClips ?? []).filter { ids.contains($0.id) }.map { $0.disabled == true }
            let off: Bool? = all.allSatisfy { $0 } ? nil : true      // all off -> switch on; otherwise switch them all off
            try await mutate { p in
                for i in p.clips.indices where ids.contains(p.clips[i].id) { p.clips[i].disabled = off }
                if var u = p.upperClips { for i in u.indices where ids.contains(u[i].id) { u[i].disabled = off }; p.upperClips = u }
                if var o = p.overlays { for i in o.indices where ids.contains(o[i].id) { o[i].disabled = off }; p.overlays = o }
                if var a = p.audioClips { for i in a.indices where ids.contains(a[i].id) { a[i].disabled = off }; p.audioClips = a }
            }
            return ["off": off ?? false, "items": all.count]
        case "commit_live":
            commitLive(); return [:]
        case "set_lut":
            // clip= or same_media_as=  slot=input|creative|output (default output)  path=<file.cube> or asset=<id>  [intensity=0..1] [enabled=true|false]
            let idx = try colorTargets(c)
            let slot = str(c, "slot") ?? "output"
            guard ["input", "creative", "output"].contains(slot) else { throw RenderError.message("slot must be input, creative or output") }
            var assetID = str(c, "asset")
            var newAsset: Asset?
            if assetID == nil, let path = str(c, "path") {
                let src = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                _ = try LUTLoader.load(src)      // fail early with a clear message if it is not a usable .cube
                // keep a copy inside the project's own LUTs folder so the project stays portable (the original is never touched)
                var dest = src
                if let b = base {
                    let dir = b.appendingPathComponent("LUTs")
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    dest = dir.appendingPathComponent(src.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.copyItem(at: src, to: dest) }
                }
                let rel = base.map { dest.path.hasPrefix($0.path + "/") ? String(dest.path.dropFirst($0.path.count + 1)) : dest.path } ?? dest.path
                if let a = project.assets.first(where: { $0.path == rel }) { assetID = a.id }
                else {
                    var n = project.assets.count + 1
                    while project.assets.contains(where: { $0.id == "a\(n)" }) { n += 1 }
                    newAsset = Asset(id: "a\(n)", path: rel); assetID = newAsset!.id
                }
            }
            let aid = try need(assetID, "path or asset")
            let intensity = num(c, "intensity") ?? 1
            let enabled = c["enabled"] == nil ? true : flag(c, "enabled")
            let inSp = str(c, "input_space")
            // A LUT in the Output slot produces the final picture, so unless told otherwise its output is the project's output space
            let outSp = str(c, "output_space") ?? (slot == "output" ? project.settings.colorSpace : nil)
            for sp in [inSp, outSp].compactMap({ $0 }) where !ColorSpaces.all.contains(where: { $0.id == sp }) {
                throw RenderError.message("space must be one of: \(ColorSpaces.all.map { $0.id }.joined(separator: ", "))")
            }
            try await mutate { p in
                if let na = newAsset { p.assets.append(na) }
                for i in idx {
                    p.editColor(i) { col in
                        var l = col.luts ?? []
                        l.removeAll { $0.slot == slot }
                        l.append(LUTSlot(slot: slot, asset: aid, intensity: intensity, enabled: enabled, inputSpace: inSp, outputSpace: outSp))
                        col.luts = l
                    }
                }
            }
            return ["clips": idx.count, "asset": aid, "slot": slot]
        case "remove_lut":
            let idx = try colorTargets(c)
            let slot = str(c, "slot")
            try await mutate { p in for i in idx { p.editColor(i) { $0.luts?.removeAll { slot == nil || $0.slot == slot } } } }
            return ["clips": idx.count]
        case "split":
            let t = snap(try need(num(c, "at"), "at"))
            _ = try need(project.clips.firstIndex { t > $0.offset + frame * 0.5 && t < $0.offset + $0.duration - frame * 0.5 },
                         "no clip spans time \(t)")
            try await mutate { self.splitAt(&$0, t) }
            return ["clips": project.clips.map { $0.id }]
        case "add_clip":
            // asset=<id> or path=<media file>; optional source_in, dur, offset (default: end of timeline)
            var assetID = str(c, "asset")
            var newAsset: Asset?
            if assetID == nil, let path = str(c, "path") {
                let abs = ((path as NSString).expandingTildeInPath)
                if let a = project.assets.first(where: { project.resolve($0.id, base: base)?.standardizedFileURL.path == URL(fileURLWithPath: abs).standardizedFileURL.path }) { assetID = a.id }
                else {
                    var n = project.assets.count + 1
                    while project.assets.contains(where: { $0.id == "a\(n)" }) { n += 1 }
                    newAsset = Asset(id: "a\(n)", path: abs); assetID = newAsset!.id
                }
            }
            let aid = try need(assetID, "asset or path")
            var all = project
            if let na = newAsset { all.assets.append(na) }
            let url = try need(all.resolve(aid, base: base), "asset '\(aid)' not found")
            let mediaDur = try await AVURLAsset(url: url).load(.duration).seconds
            let sIn = snap(num(c, "source_in") ?? 0)
            let dur = snap(num(c, "dur") ?? (mediaDur - sIn))
            let off = snap(num(c, "offset") ?? project.totalDuration)
            guard sIn + dur <= mediaDur + frame else { throw RenderError.message("media is only \(mediaDur) s long") }
            let hasSound = (try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio).isEmpty == false) ?? false
            let inputLUT: LUTSlot? = nil  // no automatic LUT: the user picks LUTs per clip in the Color tab
            if project.clips.isEmpty && (project.upperClips ?? []).isEmpty, let f = await MediaFormat.read(url),
               f.width != project.settings.width || f.height != project.settings.height || abs(f.fps - project.settings.fps) > 0.01 {
                var g = f; g.path = url.path; offerMatch = g
            }
            var id = ""
            try await mutate { p in
                if let na = newAsset { p.assets.append(na) }
                id = self.newClipID(p)
                if self.flag(c, "insert") {
                    // Final Cut insert (W): cut the storyline at the point and push everything after it to the right
                    self.splitAt(&p, off)
                    self.rippleAfter(&p, from: off, by: dur, except: nil)
                }
                if let l = self.num(c, "lane").map({ Int($0) }), l >= 1 {
                    // a video track above the storyline (V2 = lane 1): a free track at that spot, starting from lane=
                    var up = p.upperClips ?? []
                    var lane = l
                    let ov = p.overlays ?? []
                    while up.contains(where: { ($0.lane ?? 1) == lane && $0.offset < off + dur - 0.001 && off < $0.offset + $0.duration - 0.001 })
                            || ov.contains(where: { $0.lane == lane && $0.offset < off + dur - 0.001 && off < $0.offset + $0.duration - 0.001 }) { lane += 1 }
                    var x = Clip(id: id, asset: aid, sourceIn: sIn, duration: dur, offset: off); x.lane = lane
                    let g = self.flag(c, "mute") ? -96 : (self.num(c, "gain_db") ?? 0)
                    x.audio.gainDb = g
                    if let l = inputLUT { x.color.luts = [l] }
                    if hasSound {
                        // its sound shows at once on the first free audio track from A2, linked: it moves, trims, cuts and deletes with the picture
                        var ac = p.audioClips ?? []
                        var n = ac.count + 1; while ac.contains(where: { $0.id == "au\(n)" }) { n += 1 }
                        let al = self.freeAudioLane2(p, off, dur)
                        ac.append(AudioClip(id: "au\(n)", asset: aid, name: (url.path as NSString).lastPathComponent, lane: al, offset: off, sourceIn: sIn, duration: dur, gainDb: g, link: id))
                        p.audioClips = ac; p.audioLanes = max(p.audioLanes ?? 0, al - 1)
                        x.audioDetached = true
                    }
                    up.append(x); p.upperClips = up; p.gfxLanes = max(p.gfxLanes ?? 0, lane)
                } else {
                    var x = Clip(id: id, asset: aid, sourceIn: sIn, duration: dur, offset: off)
                    if let l = inputLUT { x.color.luts = [l] }
                    p.clips.append(x)
                    p.clips.sort { $0.offset < $1.offset }
                }
            }
            if flag(c, "insert") || num(c, "lane") != nil { selection = [id] }
            selectedClip = id
            return ["clip": id, "asset": aid, "duration": dur, "offset": off]
        case "trim":
            // clip=<id> edge=start|end to=<timeline time>. Start trims move the in-point; the clip's end stays put.
            let i = try clipIndex(c)
            let edge = try need(str(c, "edge"), "edge (start or end)")
            let to = snap(try need(num(c, "to"), "to"))
            try await mutate { p in
                var k = p.clips[i]
                if edge == "start" {
                    let d = to - k.offset
                    let ks = d * k.sp; k.sourceIn += ks; k.audioSource?.sourceIn += ks; k.duration -= d; k.offset = to
                } else if edge == "end" {
                    k.duration = to - k.offset
                } else { throw RenderError.message("edge must be start or end") }
                p.clips[i] = k
            }
            return ["clip": project.clips[i].id, "offset": project.clips[i].offset, "duration": project.clips[i].duration]
        case "move":
            let i = try clipIndex(c)
            let to = snap(try need(num(c, "offset"), "offset"))
            try await mutate { $0.clips[i].offset = to }
            return ["clip": project.clips[i].id, "offset": to]
        case "delete":
            // removes the clip and leaves a gap
            let i = try clipIndex(c)
            let id = project.clips[i].id
            if magnetic && c["magnetic"] == nil { return try await run("ripple_delete", c) }
            try await mutate { p in p.clips.remove(at: i) }
            if selectedClip == id { selectedClip = nil }
            return ["deleted": id]
        case "ripple_delete":
            // clip=<id>: remove it and pull everything after it (clips and lower thirds) left to close the gap.
            // or from=<t> to=<t>: remove that time range across clips, then close the gap.
            var a: Double, b: Double
            if let f = num(c, "from"), let t = num(c, "to") { a = snap(f); b = snap(t) }
            else { let i = try clipIndex(c); a = project.clips[i].offset; b = a + project.clips[i].duration }
            guard b > a else { throw RenderError.message("empty range") }
            let gap = b - a
            try await mutate { p in
                self.splitAt(&p, a); self.splitAt(&p, b)
                let gone = Set(p.clips.filter { $0.offset >= a - self.frame * 0.25 && $0.offset + $0.duration <= b + self.frame * 0.25 }.map { $0.id })
                p.clips.removeAll { gone.contains($0.id) }
                self.rippleDelete(&p, a, b)
            }
            selectedClip = nil
            return ["removed": gap, "duration": built?.duration ?? 0]
        case "drag_edit":
            // clip=<id> mode=trim_start|trim_end|move delta=<seconds> [magnet_range=<seconds>]
            // Same code path as dragging with the mouse.
            let i = try clipIndex(c)
            let m = try need(DragMode(rawValue: str(c, "mode") ?? ""), "mode (trim_start, trim_end or move)")
            let delta = try need(num(c, "delta"), "delta"), mr = num(c, "magnet_range") ?? 0
            let magneticOn = c["magnetic"] == nil ? magnetic : flag(c, "magnetic")
            if magneticOn {
                let old = project.clips[i], end = old.offset + old.duration
                switch m {
                case .trimEnd:
                    let r = isolated(.trimEnd, old, delta: delta, magnetRange: mr)
                    try await mutate { p in p.clips[i] = r; self.rippleAfter(&p, from: end, by: r.duration - old.duration, except: old.id) }
                case .trimStart:
                    let r = isolated(.trimStart, old, delta: delta, magnetRange: mr)
                    let d = r.offset - old.offset
                    var n = r; n.offset = old.offset
                    try await mutate { p in
                        p.clips[i] = n
                        self.shiftConnected(&p, clip: old.id, by: -d)
                        self.rippleAfter(&p, from: end, by: -d, except: old.id)
                    }
                case .move:
                    // take the clip out, drop it where it lands (before the first clip whose middle is after the drop point), close all gaps
                    try await mutate { p in
                        var target = old.offset + delta
                        if mr > 0 { for e in p.clips.flatMap({ [$0.offset, $0.offset + $0.duration] }) + [self.playhead] where abs(e - target) <= mr { target = e } }
                        var rest = p.clips.filter { $0.id != old.id }.sorted { $0.offset < $1.offset }
                        let idx = rest.firstIndex { $0.offset + $0.duration / 2 > target } ?? rest.count
                        rest.insert(old, at: idx)
                        var t = 0.0
                        for k in rest.indices {
                            let d = t - rest[k].offset
                            self.shiftConnected(&p, clip: rest[k].id, by: d)
                            rest[k].offset = t; t += rest[k].duration
                        }
                        p.clips = rest
                    }
                }
                let r = project.clips.first { $0.id == old.id }!
                return ["clip": r.id, "offset": r.offset, "duration": r.duration, "source_in": r.sourceIn, "magnetic": true]
            }
            let r = try need(dragResult(m, clip: project.clips[i].id, delta: delta, magnetRange: mr), "clip")
            try await mutate { p in self.shiftConnected(&p, clip: r.id, by: r.offset - p.clips[i].offset); p.clips[i] = r }
            return ["clip": r.id, "offset": r.offset, "duration": r.duration, "source_in": r.sourceIn]
        case "import_fcpxml":
            // path=<.fcpxmld or .fcpxml> out=<project.cutgenie.json to write>. Read-only on the Final Cut project.
            let src = try need(str(c, "path"), "path")
            let outPath = try need(str(c, "out"), "out")
            let out = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: out.path) && !flag(c, "overwrite") {
                throw RenderError.message("output exists: \(out.path) (pass overwrite=true)")
            }
            var lutRel: String?
            if let lp = str(c, "lut") {
                let lsrc = URL(fileURLWithPath: (lp as NSString).expandingTildeInPath)
                _ = try LUTLoader.load(lsrc)
                let dir = out.deletingLastPathComponent().appendingPathComponent("LUTs")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(lsrc.lastPathComponent)
                if !FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.copyItem(at: lsrc, to: dest) }
                lutRel = "LUTs/" + lsrc.lastPathComponent
            }
            var (p, report) = try FCPXMLImport.run(path: src, lutPath: lutRel)
            p.liftBackgroundLanes()
            try p.save(to: out)
            try (report.joined(separator: "\n") + "\n").write(to: out.deletingPathExtension().appendingPathExtension("report.txt"), atomically: true, encoding: .utf8)
            if !flag(c, "no_open") { try await open(out.path) }
            return ["project_file": out.path, "report": report, "duration": built?.duration ?? p.totalDuration]
        case "set_setting":
            // key=colorPipeline value=raw|managed   key=colorSpace value=<project output space>   key=hdrToSdr value=soft|clip
            let k = try need(str(c, "key"), "key"), v = try need(str(c, "value"), "value")
            let ids = ColorSpaces.all.map { $0.id }
            switch k {
            case "colorPipeline": guard ["raw", "managed"].contains(v) else { throw RenderError.message("value must be raw or managed") }
                try await mutate { $0.settings.colorPipeline = v }
            case "colorSpace": guard ids.contains(v) else { throw RenderError.message("value must be one of: \(ids.joined(separator: ", "))") }
                try await mutate { $0.settings.colorSpace = v }
            case "hdrToSdr": guard ["soft", "clip"].contains(v) else { throw RenderError.message("value must be soft or clip") }
                try await mutate { $0.settings.hdrToSdr = v }
            case "wheelScale":
                guard let x = Double(v), x >= 0, x <= 3 else { throw RenderError.message("value must be a number 0...3") }
                try await mutate { $0.settings.wheelScale = x }
            case "wheelRange":
                guard let x = Double(v), x >= 0.1, x <= 4 else { throw RenderError.message("value must be a number 0.1...4") }
                try await mutate { $0.settings.wheelRange = x }
            case "wheelMid":
                guard let x = Double(v), x >= 0, x <= 2 else { throw RenderError.message("value must be a number 0...2") }
                try await mutate { $0.settings.wheelMid = x }
            default: throw RenderError.message("keys: colorPipeline, colorSpace, hdrToSdr, wheelScale, wheelRange, wheelMid")
            }
            return [:]
        case "probe_player":
            // Testing aid: grabs the frame the LIVE PLAYER composes at time= (what you see in the window) and saves it as PNG.
            let t = try need(num(c, "time"), "time")
            let out = URL(fileURLWithPath: ((try need(str(c, "out"), "out")) as NSString).expandingTildeInPath)
            player.pause()
            if !flag(c, "no_seek") { await player.seek(to: CMTime(seconds: t, preferredTimescale: 6000), toleranceBefore: .zero, toleranceAfter: .zero) }
            let vo = try need(playerOutput, "player output")
            var pb: CVPixelBuffer?
            for _ in 0..<40 {
                pb = vo.copyPixelBuffer(forItemTime: CMTime(seconds: t, preferredTimescale: 6000), itemTimeForDisplay: nil)
                if pb != nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try Renderer.writePNG(try need(pb, "player frame"), to: out)
            return ["file": out.path]
        case "snapshot_ui":
            // Testing aid: the app renders its own interface (view=color|window) to a PNG. Needs no screen permission.
            let out = try need(str(c, "out"), "out")
            let ok = snapshotUI?(str(c, "view") ?? "color", out) ?? false
            if !ok { throw RenderError.message("could not render the interface") }
            return ["file": out]
        case "convert_probe":
            // from= to= (colour space ids) r= g= b= (0...1) [tone_map=soft|clip]: runs the real conversion on one colour
            let f = try need(str(c, "from"), "from"), t = try need(str(c, "to"), "to")
            let o = Renderer.probeConvert(from: f, to: t, rgb: [try need(num(c, "r"), "r"), try need(num(c, "g"), "g"), try need(num(c, "b"), "b")], toneMap: str(c, "tone_map") ?? "soft")
            return ["result": o]
        case "set_display":
            // gamma=<0.8...1.1> : window-only display curve (testing aid / same as the panel slider)
            if let g = num(c, "gamma") { displayGamma = min(max(g, 0.8), 1.1) }
            if let w = num(c, "warmth") { displayWarmth = min(max(w, -10), 10) }
            refreshFrame()
            return ["gamma": displayGamma, "warmth": displayWarmth]
        case "set_eq":
            // band=<index> (index = count adds a band, max 10) type=bell|lowshelf|highshelf|highpass|lowpass|notch freq= gain= q= enabled=   or eq_enabled=
            let types = ["bell", "lowshelf", "highshelf", "highpass", "lowpass", "notch"]
            if let t = str(c, "type"), !types.contains(t) { throw RenderError.message("type must be one of \(types.joined(separator: ", "))") }
            let cur = audioChain
            if let bi = num(c, "band").map({ Int($0) }) {
                guard bi >= 0, bi <= cur.eq.count, bi < 10 else { throw RenderError.message("band must be 0...\(min(cur.eq.count, 9))") }
            }
            audioEdit(live: flag(c, "live")) { ch in
                if c["eq_enabled"] != nil { ch.eqEnabled = self.flag(c, "eq_enabled") }
                guard let bi = self.num(c, "band").map({ Int($0) }) else { return }
                if bi == ch.eq.count { ch.eq.append(EQBand()) }
                var b = ch.eq[bi]
                if let t = self.str(c, "type") { b.type = t }
                if let v = self.num(c, "freq") { b.freq = min(max(v, 20), 20000) }
                if let v = self.num(c, "gain") { b.gainDb = min(max(v, -24), 24) }
                if let v = self.num(c, "q") { b.q = min(max(v, 0.1), 18) }
                if c["enabled"] != nil { b.enabled = self.flag(c, "enabled") }
                ch.eq[bi] = b
            }
            return ["bands": audioChain.eq.count]
        case "remove_eq":
            let bi = Int(try need(num(c, "band"), "band"))
            guard audioChain.eq.indices.contains(bi) else { throw RenderError.message("no band \(bi)") }
            audioEdit(live: false) { $0.eq.remove(at: bi) }
            return ["bands": audioChain.eq.count]
        case "set_gate":
            audioEdit(live: flag(c, "live")) { ch in
                if c["enabled"] != nil { ch.gate.enabled = self.flag(c, "enabled") }
                if let v = self.num(c, "threshold") { ch.gate.thresholdDb = min(max(v, -100), 0) }
                if let v = self.num(c, "range") { ch.gate.rangeDb = min(max(v, -100), 0) }
                if let v = self.num(c, "attack") { ch.gate.attackMs = min(max(v, 0.1), 500) }
                if let v = self.num(c, "release") { ch.gate.releaseMs = min(max(v, 1), 5000) }
            }
            return [:]
        case "set_comp":
            audioEdit(live: flag(c, "live")) { ch in
                if c["enabled"] != nil { ch.compressor.enabled = self.flag(c, "enabled") }
                if let v = self.num(c, "threshold") { ch.compressor.thresholdDb = min(max(v, -60), 0) }
                if let v = self.num(c, "ratio") { ch.compressor.ratio = min(max(v, 1), 30) }
                if let v = self.num(c, "attack") { ch.compressor.attackMs = min(max(v, 0.1), 500) }
                if let v = self.num(c, "release") { ch.compressor.releaseMs = min(max(v, 1), 5000) }
                if let v = self.num(c, "knee") { ch.compressor.kneeDb = min(max(v, 0), 24) }
                if let v = self.num(c, "makeup") { ch.compressor.makeupDb = min(max(v, -24), 24) }
            }
            return [:]
        case "set_limiter":
            audioEdit(live: flag(c, "live")) { ch in
                if c["enabled"] != nil { ch.limiter.enabled = self.flag(c, "enabled") }
                if let v = self.num(c, "ceiling") { ch.limiter.ceilingDb = min(max(v, -24), 0) }
                if let v = self.num(c, "release") { ch.limiter.releaseMs = min(max(v, 1), 2000) }
                if let v = self.num(c, "lookahead") { ch.limiter.lookaheadMs = min(max(v, 0), 20) }
            }
            return [:]
        case "set_output":
            let g = try need(num(c, "gain"), "gain")
            audioEdit(live: flag(c, "live")) { $0.outputGainDb = min(max(g, -40), 40) }
            return [:]
        case "commit_audio":
            commitLive(); return [:]
        case "analyze_audio":
            // integrated loudness (LUFS, ITU-R BS.1770) and sample peak of the processed sound; optional from= to= seconds
            let b = try need(built, "no project open")
            let r = try await Task.detached { try Loudness.measure(b, from: c["from"] as? Double, to: c["to"] as? Double) }.value
            lastLoudness = LoudnessResult(lufs: r.lufs, peakDb: r.peakDb)
            return ["lufs": (r.lufs * 10).rounded() / 10, "peak_db": (r.peakDb * 10).rounded() / 10, "seconds": r.seconds]
        case "match_loudness":
            // sets Output gain so the integrated loudness reaches target= (default -14 LUFS); the limiter (if on) keeps peaks under its ceiling
            let target = num(c, "target") ?? -14
            let b = try need(built, "no project open")
            let base = project
            var last = 0.0
            for _ in 0..<3 {
                let r = try await Task.detached { try Loudness.measure(b, from: c["from"] as? Double, to: c["to"] as? Double) }.value
                last = r.lufs
                if abs(r.lufs - target) < 0.2 { break }
                var ch = chain(for: "A1"); ch.outputGainDb += target - r.lufs; ch.targetLUFS = target
                project.audioChain = ch; b.audioStore.set(ch)
            }
            let r = try await Task.detached { try Loudness.measure(b, from: c["from"] as? Double, to: c["to"] as? Double) }.value
            lastLoudness = LoudnessResult(lufs: r.lufs, peakDb: r.peakDb)
            if base != project { undoStack.append(base); redoStack = [] }
            _ = last
            return ["lufs": (r.lufs * 10).rounded() / 10, "peak_db": (r.peakDb * 10).rounded() / 10, "output_gain_db": (chain(for: "A1").outputGainDb * 10).rounded() / 10]
        case "show":
            // tab=color|audio : which panel the window shows
            inspectorTab = ["audio", "clip"].contains(str(c, "tab") ?? "") ? str(c, "tab")! : "color"; return [:]
        case "audio_debug":
            if flag(c, "reset") { AudioDebug.peakIn = 0; AudioDebug.peakOut = 0; AudioDebug.calls = 0; AudioDebug.frames = 0; return [:] }
            return ["calls": AudioDebug.calls, "frames": AudioDebug.frames, "peak_in": Double(AudioDebug.peakIn), "peak_out": Double(AudioDebug.peakOut), "resets": AudioDebug.resets, "meter_db": meter.meterDb, "rms_db": meter.rmsDb, "lufs_m": meter.momentaryLUFS, "hold_db": meter.peakHoldDb, "meter_raw": Double(AudioDebug.meter), "tab": inspectorTab, "overs": AudioDebug.overs,
                    "fmt": AudioDebug.fmt, "rate": Double(player.rate), "volume": Double(player.volume), "muted": player.isMuted,
                    "item": "\(player.currentItem?.status.rawValue ?? -1)", "err": player.currentItem?.error?.localizedDescription ?? ""]
        case "segments":
            // testing aid: the picture track's segments between from= and to=
            let b = try need(built, "no project")
            let f = num(c, "from") ?? 0, t = num(c, "to") ?? 1e9
            let segs = b.composition.tracks(withMediaType: .video).first?.segments ?? []
            return ["filler": FillerDebug.message, "segments": segs.filter { $0.timeMapping.target.end.seconds > f && $0.timeMapping.target.start.seconds < t }.map {
                ["start": $0.timeMapping.target.start.seconds, "end": $0.timeMapping.target.end.seconds, "empty": $0.isEmpty, "src": $0.timeMapping.source.duration.seconds] }]
        case "overlay_edit":
            // id=<graphic id> [offset=] [duration=] [trim_start=<seconds to remove from the start, negative extends>]
            let id = try need(str(c, "id"), "id")
            guard let i = project.overlays?.firstIndex(where: { $0.id == id }) else { throw RenderError.message("no graphic \(id)") }
            try await mutate { p in
                var o = p.overlays![i]
                if let d = self.num(c, "trim_start") {
                    let dd = max(min(d, o.duration - self.frame), -o.offset)
                    o.offset += dd; o.duration -= dd
                    // keep the animation where it was in time
                    o.position = o.position.map { Keyframe(t: $0.t - dd, v: $0.v) }
                    o.scale = o.scale.map { Keyframe(t: $0.t - dd, v: $0.v) }
                    o.opacity = o.opacity.map { Keyframe(t: $0.t - dd, v: $0.v) }
                }
                if let v = self.num(c, "offset") {
                    o.offset = max(0, self.snap(v))
                    o.connectedTo = p.clips.first { o.offset >= $0.offset - 0.001 && o.offset < $0.offset + $0.duration }?.id
                }
                if let v = self.num(c, "duration") { o.duration = max(self.frame, self.snap(v)) }
                if let v = self.num(c, "lane"), Int(v) != 0 { o.lane = Int(v); p.gfxLanes = max(p.gfxLanes ?? 0, o.lane) }
                p.overlays![i] = o
            }
            return ["id": id]
        case "overlay_delete":
            let id = try need(str(c, "id"), "id")
            guard project.overlays?.contains(where: { $0.id == id }) == true else { throw RenderError.message("no graphic \(id)") }
            try await mutate { $0.overlays?.removeAll { $0.id == id } }
            if selectedOverlay == id { selectedOverlay = nil }
            return [:]
        case "scroll_by":
            // dx= dy= : move the timeline view (testing smoothness)
            scrollBy(num(c, "dx") ?? 0, num(c, "dy") ?? 0); return ["scroll_x": scrollX]
        case "zoom":
            // pps=<pixels per second> : timeline zoom (same as the slider / ⌘+scroll)
            zoom(to: try need(num(c, "pps"), "pps")); return ["pps": pxPerSec, "scroll_x": scrollX]
        case "set_mode":
            // magnetic=true|false snapping=true|false
            if c["magnetic"] != nil { magnetic = flag(c, "magnetic") }
            if c["snapping"] != nil { snapping = flag(c, "snapping") }
            return ["magnetic": magnetic, "snapping": snapping]
        case "shuttle":
            // rate= : J/K/L style playback speed (negative = backwards)
            let r = try need(num(c, "rate"), "rate"); player.rate = Float(r); return ["rate": r]
        case "nudge":
            // frames= : move the selected clip or graphic by whole frames (Final Cut , and .)
            let n = try need(num(c, "frames"), "frames")
            if let o = selectedOverlay, let ov = project.overlays?.first(where: { $0.id == o }) {
                return try await run("overlay_edit", ["id": o, "offset": max(0, ov.offset + n * frame)])
            }
            let id = try need(selectedClip, "a selected clip or graphic")
            return try await run("drag_edit", ["clip": id, "mode": "move", "delta": n * frame, "magnetic": false])
        case "select_items":
            // ids=a,b,c (clip or graphic ids)  [add=true]   or  all=true
            if flag(c, "all") { selection = Set(project.clips.map { $0.id } + (project.overlays ?? []).map { $0.id }) }
            else {
                let ids = (str(c, "ids") ?? "").split(separator: ",").map(String.init)
                selection = flag(c, "add") ? selection.union(ids) : Set(ids)
            }
            return ["selected": selection.count]
        case "magnetic_drop_x":
            // clip= delta= : where a magnetic move would land (time of the insertion point)
            let i = try clipIndex(c); let old = project.clips[i]
            let target = old.offset + (try need(num(c, "delta"), "delta"))
            let rest = project.clips.filter { $0.id != old.id }.sorted { $0.offset < $1.offset }
            let idx = rest.firstIndex { $0.offset + $0.duration / 2 > target } ?? rest.count
            return ["time": rest.prefix(idx).reduce(0) { $0 + $1.duration }]
        case "copy", "cut":
            let ids = selection.isEmpty ? Set([selectedClip, selectedOverlay].compactMap { $0 }) : selection
            guard !ids.isEmpty else { throw RenderError.message("Select something to \(name) first") }
            if name == "copy", let first = (project.clips + (project.upperClips ?? [])).filter({ ids.contains($0.id) }).min(by: { $0.offset < $1.offset }) { attrClip = first }
            let cl = project.clips.filter { ids.contains($0.id) }.sorted { $0.offset < $1.offset }
            let cids = Set(cl.map { $0.id })
            // connected graphics travel with their clip (Final Cut), plus any graphic selected on its own
            let ov = (project.overlays ?? []).filter { ids.contains($0.id) || ($0.connectedTo.map { cids.contains($0) } ?? false) }
            let au = (project.audioClips ?? []).filter { ids.contains($0.id) }
            let start = (cl.map { $0.offset } + ov.map { $0.offset } + au.map { $0.offset }).min() ?? 0
            clipboard = (cl, ov, au, start)
            if name == "cut" { selection = ids; _ = try await run("delete_selected", ["ripple": true]) }
            return ["clips": cl.count, "graphics": ov.count, "audio": au.count]
        case "paste":
            // at= (default playhead). Clips are inserted into the main storyline (later clips move right); graphics and
            // audio clips go on top at the same relative times, each on the first track with room.
            guard let cb = clipboard else { throw RenderError.message("Nothing copied yet (⌘C)") }
            let t = snap(num(c, "at") ?? playhead)
            var newSel = Set<String>()
            try await mutate { p in
                var idMap: [String: String] = [:]
                if !cb.clips.isEmpty {
                    self.splitAt(&p, t)
                    let total = cb.clips.reduce(0) { $0 + $1.duration }
                    self.rippleAfter(&p, from: t, by: total, except: nil)
                    var pos = t
                    for var k in cb.clips {
                        let nid = self.newClipID(p); idMap[k.id] = nid
                        k.id = nid; k.offset = pos; pos += k.duration
                        p.clips.append(k); newSel.insert(nid)
                    }
                    p.clips.sort { $0.offset < $1.offset }
                }
                var ov = p.overlays ?? []
                for var o in cb.overlays {
                    var n = ov.count + 1; while ov.contains(where: { $0.id == "g\(n)" }) { n += 1 }
                    o.id = "g\(n)"; o.offset = t + (o.offset - cb.start)
                    if let cn = o.connectedTo, let m = idMap[cn] { o.connectedTo = m } else { o.connectedTo = p.clips.first { o.offset >= $0.offset && o.offset < $0.offset + $0.duration }?.id }
                    let oo = o
                    while ov.contains(where: { $0.lane == o.lane && $0.offset < oo.offset + oo.duration - 0.001 && oo.offset < $0.offset + $0.duration - 0.001 }) || !self.synced(p, video: o.lane) { o.lane += o.lane >= 0 ? 1 : -1 }
                    ov.append(o); newSel.insert(o.id)
                }
                if !cb.overlays.isEmpty { p.overlays = ov; p.gfxLanes = max(p.gfxLanes ?? 0, ov.map { $0.lane }.max() ?? 0) }
                var ac = p.audioClips ?? []
                for var a in cb.audio {
                    var n = ac.count + 1; while ac.contains(where: { $0.id == "au\(n)" }) { n += 1 }
                    a.id = "au\(n)"; a.offset = t + (a.offset - cb.start); a.link = nil; a.syncWith = nil
                    let aa = a
                    while ac.contains(where: { $0.lane == a.lane && $0.offset < aa.offset + aa.duration - 0.001 && aa.offset < $0.offset + $0.duration - 0.001 }) || !self.synced(p, audio: a.lane) { a.lane += 1 }
                    ac.append(a); newSel.insert(a.id)
                }
                if !cb.audio.isEmpty { p.audioClips = ac; p.audioLanes = max(p.audioLanes ?? 0, (ac.map { $0.lane }.max() ?? 1) - 1) }
            }
            selection = newSel
            return ["pasted": newSel.count]
        case "match_input_luts":
            // every clip without an Input LUT gets the one other clips of the same kind (HLG / PQ) already use
            var n = 0
            var plan: [(Int, LUTSlot)] = []
            for i in project.gradeIndices {
                guard let cl = project.gradeClip(i), !(cl.color.luts ?? []).contains(where: { $0.slot == "input" }),
                      let h = assetFormat[cl.asset]?.hdr, let l = inputLUT(forHDR: h) else { continue }
                plan.append((i, l))
            }
            guard !plan.isEmpty else { throw RenderError.message("Every HLG / PQ clip already has an Input LUT (or no clip has one to copy).") }
            try await mutate { p in for (i, l) in plan { p.editColor(i) { $0.luts = ($0.luts ?? []) + [l] }; n += 1 } }
            lastMessage = "Added the Input LUT to \(n) clip\(n == 1 ? "" : "s")"
            return ["clips": n]
        case "project_settings":
            // [width=] [height=] [fps=] [fit=fit|fill|none] : the project's format (Project settings window)
            var st = project.settings
            if let w = num(c, "width") { st.width = max(16, Int(w) / 2 * 2) }
            if let h = num(c, "height") { st.height = max(16, Int(h) / 2 * 2) }
            if let f = num(c, "fps") { st.fps = f }
            if let f = str(c, "fit") { st.fit = f == "fit" ? nil : f }
            let oldFrame = frame, newSt = st
            var moved = 0
            try await mutate { p in
                p.settings = newSt
                // a new frame rate: every edit point goes onto the new frame grid
                if abs(1 / oldFrame - Self.exact(newSt.fps)) > 0.001 {
                    let fr = 1 / Self.exact(newSt.fps)
                    func q(_ t: Double) -> Double { (t / fr).rounded() * fr }
                    func fix(_ o: Double, _ d: Double) -> (Double, Double) { let a = q(o), b = q(o + d); if abs(a - o) > 0.0005 || abs(b - o - d) > 0.0005 { moved += 1 }; return (a, max(fr, b - a)) }
                    for k in p.clips.indices { (p.clips[k].offset, p.clips[k].duration) = fix(p.clips[k].offset, p.clips[k].duration) }
                    if var u = p.upperClips { for k in u.indices { (u[k].offset, u[k].duration) = fix(u[k].offset, u[k].duration) }; p.upperClips = u }
                    if var u = p.audioClips { for k in u.indices { (u[k].offset, u[k].duration) = fix(u[k].offset, u[k].duration) }; p.audioClips = u }
                    if var u = p.overlays { for k in u.indices { (u[k].offset, u[k].duration) = fix(u[k].offset, u[k].duration) }; p.overlays = u }
                }
            }
            lastMessage = moved > 0 ? "Project set to \(st.width)×\(st.height) at \(Self.fpsName(st.fps)) fps - \(moved) edit points moved onto the new frames" : "Project set to \(st.width)×\(st.height) at \(Self.fpsName(st.fps)) fps"
            return ["width": st.width, "height": st.height, "fps": st.fps, "moved": moved]
        case "match_clip":
            // asset=<id> or path= : take that clip's size and frame rate for the project
            let url: URL
            if let a = str(c, "asset") { url = try need(project.resolve(a, base: base), "asset") } else { url = URL(fileURLWithPath: try need(str(c, "path"), "asset or path")) }
            guard let f = await MediaFormat.read(url) else { throw RenderError.message("Couldn't read that clip's format") }
            offerMatch = nil
            return try await run("project_settings", ["width": f.width, "height": f.height, "fps": f.fps])
        case "slow_motion":
            // clip= : a high-frame-rate clip plays every recorded frame (60 fps in a 23.98 project = 40 % smooth slow motion)
            let id = try need(str(c, "clip"), "clip")
            guard let cl = (project.clips + (project.upperClips ?? [])).first(where: { $0.id == id }), let f = assetFormat[cl.asset] else { throw RenderError.message("no clip \(id)") }
            let k = exactFPS / f.fps
            guard k < 0.95 else { throw RenderError.message("This clip was recorded at \(Self.fpsName(f.fps)) fps - it needs a higher frame rate than the project (\(Self.fpsName(project.settings.fps))) for slow motion") }
            return try await run("set_speed", ["clip": id, "speed": k])
        case "new_project":
            // path= [width=] [height=] [fps=] : an empty project saved there and opened
            let path = ((try need(str(c, "path"), "path")) as NSString).expandingTildeInPath
            guard !FileManager.default.fileExists(atPath: path) else { throw RenderError.message("A project with that name already exists") }
            var np = Project()
            if let w = num(c, "width") { np.settings.width = Int(w) }; if let h = num(c, "height") { np.settings.height = Int(h) }; if let f = num(c, "fps") { np.settings.fps = f }
            try np.save(to: URL(fileURLWithPath: path))
            try await open(path)
            return ["path": path]
        case "duplicate_project":
            // path=<new file> [vertical=true] : a copy of this project (vertical: 9:16 with every clip filling the frame)
            let path = ((try need(str(c, "path"), "path")) as NSString).expandingTildeInPath
            guard !FileManager.default.fileExists(atPath: path) else { throw RenderError.message("A project with that name already exists") }
            var np = project
            if flag(c, "vertical") {
                let w = np.settings.width, h = np.settings.height
                let short = min(w, h)
                np.settings.width = short; np.settings.height = short * 16 / 9 / 2 * 2; np.settings.fit = "fill"
            }
            // keep media paths working from the new place
            let newBase = URL(fileURLWithPath: path).deletingLastPathComponent()
            for k in np.assets.indices where !np.assets[k].path.hasPrefix("/") {
                if let u = project.resolve(np.assets[k].id, base: base) { np.assets[k].path = u.standardizedFileURL.path }
            }
            _ = newBase
            try np.save(to: URL(fileURLWithPath: path))
            return ["path": path]
        case "detach_audio", "link_audio", "toggle_link":
            // ONE idea for every video track (V1 included): a clip's sound is either linked to it or not (⌘L toggles, ⌃⇧S too).
            // Unlink: the sound becomes its own clip in place and moves on its own. Link: selected sound follows the selected picture.
            var ids = str(c, "clip").map { Set([$0]) } ?? str(c, "ids").map { Set($0.split(separator: ",").map(String.init)) }
                ?? (selection.isEmpty ? Set([selectedClip].compactMap { $0 }) : selection)
            let allV = project.clips + (project.upperClips ?? [])
            for a in project.audioClips ?? [] where a.link.map({ ids.contains($0) }) ?? false { ids.insert(a.id) }
            let vids = allV.filter { ids.contains($0.id) }
            let auds = (project.audioClips ?? []).filter { ids.contains($0.id) }
            let joined = vids.filter { $0.audioDetached != true }
            let linked = auds.filter { $0.link != nil }
            let unlink = name == "detach_audio" || (name == "toggle_link" && (!joined.isEmpty || !linked.isEmpty))
            if unlink {
                let fixedSpeed = joined.filter { abs($0.sp - 1) > 0.0001 }
                let split = joined.filter { abs($0.sp - 1) <= 0.0001 }
                guard !split.isEmpty || !linked.isEmpty else {
                    throw RenderError.message(fixedSpeed.isEmpty ? "Nothing selected is linked." : "Unlink isn't available on speed-changed clips yet - set the speed back to 100 % first")
                }
                var made: [String] = []
                try await mutate { p in
                    for k in (p.audioClips ?? []).indices where linked.contains(where: { $0.id == p.audioClips![k].id }) {
                        p.audioClips![k].syncWith = p.audioClips![k].link; p.audioClips![k].link = nil
                    }
                    for cl in split {
                        let i = p.clips.firstIndex(where: { $0.id == cl.id }), u = p.upperClips?.firstIndex(where: { $0.id == cl.id })
                        if let i { p.clips[i].audioDetached = true } else if let u { p.upperClips![u].audioDetached = true } else { continue }
                        var ac = p.audioClips ?? []
                        var n = ac.count + 1; while ac.contains(where: { $0.id == "au\(n)" }) { n += 1 }
                        let src = cl.audioSource?.asset ?? cl.asset
                        // V1 sound stays on A1 where it was; sound of V2+ clips goes to the first free track from A2
                        let lane = i != nil ? self.freeAudioLane(p, cl.offset, cl.duration) : self.freeAudioLane2(p, cl.offset, cl.duration)
                        let nm = (p.assets.first { $0.id == src }?.path as NSString?)?.lastPathComponent ?? "audio"
                        var a = AudioClip(id: "au\(n)", asset: src, name: nm, lane: lane, offset: cl.offset, sourceIn: cl.audioSource?.sourceIn ?? cl.sourceIn, duration: cl.duration, gainDb: cl.audio.gainDb, keys: cl.audio.keys, fadeIn: cl.audio.fadeIn, fadeOut: cl.audio.fadeOut)
                        a.syncWith = cl.id
                        ac.append(a); p.audioClips = ac; p.audioLanes = max(p.audioLanes ?? 0, lane - 1)
                        made.append(a.id)
                    }
                }
                lastMessage = "Unlinked - picture and sound now move on their own"
                selection = Set(made + linked.map { $0.id })
                return ["unlinked": made + linked.map { $0.id }, "audio_clips": made]
            }
            // Link
            let free = auds.filter { $0.link == nil }
            guard !free.isEmpty else { throw RenderError.message("Select a video clip and the sound to link to it (⌘-click both).") }
            var pairs: [(String, String)] = []
            for a in free {
                let own = vids.first { ($0.audioSource?.asset ?? $0.asset) == a.asset && $0.offset < a.offset + a.duration && a.offset < $0.offset + $0.duration }
                if vids.count == 1 { pairs.append((a.id, vids[0].id)) }
                else if let v = own { pairs.append((a.id, v.id)) }
                else if vids.isEmpty, let w = a.syncWith, allV.contains(where: { $0.id == w }) { pairs.append((a.id, w)) }   // back to the picture it came from
                else { throw RenderError.message(vids.isEmpty ? "Select the video clip to link this sound to as well (⌘-click it)." : "Select one video clip, or clips whose own sound is selected, to link.") }
            }
            let pm = Dictionary(uniqueKeysWithValues: pairs)
            try await mutate { p in for k in (p.audioClips ?? []).indices { if let v = pm[p.audioClips![k].id] { p.audioClips![k].link = v; p.audioClips![k].syncWith = nil } } }
            lastMessage = pairs.count == 1 ? "Linked - the sound now moves with its picture" : "Linked \(pairs.count) sounds to their pictures"
            selection = Set(pairs.map { $0.0 } + pairs.map { $0.1 })
            return ["linked": pairs.map { $0.0 }]
        case "group":
            // ids= (default: selection) [name=] : ties them together (⌘G)
            let ids = str(c, "ids").map { Set($0.split(separator: ",").map(String.init)) } ?? selection
            guard ids.count > 1 else { throw RenderError.message("Select two or more items to group.") }
            let gs = project.groups ?? []
            var n = gs.count + 1; while gs.contains(where: { $0.id == "grp\(n)" }) { n += 1 }
            let g = ClipGroup(id: "grp\(n)", name: str(c, "name") ?? "Group \(n)", color: n % 6, members: Array(ids).sorted())
            try await mutate { p in
                // an item is in one group at a time: the new group takes in any group it touches
                var keep: [ClipGroup] = []; var mem = Set(g.members)
                for x in p.groups ?? [] { if x.members.contains(where: { mem.contains($0) }) { mem.formUnion(x.members) } else { keep.append(x) } }
                var ng = g; ng.members = Array(mem).sorted()
                p.groups = keep + [ng]
            }
            return ["group": g.id, "items": ids.count]
        case "ungroup":
            let ids = str(c, "ids").map { Set($0.split(separator: ",").map(String.init)) } ?? selection
            guard (project.groups ?? []).contains(where: { $0.members.contains(where: { ids.contains($0) }) }) else { throw RenderError.message("Nothing selected is in a group.") }
            try await mutate { p in p.groups = (p.groups ?? []).filter { !$0.members.contains(where: { ids.contains($0) }) }; if p.groups?.isEmpty == true { p.groups = nil } }
            return [:]
        case "rename_group":
            let id = try need(str(c, "id"), "id"), nm = try need(str(c, "name"), "name")
            try await mutate { p in for k in (p.groups ?? []).indices where p.groups![k].id == id { p.groups![k].name = nm } }
            return [:]
        case "select_forward":
            // at= : selects everything that starts at or after this time, on every track
            let t = num(c, "at") ?? playhead, e = 0.001
            selection = Set(project.clips.filter { $0.offset >= t - e }.map { $0.id } + (project.upperClips ?? []).filter { $0.offset >= t - e }.map { $0.id }
                            + (project.overlays ?? []).filter { $0.offset >= t - e }.map { $0.id } + (project.audioClips ?? []).filter { $0.offset >= t - e }.map { $0.id })
            .filter { lockedTrack(of: $0) == nil }
            return ["selected": selection.count]
        case "move_items":
            // ids= (default: selection) delta=<seconds> : moves all of them by the same amount, each on its own track
            let ids = (str(c, "ids").map { Set($0.split(separator: ",").map(String.init)) } ?? selection).filter { lockedTrack(of: $0) == nil }
            var d = snap(try need(num(c, "delta"), "delta"))
            let v1 = project.clips.filter { ids.contains($0.id) }, v1ids = Set(v1.map { $0.id })
            let ups = (project.upperClips ?? []).filter { ids.contains($0.id) }, upIds = Set(ups.map { $0.id })
            let ovs = (project.overlays ?? []).filter { ids.contains($0.id) || ($0.connectedTo.map { v1ids.contains($0) } ?? false) }
            let aus = (project.audioClips ?? []).filter { ids.contains($0.id) || ($0.link.map { upIds.contains($0) } ?? false) }
            let starts = v1.map { $0.offset } + ups.map { $0.offset } + ovs.map { $0.offset } + aus.map { $0.offset }
            guard let first = starts.min() else { throw RenderError.message("Select something to move.") }
            d = max(d, -first)
            guard abs(d) > 0.0001 else { return ["moved": 0] }
            func hit(_ a: Double, _ ad: Double, _ b: Double, _ bd: Double) -> Bool { a < b + bd - 0.001 && b < a + ad - 0.001 }
            let ovIds = Set(ovs.map { $0.id }), auIds = Set(aus.map { $0.id })
            for x in v1 where project.clips.contains(where: { !v1ids.contains($0.id) && hit(x.offset + d, x.duration, $0.offset, $0.duration) }) {
                throw RenderError.message("That would push V1 clips on top of other V1 clips. Move them to an empty part, or include the clips in the way.")
            }
            for x in ups where (project.upperClips ?? []).contains(where: { !upIds.contains($0.id) && ($0.lane ?? 1) == (x.lane ?? 1) && hit(x.offset + d, x.duration, $0.offset, $0.duration) })
                || (project.overlays ?? []).contains(where: { !ovIds.contains($0.id) && $0.lane == (x.lane ?? 1) && hit(x.offset + d, x.duration, $0.offset, $0.duration) }) {
                throw RenderError.message("V\((x.lane ?? 1) + 1) already has something there.")
            }
            for x in aus where (project.audioClips ?? []).contains(where: { !auIds.contains($0.id) && $0.lane == x.lane && hit(x.offset + d, x.duration, $0.offset, $0.duration) })
                || (x.lane <= 1 && project.clips.contains(where: { !v1ids.contains($0.id) && $0.audioDetached != true && hit(x.offset + d, x.duration, $0.offset, $0.duration) })) {
                throw RenderError.message("A\(x.lane) already has sound there.")
            }
            try await mutate { p in
                for k in p.clips.indices where v1ids.contains(p.clips[k].id) { p.clips[k].offset += d }
                p.clips.sort { $0.offset < $1.offset }
                for k in (p.upperClips ?? []).indices where upIds.contains(p.upperClips![k].id) { p.upperClips![k].offset += d }
                for k in (p.overlays ?? []).indices where ovIds.contains(p.overlays![k].id) { p.overlays![k].offset += d }
                for k in (p.audioClips ?? []).indices where auIds.contains(p.audioClips![k].id) { p.audioClips![k].offset += d }
                if var mk = p.markers { for k in mk.indices where mk[k].clip.map({ v1ids.contains($0) || upIds.contains($0) }) ?? false { mk[k].time += d }; p.markers = mk }
            }
            return ["moved": v1.count + ups.count + ovs.count + aus.count, "delta": d]
        case "resync_audio":
            // id=<audio clip> : moves an unlinked / linked sound back in line with its video clip
            let id = try need(str(c, "id"), "id")
            guard let a = project.audioClips?.first(where: { $0.id == id }), let vid = a.link ?? a.syncWith,
                  let v = (project.clips + (project.upperClips ?? [])).first(where: { $0.id == vid }) else { throw RenderError.message("This sound has no video clip to sync with") }
            let want = max(0, snap(v.offset - (v.audioSource?.sourceIn ?? v.sourceIn) + a.sourceIn))
            noReconcile = true; defer { noReconcile = false }
            try await mutate { p in for k in (p.audioClips ?? []).indices where p.audioClips![k].id == id { p.audioClips![k].offset = want } }
            return ["id": id, "offset": want]
        case "relink_audio":
            // id=<audio clip> : links an unlinked sound to its video clip again
            let id = try need(str(c, "id"), "id")
            try await mutate { p in for k in (p.audioClips ?? []).indices where p.audioClips![k].id == id { if let w = p.audioClips![k].syncWith { p.audioClips![k].link = w; p.audioClips![k].syncWith = nil } } }
            return ["id": id]
        case "lib_add":
            // path=<folder or file>[,<more>] : adds to the media library (testing / automation)
            let ps = try need(str(c, "path"), "path").split(separator: ",").map { (String($0) as NSString).expandingTildeInPath }
            await MediaLibrary.shared.add(paths: ps, watch: !flag(c, "no_watch"))
            return ["items": MediaLibrary.shared.items.count]
        case "lib_list":
            let lib = MediaLibrary.shared
            return ["items": lib.items.map { ["name": $0.name, "kind": $0.kind, "duration": $0.duration, "hdr": $0.hdr ?? "", "audio": $0.hasAudio,
                                             "size": "\($0.width ?? 0)x\($0.height ?? 0)", "camera": $0.camera ?? "", "rating": $0.rating] },
                    "folders": lib.folders.map { $0.path }, "ranges": lib.ranges.count, "collections": lib.collections.map { $0.name }]
        case "sync_clips":
            // ids= (default: selection) [ref=<id>] : lines the clips up with the reference by their SOUND (multi-camera, separate mic).
            // Reference = ref=, else the selected V1 clip, else the lowest video track, else the first audio clip. Only V2+ video
            // clips and audio-track clips move (V1 is the storyline); a clip's linked sound / picture moves with it.
            var ids = str(c, "ids").map { Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) } ?? selection
            if ids.isEmpty, let s = selectedClip { ids = [s] }
            let ups = project.upperClips ?? [], acs = project.audioClips ?? []
            // a linked sound stands for its picture
            ids = Set(ids.map { id in acs.first { $0.id == id }?.link.flatMap { l in ups.contains { $0.id == l } ? l : nil } ?? id })
            struct Item { let id: String; let kind: Int; let asset: String; let sIn: Double; let off: Double; let dur: Double }   // kind 0 V1, 1 V2+, 2 audio
            var items: [Item] = []
            for cl in project.clips where ids.contains(cl.id) {
                guard abs(cl.sp - 1) < 0.0001 else { throw RenderError.message("One of the clips has a changed speed. Set it back to 100 % first.") }
                items.append(Item(id: cl.id, kind: 0, asset: cl.audioSource?.asset ?? cl.asset, sIn: cl.audioSource?.sourceIn ?? cl.sourceIn, off: cl.offset, dur: cl.duration))
            }
            for cl in ups where ids.contains(cl.id) {
                guard abs(cl.sp - 1) < 0.0001 else { throw RenderError.message("One of the clips has a changed speed. Set it back to 100 % first.") }
                if cl.audioDetached == true, let a = acs.first(where: { $0.link == cl.id }) {
                    items.append(Item(id: cl.id, kind: 1, asset: a.asset, sIn: a.sourceIn + (cl.offset - a.offset), off: cl.offset, dur: cl.duration))
                } else {
                    items.append(Item(id: cl.id, kind: 1, asset: cl.audioSource?.asset ?? cl.asset, sIn: cl.audioSource?.sourceIn ?? cl.sourceIn, off: cl.offset, dur: cl.duration))
                }
            }
            for a in acs where ids.contains(a.id) { items.append(Item(id: a.id, kind: 2, asset: a.asset, sIn: a.sourceIn, off: a.offset, dur: a.duration)) }
            let refItem: Item
            if let r = str(c, "ref") { refItem = try need(items.first { $0.id == r }, "ref '\(r)' among the selected clips") }
            else {
                let ordered = items.sorted { ($0.kind, $0.off) < ($1.kind, $1.off) }
                guard let f = ordered.first else { throw RenderError.message("No clips are selected. Graphics and titles have no sound, so they can't be synced.") }; refItem = f
            }
            if items.count < 2 { throw RenderError.message(items.isEmpty ? "No clips are selected." : "Only one clip is selected.") }
            let others = items.filter { $0.id != refItem.id && $0.kind != 0 }
            guard !others.isEmpty else {
                throw RenderError.message("All the selected clips are on V1. V1 is the main storyline and stays where it is, so there is nothing to move.")
            }
            try refuseIfLocked(others.map { $0.id })
            let refURL = try need(project.resolve(refItem.asset, base: base), "reference media")
            // parts of the reference to listen to: the middle first, then spread over the clip (a short recording may cover only part of it)
            var wins: [(Double, Double)] = []
            if refItem.dur > 120 {
                wins.append((refItem.sIn + (refItem.dur - 120) / 2, 120))
                let n = min(8, Int(refItem.dur / 120))
                for k in 0..<n { wins.append((refItem.sIn + Double(k) * (refItem.dur - 120) / Double(max(1, n - 1)), 120)) }
            } else if refItem.dur < 40 { wins.append((max(0, refItem.sIn + refItem.dur / 2 - 30), 60)) }
            else { wins.append((refItem.sIn, refItem.dur)) }
            let windows = wins
            lastMessage = "Matching sound…"
            var found: [String: (Double, Double)] = [:]      // id -> (L seconds, confidence)
            try await withThrowingTaskGroup(of: (String, Double, Double).self) { g in
                for o in others {
                    if o.asset == refItem.asset { found[o.id] = (0, 99); continue }
                    let ou = try need(project.resolve(o.asset, base: base), "media of \(o.id)")
                    g.addTask {
                        var best = (0.0, 0.0)
                        for (rs, rd) in windows {
                            let r = try await AudioSync.offset(ref: refURL, refStart: rs, refDur: rd, other: ou)
                            if r.confidence > best.1 { best = (r.seconds, r.confidence) }
                            if r.confidence >= 2.5 { break }
                        }
                        return (o.id, best.0, best.1)
                    }
                }
                for try await (id, l, cf) in g { found[id] = (l, cf) }
            }
            lastMessage = ""
            let weak = found.filter { $0.value.1 < 1.6 }.map { $0.key }.sorted()
            if found.count == weak.count, !weak.isEmpty, !flag(c, "force") {
                throw RenderError.message("The sound in these clips doesn't match. They may not have been recorded at the same time.")
            }
            var report: [[String: Any]] = []
            try await mutate { p in
                for o in others {
                    guard let (L, cf) = found[o.id], cf >= 1.6 || self.flag(c, "force") else { continue }
                    var newOff = refItem.off - refItem.sIn + o.sIn - L
                    var cutHead = 0.0
                    if newOff < 0 { cutHead = -newOff; newOff = 0 }
                    let delta = newOff - o.off
                    if o.kind == 1, var u = p.upperClips, let i = u.firstIndex(where: { $0.id == o.id }) {
                        guard cutHead < u[i].duration - self.frame else { continue }
                        u[i].offset = newOff; u[i].sourceIn += cutHead; u[i].duration -= cutHead
                        if u[i].audioSource != nil { u[i].audioSource!.sourceIn += cutHead }
                        // free spot on its track (or the next one up) among clips that are not moving
                        let moving = Set(others.map { $0.id })
                        func clash(_ l: Int) -> Bool { u.contains { !moving.contains($0.id) && ($0.lane ?? 1) == l && $0.offset < u[i].offset + u[i].duration - 0.001 && u[i].offset < $0.offset + $0.duration - 0.001 } }
                        var l = u[i].lane ?? 1; while clash(l) { l += 1 }; u[i].lane = l
                        p.upperClips = u; p.gfxLanes = max(p.gfxLanes ?? 0, l)
                        if var ac = p.audioClips {
                            for j in ac.indices where ac[j].link == o.id {
                                ac[j].offset += delta + cutHead; ac[j].sourceIn += cutHead; ac[j].duration -= cutHead
                                if ac[j].offset < 0 { ac[j].sourceIn -= ac[j].offset; ac[j].duration += ac[j].offset; ac[j].offset = 0 }
                            }
                            p.audioClips = ac
                        }
                    } else if o.kind == 2, var ac = p.audioClips, let i = ac.firstIndex(where: { $0.id == o.id }) {
                        guard cutHead < ac[i].duration - self.frame else { continue }
                        ac[i].offset = newOff; ac[i].sourceIn += cutHead; ac[i].duration -= cutHead
                        ac[i].keys = ac[i].keys?.map { VolKey(t: $0.t - cutHead, db: $0.db) }
                        let moving = Set(others.map { $0.id }), x = ac[i]
                        func busy(_ l: Int) -> Bool {
                            ac.contains { !moving.contains($0.id) && $0.lane == l && $0.offset < x.offset + x.duration - 0.001 && x.offset < $0.offset + $0.duration - 0.001 }
                            || (l == 1 && p.clips.contains { $0.audioDetached != true && $0.offset < x.offset + x.duration - 0.001 && x.offset < $0.offset + $0.duration - 0.001 })
                        }
                        var l = x.lane; while busy(l) { l += 1 }; ac[i].lane = l
                        p.audioClips = ac
                        p.audioLanes = max(p.audioLanes ?? 0, ac[i].lane - 1)
                    }
                    report.append(["id": o.id, "moved_by": delta, "offset": newOff, "trimmed_head": cutHead, "confidence": cf])
                }
            }
            lastMessage = "Synced \(report.count) clip\(report.count == 1 ? "" : "s") by sound" + (weak.isEmpty ? "" : " - no match for \(weak.joined(separator: ", "))")
            var out: [String: Any] = ["reference": refItem.id, "synced": report]
            if !weak.isEmpty { out["not_matched"] = weak }
            return out
        case "roll":
            // at=<edit point time> delta= : moves the cut between two touching clips; total length stays the same (Trim tool on an edit point)
            let at = try need(num(c, "at"), "at"); var d = snap(try need(num(c, "delta"), "delta"))
            let cs = project.clips
            guard let a = cs.firstIndex(where: { abs($0.offset + $0.duration - at) < frame * 0.6 }), let b = cs.firstIndex(where: { abs($0.offset - at) < frame * 0.6 }) else { throw RenderError.message("No edit point between two clips there") }
            let A = cs[a], B = cs[b]
            let aMax = ((mediaDuration[A.asset] ?? .infinity) - A.sourceIn) / A.sp - A.duration      // media left after A (timeline s)
            d = max(-(A.duration - frame), -B.sourceIn / B.sp, min(d, B.duration - frame, aMax))
            try await mutate { p in
                p.clips[a].duration += d
                p.clips[b].offset += d; p.clips[b].sourceIn += d * B.sp; p.clips[b].audioSource?.sourceIn += d * B.sp; p.clips[b].duration -= d
                p.clips[b].audio.keys = p.clips[b].audio.keys?.map { VolKey(t: $0.t - d, db: $0.db) }
                if var ov = p.overlays {   // graphics connected to B in the part that changed hands stay where they are in time
                    for k in ov.indices where ov[k].connectedTo == B.id && ov[k].offset < at + d && d > 0 { ov[k].connectedTo = A.id }
                    for k in ov.indices where ov[k].connectedTo == A.id && ov[k].offset >= at + d && d < 0 { ov[k].connectedTo = B.id }
                    p.overlays = ov
                }
            }
            return ["delta": d]
        case "slip":
            // clip= delta= : shows a different part of the media, same position and length (Trim tool in the middle of a clip)
            let i = try clipIndex(c); var d = snap(try need(num(c, "delta"), "delta"))
            let cl = project.clips[i], md = mediaDuration[cl.asset] ?? .infinity
            d = max(-cl.sourceIn, min(d, md - cl.sourceIn - cl.duration * cl.sp))
            if let s = cl.audioSource { d = max(d, -s.sourceIn) }
            try await mutate { p in p.clips[i].sourceIn += d; p.clips[i].audioSource?.sourceIn += d }
            return ["delta": d]
        case "slide":
            // clip= delta= : moves a clip between its neighbours; the one before gets longer/shorter, the one after the opposite (⌥ Trim tool)
            let i = try clipIndex(c); var d = snap(try need(num(c, "delta"), "delta"))
            let cs = project.clips, cl = cs[i]
            guard let a = cs.firstIndex(where: { abs($0.offset + $0.duration - cl.offset) < frame * 0.6 }),
                  let b = cs.firstIndex(where: { abs($0.offset - (cl.offset + cl.duration)) < frame * 0.6 }) else { throw RenderError.message("Slide needs a clip on both sides") }
            let A = cs[a], B = cs[b]
            d = max(-(A.duration - frame), -B.sourceIn / B.sp, min(d, B.duration - frame, ((mediaDuration[A.asset] ?? .infinity) - A.sourceIn) / A.sp - A.duration))
            try await mutate { p in
                p.clips[a].duration += d
                p.clips[i].offset += d
                p.clips[b].offset += d; p.clips[b].sourceIn += d * B.sp; p.clips[b].audioSource?.sourceIn += d * B.sp; p.clips[b].duration -= d
                p.clips[b].audio.keys = p.clips[b].audio.keys?.map { VolKey(t: $0.t - d, db: $0.db) }
                self.shiftConnected(&p, clip: cl.id, by: d)
            }
            return ["delta": d]
        case "set_zoom":
            // clip=<V1 clip> keys="t:scale[:ease],..." (t = seconds from the clip's start, scale 1.2 = 20 % closer, ease = linear|in|out|s)
            // [anchor=x,y: the point that stays still, Final Cut units from the centre, y up]. keys="" removes the zoom.
            let id = try need(str(c, "clip"), "clip"); try refuseIfLocked([id])
            guard let i = project.clips.firstIndex(where: { $0.id == id }) else { throw RenderError.message("no V1 clip \(id) (zoom is for the main track; use pip for V2+)") }
            var ks: [Keyframe] = []
            for part in (str(c, "keys") ?? "").split(separator: ",") {
                let f = part.split(separator: ":").map(String.init)
                guard f.count >= 2, let t = Double(f[0]), let v = Double(f[1]), v > 0 else { throw RenderError.message("keys look like 0:1,3:1.2:s") }
                ks.append(Keyframe(t: t, v: [v], e: f.count > 2 && f[2] != "linear" ? f[2] : nil))
            }
            let anchor = str(c, "anchor")?.split(separator: ",").compactMap { Double($0) }
            try await mutate { p in
                p.clips[i].zoom = ks.isEmpty ? nil : ks.sorted { $0.t < $1.t }
                if let a = anchor, a.count == 2 { p.clips[i].zoomAnchor = a }
            }
            return ["clip": id, "keys": ks.count]
        case "set_fade":
            // id=<clip or audio clip> [in=<seconds>] [out=<seconds>]
            let id = try need(str(c, "id"), "id")
            func clampF(_ v: Double?, _ d: Double) -> Double?? { v.map { let x = max(0, min(snap($0), d)); return x < 0.001 ? nil : x } }
            if let i = project.clips.firstIndex(where: { $0.id == id }) {
                let d = project.clips[i].duration
                let fi = clampF(num(c, "in"), d), fo = clampF(num(c, "out"), d)
                try await mutate { p in if let fi { p.clips[i].audio.fadeIn = fi }; if let fo { p.clips[i].audio.fadeOut = fo } }
            } else if let i = project.audioClips?.firstIndex(where: { $0.id == id }) {
                let d = project.audioClips![i].duration
                let fi = clampF(num(c, "in"), d), fo = clampF(num(c, "out"), d)
                try await mutate { p in if let fi { p.audioClips![i].fadeIn = fi }; if let fo { p.audioClips![i].fadeOut = fo } }
            } else { throw RenderError.message("no clip \(id)") }
            return ["id": id]
        case "set_volume":
            // id=<clip or audio clip> [gain_db=] [keys="t:db,t:db,..." (t from clip start; keys="" removes them)]
            let id = try need(str(c, "id"), "id")
            func parse(_ k: String) -> [VolKey]? {
                let v = k.split(separator: ",").compactMap { pr -> VolKey? in
                    let a = pr.split(separator: ":").compactMap { Double($0) }; return a.count == 2 ? VolKey(t: a[0], db: max(-96, min(12, a[1]))) : nil }
                return v.isEmpty ? nil : v.sorted { $0.t < $1.t }
            }
            let g = num(c, "gain_db").map { max(-96, min(12, $0)) }, keys = str(c, "keys").map(parse)
            if let i = project.clips.firstIndex(where: { $0.id == id }) {
                try await mutate { p in if let g { p.clips[i].audio.gainDb = g }; if let keys { p.clips[i].audio.keys = keys } }
            } else if let i = project.audioClips?.firstIndex(where: { $0.id == id }) {
                try await mutate { p in if let g { p.audioClips![i].gainDb = g }; if let keys { p.audioClips![i].keys = keys } }
            } else { throw RenderError.message("no clip \(id)") }
            return ["id": id]
        case "to_lane":
            // clip=<id> lane=<0 = V1 main storyline, 1 = V2, 2 = V3...> at=<new start>
            // V1 -> V2+: the clip is lifted out and leaves a gap (everything else stays in sync), Final Cut "Lift from Storyline"
            // V2+ -> V1: inserted into the storyline at that point (later clips move right); V2+ -> V2+: moved
            let id = try need(str(c, "clip"), "clip"), lane = Int(try need(num(c, "lane"), "lane"))
            let at = max(0, snap(try need(num(c, "at"), "at")))
            let ups = project.upperClips ?? []
            func clash(_ x: Clip) -> Bool { ups.contains { $0.id != x.id && ($0.lane ?? 1) == (x.lane ?? 1) && $0.offset < x.offset + x.duration - 0.001 && x.offset < $0.offset + $0.duration - 0.001 } }
            if let i = project.clips.firstIndex(where: { $0.id == id }) {
                guard lane >= 1 else { return ["clip": id] }
                var x = project.clips[i]; x.lane = lane; x.offset = at
                if clash(x) { throw RenderError.message("V\(lane + 1) already has a clip there") }
                let old = project.clips[i]
                try await mutate { p in
                    p.clips.remove(at: i)
                    if old.audioDetached != true && abs(old.sp - 1) < 0.0001 {
                        // its sound stays on the audio tracks (A1 where it was, if free), linked to the clip so it follows it
                        x.audioDetached = true
                        let src = old.audioSource?.asset ?? old.asset
                        var ac = p.audioClips ?? []
                        var n = ac.count + 1; while ac.contains(where: { $0.id == "au\(n)" }) { n += 1 }
                        let nm = (p.assets.first { $0.id == src }?.path as NSString?)?.lastPathComponent ?? "audio"
                        let lane = self.freeAudioLane(p, at, old.duration)
                        ac.append(AudioClip(id: "au\(n)", asset: src, name: nm, lane: lane, offset: at, sourceIn: old.audioSource?.sourceIn ?? old.sourceIn,
                                            duration: old.duration, gainDb: old.audio.gainDb, keys: old.audio.keys, fadeIn: old.audio.fadeIn, fadeOut: old.audio.fadeOut, link: id))
                        p.audioClips = ac; p.audioLanes = max(p.audioLanes ?? 0, lane - 1)
                    }
                    p.upperClips = (p.upperClips ?? []) + [x]
                    p.gfxLanes = max(p.gfxLanes ?? 0, lane)
                    // its graphics stay attached to it; markers on it stay where they are in time
                    if var mk = p.markers { for k in mk.indices where mk[k].clip == id { mk[k].clip = nil }; p.markers = mk }
                }
            } else if let i = ups.firstIndex(where: { $0.id == id }) {
                var x = ups[i]
                if lane == 0 {
                    x.lane = nil; x.offset = at
                    let linked = (project.audioClips ?? []).filter { $0.link == id }
                    if !linked.isEmpty { x.audioDetached = nil }      // its own sound joins it again under V1
                    try await mutate { p in
                        p.upperClips?.remove(at: i)
                        p.audioClips?.removeAll { $0.link == id }
                        self.splitAt(&p, at)
                        self.rippleAfter(&p, from: at, by: x.duration, except: nil)
                        p.clips.append(x); p.clips.sort { $0.offset < $1.offset }
                    }
                } else {
                    let d = at - x.offset
                    x.lane = lane; x.offset = at
                    if clash(x) { throw RenderError.message("V\(lane + 1) already has a clip there") }
                    try await mutate { p in
                        p.upperClips![i] = x; p.gfxLanes = max(p.gfxLanes ?? 0, lane)
                        self.followLinked(&p, id, offsetBy: d)
                    }
                }
            } else { throw RenderError.message("no clip \(id)") }
            return ["clip": id, "lane": lane]
        case "upper_trim":
            // clip=<id on V2+> [trim_start=<seconds removed from the start, negative extends>] [duration=]
            let id = try need(str(c, "clip"), "clip")
            guard let i = project.upperClips?.firstIndex(where: { $0.id == id }) else { throw RenderError.message("no clip \(id) on V2+") }
            var x = project.upperClips![i]
            let md = mediaDuration[x.asset] ?? .infinity
            if let d = num(c, "trim_start") {
                let dd = max(min(snap(d), x.duration - frame), max(-x.sourceIn / x.sp, -x.offset))
                let xs = dd * x.sp; x.offset += dd; x.sourceIn += xs; x.audioSource?.sourceIn += xs; x.duration -= dd
                x.audio.keys = x.audio.keys?.map { VolKey(t: $0.t - dd, db: $0.db) }
            }
            if let v = num(c, "duration") { x.duration = max(frame, min(snap(v), (md - x.sourceIn) / x.sp)) }
            let nx = x
            if (project.upperClips ?? []).contains(where: { $0.id != id && $0.lane == nx.lane && $0.offset < nx.offset + nx.duration - 0.001 && nx.offset < $0.offset + $0.duration - 0.001 }) {
                throw RenderError.message("V\((nx.lane ?? 1) + 1) already has a clip there")
            }
            let old = project.upperClips![i]
            try await mutate { p in
                p.upperClips![i] = nx
                // linked sound takes the same trim
                if var ac = p.audioClips {
                    for k in ac.indices where ac[k].link == id {
                        let ds = nx.offset - old.offset
                        ac[k].offset += ds; ac[k].sourceIn += ds; ac[k].duration = nx.duration
                        ac[k].keys = ac[k].keys?.map { VolKey(t: $0.t - ds, db: $0.db) }
                    }
                    p.audioClips = ac
                }
            }
            return ["clip": id]
        case "layer_fx":
            // ids=g1,g2 type=shadow|glow|stroke|corners|blur|color|tint [any effect number, e.g. distance=20]  (adds an effect)
            let ids = (try need(str(c, "ids"), "ids")).split(separator: ",").map(String.init)
            let type = try need(str(c, "type"), "type")
            guard let cat = LayerEffect.catalog.first(where: { $0.type == type }) else { throw RenderError.message("unknown effect \(type)") }
            var pr = cat.defaults; for k in pr.keys { if let v = num(c, k) { pr[k] = v } }
            try refuseIfLocked(ids)
            try await mutate { p in
                for k in (p.overlays ?? []).indices where ids.contains(p.overlays![k].id) {
                    p.overlays![k].effects = (p.overlays![k].effects ?? []) + [LayerEffect(id: UUID().uuidString, type: type, p: pr)]
                }
            }
            return ["added": type]
        case "layer_set":
            // ids=g1,g2 [x= y= (px from centre) scale= rotation= opacity=] [crop=l,r,t,b] [blend=] [fade_in= fade_out=] [clear_fx=true] (at= timeline time)
            let ids = (try need(str(c, "ids"), "ids")).split(separator: ",").map(String.init)
            try refuseIfLocked(ids)
            let at = num(c, "at") ?? playhead, u = Double(project.settings.height) / 100
            for (prop, v) in [("scale", num(c, "scale").map { [$0, $0] }), ("rotation", num(c, "rotation").map { [$0] }), ("opacity", num(c, "opacity").map { [$0] })] {
                if let v { setLayerValue(ids, prop, v, at: at) }
            }
            if num(c, "x") != nil || num(c, "y") != nil, let o = project.overlays?.first(where: { ids.contains($0.id) }) {
                let cur = layerValue(o, "position", at: at)
                setLayerValue(ids, "position", [num(c, "x").map { $0 / u } ?? cur[0], num(c, "y").map { $0 / u } ?? cur[1]], at: at)
            }
            var shapeCols: [String: [Double]] = [:]
            for k in ["shape_fill", "shape_fill2", "shape_stroke"] { if let v = str(c, k) { shapeCols[k] = v.split(separator: ",").compactMap { Double($0) } } }
            liveLayers(ids) { o in
                if let cr = self.str(c, "crop") { let v = cr.split(separator: ",").compactMap { Double($0) }; if v.count == 4 { o.crop = v } }
                if let b = self.str(c, "blend") { o.blend = b == "normal" ? nil : b }
                if let v = self.num(c, "fade_in") { o.fadeIn = v > 0 ? v : nil }
                if let v = self.num(c, "fade_out") { o.fadeOut = v > 0 ? v : nil }
                // shape layers: shape_w= shape_h= shape_radius= shape_fill=r,g,b,a shape_fill2= shape_angle= shape_stroke=r,g,b,a shape_stroke_width=
                if var sh = o.shape {
                    func col(_ k: String) -> [Double]? { shapeCols[k] }
                    if let v = self.num(c, "shape_w") { sh.w = v }; if let v = self.num(c, "shape_h") { sh.h = v }
                    if let v = self.num(c, "shape_radius") { sh.radius = v }; if let v = self.num(c, "shape_angle") { sh.angle = v }
                    if let v = col("shape_fill") { sh.fill = v.count >= 3 ? v : nil }; if let v = col("shape_fill2") { sh.fill2 = v }
                    if let v = col("shape_stroke") { sh.strokeColor = v }; if let v = self.num(c, "shape_stroke_width") { sh.strokeWidth = v }
                    o.shape = sh
                }
                // mask=rect|circle|none [mask_x= mask_y= mask_w= mask_h= mask_radius= mask_feather= mask_invert=]
                if let mk = self.str(c, "mask") { if mk == "none" { o.mask = nil } else { var m = o.mask ?? MaskSpec(); m.kind = mk; o.mask = m } }
                if var m = o.mask {
                    if let v = self.num(c, "mask_x") { m.x = v }; if let v = self.num(c, "mask_y") { m.y = v }
                    if let v = self.num(c, "mask_w") { m.w = v }; if let v = self.num(c, "mask_h") { m.h = v }
                    if let v = self.num(c, "mask_radius") { m.radius = v }; if let v = self.num(c, "mask_feather") { m.feather = v }
                    if c["mask_invert"] != nil { m.invert = self.flag(c, "mask_invert") ? true : nil }
                    o.mask = m
                }
                // behaviour=wiggle|drift|pulse|spin|none [b_amount= b_speed= b_angle=] (adds one; none clears them)
                if let bt = self.str(c, "behaviour") {
                    if bt == "none" { o.behaviours = nil } else {
                        var b = Behaviour(type: bt)
                        if let v = self.num(c, "b_amount") { b.amount = v }; if let v = self.num(c, "b_speed") { b.speed = v }; if let v = self.num(c, "b_angle") { b.angle = v }
                        o.behaviours = (o.behaviours ?? []) + [b]
                    }
                }
                // build_in=fade|slide|scale|blur|typewriter|words|none [in_dur=] [in_dir=] [in_amount=]  (same with build_out / out_*)
                for (k, pre) in [("build_in", "in"), ("build_out", "out")] {
                    guard let ty = self.str(c, k) else { continue }
                    var b: Build? = ty == "none" ? nil : Build(type: ty)
                    if let d = self.num(c, pre + "_dur") { b?.dur = d }
                    b?.dir = self.str(c, pre + "_dir"); b?.amount = self.num(c, pre + "_amount")
                    if k == "build_in" { o.buildIn = b } else { o.buildOut = b }
                }
                if self.flag(c, "clear_fx") { o.effects = nil }
                if self.str(c, "anchor") == "graphic", let pth = self.layerPath(o) { o.anchor = OverlayRender.visibleCentreOffset(path: pth) }

            }
            if let e = str(c, "ease") { setEase(ids, e, commit: false) }
            commitLive()
            return ["ids": ids]
        case "pip":
            // clip=<V2+ clip> [x= y= px from centre] [scale=] [rotation=] [opacity=] [crop=l,r,t,b]
            let id = try need(str(c, "clip"), "clip"); try refuseIfLocked([id])
            let u = Double(project.settings.height) / 100
            liveUpper([id]) { x in
                if self.num(c, "x") != nil || self.num(c, "y") != nil { let p = x.position ?? [0, 0]; x.position = [self.num(c, "x").map { $0 / u } ?? p[0], self.num(c, "y").map { $0 / u } ?? p[1]] }
                if let v = self.num(c, "scale") { x.scale = v }
                if let v = self.num(c, "rotation") { x.rotation = v }
                if let v = self.num(c, "opacity") { x.opacity = v }
                if let cr = self.str(c, "crop") { let v = cr.split(separator: ",").compactMap { Double($0) }; if v.count == 4 { x.crop = v } }
            }
            commitLive()
            return ["clip": id]
        case "live_bench":
            // testing aid: n= live moves of layer id= by 1 unit each, timed through the live redraw path
            let id = try need(str(c, "id"), "id"), n = Int(num(c, "n") ?? 30)
            let t0 = Date()
            for _ in 0..<n { liveLayers([id]) { o in o.position = o.position.map { Keyframe(t: $0.t, v: [$0.v[0] + 1, $0.v[1]], e: $0.e) } }; try? await Task.sleep(nanoseconds: 16_000_000) }
            commitLive()
            return ["seconds": Date().timeIntervalSince(t0), "live_path": showFrame != nil && player.rate == 0 && abs(LastFrame.time - player.currentTime().seconds) < frame * 0.6]
        case "mix_check":
            // volume the PLAYING item applies on its first audio track at t= (from its own mix, not ours)
            let t = CMTime(seconds: num(c, "t") ?? 0.5, preferredTimescale: 6000)
            var sv: Float = -1, ev: Float = -1, tr = CMTimeRange()
            _ = player.currentItem?.audioMix?.inputParameters.first?.getVolumeRamp(for: t, startVolume: &sv, endVolume: &ev, timeRange: &tr)
            return ["playing_item_volume": Double(sv)]
        case "fx_stats":
            return ["baked_reused": OverlayImages.bakeHits, "baked_drawn": OverlayImages.bakeMisses]
        case "track_height":
            // track=V1|V2|A1... h=<points> (same as dragging the line under the track name)
            setTrackHeight(try need(str(c, "track"), "track").uppercased(), try need(num(c, "h"), "h")); return [:]
        case "track_hidden":
            // track=V3|A2 on=true|false : hide a video track / mute an audio track (playback + export)
            let tr = try need(str(c, "track"), "track").uppercased(), on = flag(c, "on")
            try await mutate { p in
                var h = Set(p.hiddenTracks ?? []); if on { h.insert(tr) } else { h.remove(tr) }
                p.hiddenTracks = h.isEmpty ? nil : h.sorted()
            }
            return ["track": tr, "hidden": on]
        case "remove_empty_tracks":
            // drops empty video / audio tracks at the top of the stack
            try await mutate { p in
                p.gfxLanes = max(0, ((p.overlays ?? []).map { $0.lane } + (p.upperClips ?? []).map { $0.lane ?? 1 }).max() ?? 0)
                p.audioLanes = max(0, ((p.audioClips ?? []).map { $0.lane }.max() ?? 1) - 1)
            }
            return [:]
        case "sync_lock":
            // track=V5|A2 on=true|false : sync lock (on = the track follows V1 ripple edits)
            let tr = try need(str(c, "track"), "track").uppercased(), on = flag(c, "on")
            try await mutate { p in
                var u = Set(p.unsynced ?? []); if on { u.remove(tr) } else { u.insert(tr) }
                p.unsynced = u.isEmpty ? nil : u.sorted()
            }
            return ["track": tr, "on": on]
        case "add_track":
            // kind=audio|graphics : show one more empty track
            let k = str(c, "kind") ?? "audio"
            try await mutate { p in
                if k == "audio" { p.audioLanes = max(p.audioLanes ?? 0, Set((p.audioClips ?? []).map { $0.lane }).max().map { $0 - 1 } ?? 0) + 1 }
                else { p.gfxLanes = max(p.gfxLanes ?? 0, (p.overlays ?? []).map { $0.lane }.max() ?? 0) + 1 }
            }
            return ["audio_tracks": 1 + (project.audioLanes ?? 0), "graphics_tracks": project.gfxLanes ?? 0]
        case "add_audio", "add_graphic":
            // path=<file> [at= default playhead] [lane=] [dur= graphics only, default 5 s]; lane default = first track with room, else a new one
            let path = ((try need(str(c, "path"), "path")) as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { throw RenderError.message("file not found: \(path)") }
            var aid = project.assets.first(where: { project.resolve($0.id, base: base)?.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path })?.id
            var newAsset: Asset?
            if aid == nil { var n = project.assets.count + 1; while project.assets.contains(where: { $0.id == "a\(n)" }) { n += 1 }; newAsset = Asset(id: "a\(n)", path: path); aid = newAsset!.id }
            let at = snap(num(c, "at") ?? playhead), nm = (path as NSString).lastPathComponent
            if name == "add_audio" {
                let media = AVURLAsset(url: URL(fileURLWithPath: path))
                guard try await !media.loadTracks(withMediaType: .audio).isEmpty else { throw RenderError.message("no sound in \(nm)") }
                let sIn = max(0, num(c, "source_in") ?? 0)
                let full = try await media.load(.duration).seconds
                let dur = snap(num(c, "dur") ?? (full - sIn))
                let ex = project.audioClips ?? []
                var lane = Int(num(c, "lane") ?? 0)
                if lane < 2 { lane = 2; while ex.contains(where: { $0.lane == lane && $0.offset < at + dur && at < $0.offset + $0.duration }) { lane += 1 } }
                var n = ex.count + 1; while ex.contains(where: { $0.id == "au\(n)" }) { n += 1 }
                let a = AudioClip(id: "au\(n)", asset: aid!, name: nm, lane: lane, offset: at, sourceIn: sIn, duration: dur)
                try await mutate { p in if let na = newAsset { p.assets.append(na) }; p.audioClips = (p.audioClips ?? []) + [a]; p.audioLanes = max(p.audioLanes ?? 0, lane - 1) }
                selection = [a.id]
                return ["id": a.id, "lane": lane, "duration": dur]
            } else {
                guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), CGImageSourceGetCount(src) > 0 else { throw RenderError.message("not an image: \(nm)") }
                let dur = snap(num(c, "dur") ?? 5)
                let ex = project.overlays ?? []
                // graphics and video share the same video tracks: skip past anything already there
                let upc = project.upperClips ?? []
                var lane = max(1, Int(num(c, "lane") ?? 1))
                while ex.contains(where: { $0.lane == lane && $0.offset < at + dur - 0.001 && at < $0.offset + $0.duration - 0.001 })
                        || upc.contains(where: { ($0.lane ?? 1) == lane && $0.offset < at + dur - 0.001 && at < $0.offset + $0.duration - 0.001 }) { lane += 1 }
                var n = ex.count + 1; while ex.contains(where: { $0.id == "g\(n)" }) { n += 1 }
                var o = Overlay(id: "g\(n)", name: nm, asset: aid!, lane: lane, offset: at, duration: dur)
                o.connectedTo = project.clips.first { at >= $0.offset && at < $0.offset + $0.duration }?.id
                try await mutate { p in if let na = newAsset { p.assets.append(na) }; p.overlays = (p.overlays ?? []) + [o]; p.gfxLanes = max(p.gfxLanes ?? 0, lane) }
                selection = [o.id]; selectedOverlay = o.id
                return ["id": o.id, "lane": lane]
            }
        case "add_text":
            // [text=] [at= default playhead] [dur= 5] [lane=] [font=] [size=]: a new text layer, centred in the frame
            let at = snap(num(c, "at") ?? playhead), dur = snap(num(c, "dur") ?? 5)
            var r = TextRun(text: str(c, "text") ?? "Your text")
            if let f = str(c, "font") { r.font = f }
            if let z = num(c, "size") { r.size = z }
            r.bold = true
            let ex = project.overlays ?? [], upc = project.upperClips ?? []
            var lane = max(1, Int(num(c, "lane") ?? 1))
            while ex.contains(where: { $0.lane == lane && $0.offset < at + dur - 0.001 && at < $0.offset + $0.duration - 0.001 })
                    || upc.contains(where: { ($0.lane ?? 1) == lane && $0.offset < at + dur - 0.001 && at < $0.offset + $0.duration - 0.001 }) { lane += 1 }
            var n = ex.count + 1; while ex.contains(where: { $0.id == "g\(n)" }) { n += 1 }
            var o = Overlay(id: "g\(n)", name: "Text", asset: "", lane: lane, offset: at, duration: dur)
            o.conform = "none"; o.text = TextSpec(runs: [r])
            o.connectedTo = project.clips.first { at >= $0.offset && at < $0.offset + $0.duration }?.id
            try await mutate { p in p.overlays = (p.overlays ?? []) + [o]; p.gfxLanes = max(p.gfxLanes ?? 0, lane) }
            selection = [o.id]; selectedOverlay = o.id; inspectorTab = "clip"
            return ["id": o.id, "lane": lane]
        case "add_shape":
            // kind=rect|circle|line|solid|gradient [at= playhead] [dur= 5] [lane=]: a new shape layer, centred in the frame
            let kind = str(c, "kind") ?? "rect"
            let at = snap(num(c, "at") ?? playhead), dur = snap(num(c, "dur") ?? 5)
            let PW = Double(project.settings.width), PH = Double(project.settings.height)
            var sh = ShapeSpec(kind: kind, w: kind == "solid" || kind == "gradient" ? PW : kind == "circle" ? 300 : kind == "line" ? 600 : 600,
                               h: kind == "solid" || kind == "gradient" ? PH : kind == "circle" ? 300 : kind == "line" ? 8 : 300)
            if kind == "solid" { sh.fill = [0.05, 0.07, 0.12, 1] }
            if kind == "gradient" { sh.fill = [0.04, 0.10, 0.25, 1]; sh.fill2 = [0.02, 0.02, 0.05, 1]; sh.angle = 90 }
            if kind == "line" { sh.strokeWidth = 8 }
            if kind == "blur" { sh.w = 500; sh.h = 140; sh.style = "blur"; sh.amount = 30; sh.feather = 8; sh.radius = 12 }
            let ex = project.overlays ?? [], upc = project.upperClips ?? []
            var lane = max(1, Int(num(c, "lane") ?? 1))
            while ex.contains(where: { $0.lane == lane && $0.offset < at + dur - 0.001 && at < $0.offset + $0.duration - 0.001 })
                    || upc.contains(where: { ($0.lane ?? 1) == lane && $0.offset < at + dur - 0.001 && at < $0.offset + $0.duration - 0.001 }) { lane += 1 }
            var n = ex.count + 1; while ex.contains(where: { $0.id == "g\(n)" }) { n += 1 }
            var o = Overlay(id: "g\(n)", name: ShapeSpec.kinds.first { $0.id == kind }?.name ?? "Shape", asset: "", lane: lane, offset: at, duration: dur)
            o.conform = "none"; o.shape = sh
            o.connectedTo = project.clips.first { at >= $0.offset && at < $0.offset + $0.duration }?.id
            try await mutate { p in p.overlays = (p.overlays ?? []) + [o]; p.gfxLanes = max(p.gfxLanes ?? 0, lane) }
            selection = [o.id]; selectedOverlay = o.id; inspectorTab = "clip"
            return ["id": o.id, "lane": lane]
        case "save_title":
            // name= [ids= default the selection]: saves those text / shape layers (with their look and animation) as a reusable title
            let name = try need(str(c, "name"), "name")
            let ids = str(c, "ids").map { $0.split(separator: ",").map(String.init) } ?? Array(selection)
            let ls = (project.overlays ?? []).filter { ids.contains($0.id) }
            guard !ls.isEmpty else { throw RenderError.message("select the text / shape layers to save") }
            guard ls.allSatisfy({ $0.asset.isEmpty }) else { throw RenderError.message("only text and shape layers can be saved as a title (picture layers belong to their project)") }
            try Titles.save(name, ls, paths: ls.map { layerPath($0) ?? "" })
            titleTick += 1; lastMessage = "Saved title \(name)"
            return ["name": name, "layers": ls.count]
        case "add_title":
            // name= [at= playhead]: puts a saved title on the timeline at the playhead, on free tracks
            let name = try need(str(c, "name"), "name")
            guard var ls = Titles.load(name) else { throw RenderError.message("no saved title called \(name)") }
            let at = snap(num(c, "at") ?? playhead)
            let ex = project.overlays ?? [], upc = project.upperClips ?? []
            func busy(_ lane: Int, _ a: Double, _ b: Double, _ extra: [Overlay]) -> Bool {
                (ex + extra).contains { $0.lane == lane && $0.offset < b - 0.001 && a < $0.offset + $0.duration - 0.001 }
                    || upc.contains { ($0.lane ?? 1) == lane && $0.offset < b - 0.001 && a < $0.offset + $0.duration - 0.001 }
            }
            var n = ex.count + 1, placed: [Overlay] = []
            let parent = project.clips.first { at >= $0.offset && at < $0.offset + $0.duration }?.id
            ls.sort { $0.lane < $1.lane }
            // on top of whatever is already showing there (a title is meant to be seen)
            let end = at + (ls.map { $0.offset + $0.duration }.max() ?? 0)
            var lane = 1 + max(ex.filter { $0.offset < end - 0.001 && at < $0.offset + $0.duration - 0.001 }.map(\.lane).max() ?? 0,
                               upc.filter { $0.offset < end - 0.001 && at < $0.offset + $0.duration - 0.001 }.map { $0.lane ?? 1 }.max() ?? 0)
            for var o in ls {
                while ex.contains(where: { $0.id == "g\(n)" }) { n += 1 }
                o.id = "g\(n)"; n += 1
                o.offset = at + o.offset
                while busy(lane, o.offset, o.offset + o.duration, placed) { lane += 1 }
                o.lane = lane; lane += 1
                o.connectedTo = parent
                placed.append(o)
            }
            try await mutate { p in p.overlays = (p.overlays ?? []) + placed; p.gfxLanes = max(p.gfxLanes ?? 0, placed.map(\.lane).max() ?? 0) }
            selection = Set(placed.map(\.id)); selectedOverlay = placed.first?.id; inspectorTab = "clip"
            return ["ids": placed.map(\.id)]
        case "delete_title":
            Titles.delete(try need(str(c, "name"), "name")); titleTick += 1; return [:]
        case "text_edit":
            // id= [run= 0] [text=] [font=] [size=] [bold=] [italic=] [color=r,g,b,a] [tracking=] [stroke_color=] [stroke_width=]
            // [shadow_color=] [shadow_distance=] [shadow_blur=] [shadow_angle=] [align=left|center|right] [line_spacing=] [width= 0 = no wrap]
            // [add_run=text] [remove_run=index]
            let id = try need(str(c, "id"), "id")
            guard let i = project.overlays?.firstIndex(where: { $0.id == id }), var t = project.overlays?[i].text else { throw RenderError.message("\(id) is not a text layer") }
            func cols(_ k: String) -> [Double]? { str(c, k).map { $0.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } } }
            if let add = str(c, "add_run") { var r = t.runs.last ?? TextRun(text: ""); r.text = add; t.runs.append(r) }
            if let k = num(c, "remove_run"), t.runs.count > 1, Int(k) < t.runs.count { t.runs.remove(at: Int(k)) }
            let ri = min(max(0, Int(num(c, "run") ?? 0)), t.runs.count - 1)
            var r = t.runs[ri]
            if let v = str(c, "text") { r.text = v }
            if let v = str(c, "font") { r.font = v }
            if let v = num(c, "size") { r.size = max(4, v) }
            if c["bold"] != nil { r.bold = flag(c, "bold") }
            if c["italic"] != nil { r.italic = flag(c, "italic") }
            if let v = cols("color"), v.count >= 3 { r.color = v }
            if let v = num(c, "tracking") { r.tracking = v }
            if let v = cols("stroke_color") { r.strokeColor = v.isEmpty ? nil : v }
            if let v = num(c, "stroke_width") { r.strokeWidth = v > 0 ? v : nil }
            if let v = cols("shadow_color") { r.shadowColor = v.isEmpty ? nil : v }
            if let v = num(c, "shadow_distance") { r.shadowDistance = v }
            if let v = num(c, "shadow_blur") { r.shadowBlur = v }
            if let v = num(c, "shadow_angle") { r.shadowAngle = v }
            t.runs[ri] = r
            if let v = str(c, "align") { t.align = v }
            if let v = num(c, "line_spacing") { t.lineSpacing = v }
            if let v = num(c, "width") { t.width = v > 0 ? v : nil }
            try await mutate { p in p.overlays![i].text = t; if p.overlays![i].name == "Text" || p.overlays![i].name.isEmpty { p.overlays![i].name = String(t.plain.prefix(40)) } }
            return ["id": id]
        case "audio_edit":
            // id= [offset=] [duration=] [trim_start=] [gain_db=] [lane=]
            let id = try need(str(c, "id"), "id")
            guard let i = project.audioClips?.firstIndex(where: { $0.id == id }) else { throw RenderError.message("no audio clip \(id)") }
            var a = project.audioClips![i]
            let media = try await AVURLAsset(url: try need(project.resolve(a.asset, base: base), "asset")).load(.duration).seconds
            if let d = num(c, "trim_start") { let dd = max(min(snap(d), a.duration - frame), max(-a.sourceIn, -a.offset)); a.offset += dd; a.sourceIn += dd; a.duration -= dd; a.keys = a.keys?.map { VolKey(t: $0.t - dd, db: $0.db) } }
            if let v = num(c, "offset") { a.offset = max(0, snap(v)) }
            if let v = num(c, "duration") { a.duration = max(frame, min(snap(v), media - a.sourceIn)) }
            if let v = num(c, "gain_db") { a.gainDb = max(-60, min(24, v)) }
            if let v = num(c, "lane") { a.lane = max(1, Int(v)) }
            let na = a
            func clash(_ x: AudioClip) -> Bool {
                (project.audioClips ?? []).contains(where: { $0.id != id && $0.lane == x.lane && $0.offset < x.offset + x.duration - 0.001 && x.offset < $0.offset + $0.duration - 0.001 })
                || (x.lane == 1 && project.clips.contains(where: { $0.audioDetached != true && $0.offset < x.offset + x.duration - 0.001 && x.offset < $0.offset + $0.duration - 0.001 }))
            }
            if clash(na) { throw RenderError.message("A\(na.lane) already has sound there - move it to a free spot or another track") }
            let old = project.audioClips![i]
            if !flag(c, "solo"), let l = old.link, project.clips.contains(where: { $0.id == l }),
               abs(na.offset - old.offset) > 0.0001 || abs(na.duration - old.duration) > 0.0001 || abs(na.sourceIn - old.sourceIn) > 0.0001 {
                // linked to a V1 clip: dragging or trimming the sound does the same edit to the clip (its sound follows it)
                if num(c, "trim_start") != nil || abs(na.sourceIn - old.sourceIn) > 0.0001 {
                    return try await run("drag_edit", ["clip": l, "mode": "trim_start", "delta": na.offset - old.offset])
                } else if abs(na.duration - old.duration) > 0.0001 && abs(na.offset - old.offset) < 0.0001 {
                    return try await run("drag_edit", ["clip": l, "mode": "trim_end", "delta": na.duration - old.duration])
                } else {
                    return try await run("drag_edit", ["clip": l, "mode": "move", "delta": na.offset - old.offset])
                }
            }
            var vx: (Int, Clip)?
            if !flag(c, "solo"), let l = old.link, let vi = project.upperClips?.firstIndex(where: { $0.id == l }) {
                // linked: the picture takes the same move / trim
                var v = project.upperClips![vi]
                let ds = na.offset - old.offset, dIn = na.sourceIn - old.sourceIn
                let sp0 = v.sp; v.offset = max(0, v.offset + ds); v.sourceIn += dIn * sp0; v.audioSource?.sourceIn += dIn * sp0
                v.duration = max(frame, v.duration + (na.duration - old.duration))
                let vv = v
                if (project.upperClips ?? []).contains(where: { $0.id != l && ($0.lane ?? 1) == (vv.lane ?? 1) && $0.offset < vv.offset + vv.duration - 0.001 && vv.offset < $0.offset + $0.duration - 0.001 })
                    || (project.overlays ?? []).contains(where: { $0.lane == (vv.lane ?? 1) && $0.offset < vv.offset + vv.duration - 0.001 && vv.offset < $0.offset + $0.duration - 0.001 }) {
                    throw RenderError.message("Its picture on V\((vv.lane ?? 1) + 1) would hit another clip there")
                }
                vx = (vi, v)
            }
            let fixedVx = vx
            try await mutate { p in
                p.audioClips![i] = na; p.audioLanes = max(p.audioLanes ?? 0, na.lane - 1)
                if let (vi, v) = fixedVx { p.upperClips![vi] = v }
            }
            return ["id": id]
        case "blade_all":
            // cuts every clip and graphic (all lanes) that spans at= (default playhead), selected or not (Final Cut ⇧ blade)
            let t = snap(num(c, "at") ?? playhead)
            cutAllTimes.append(t)
            // cut everything under t without touching the selection (no yellow flash)
            let ids = Set(project.clips.filter { t > $0.offset && t < $0.offset + $0.duration }.map { $0.id }
                            + (project.overlays ?? []).filter { t > $0.offset && t < $0.offset + $0.duration }.map { $0.id }
                            + (project.audioClips ?? []).filter { t > $0.offset && t < $0.offset + $0.duration }.map { $0.id }
                            + (project.upperClips ?? []).filter { t > $0.offset && t < $0.offset + $0.duration }.map { $0.id })
            let r = try await run("blade_selected", ["at": t, "ids": ids.joined(separator: ",")])
            return r
        case "blade_selected":
            // cuts every selected clip and graphic that spans at= (default playhead); with nothing selected, the clip under the playhead
            let t = snap(num(c, "at") ?? playhead)
            var targets = str(c, "ids").map { Set($0.split(separator: ",").map(String.init)) } ?? selection   // ids= cut these only (Blade tool click)
            targets = targets.filter { lockedTrack(of: $0) == nil }                                             // locked tracks are never cut
            // linked picture + sound are cut together: cutting either half cuts the picture, which cuts its sound with it
            for a in project.audioClips ?? [] { if let l = a.link, targets.contains(a.id) { targets.insert(l) } }
            if targets.isEmpty, let cl = project.clips.first(where: { t > $0.offset && t < $0.offset + $0.duration }) { targets = [cl.id] }
            var cut = 0
            try await mutate { p in
                var newPieces: [String] = []
                defer {
                    // a graphic piece belongs to the clip it now starts on (so it moves / deletes with that clip)
                    if var ov = p.overlays {
                        for k in ov.indices where newPieces.contains(ov[k].id) || ov[k].connectedTo != nil {
                            if newPieces.contains(ov[k].id), let c = p.clips.first(where: { ov[k].offset >= $0.offset - self.frame * 0.5 && ov[k].offset < $0.offset + $0.duration - self.frame * 0.5 }) { ov[k].connectedTo = c.id }
                        }
                        p.overlays = ov
                    }
                }
                for id in targets {
                    if let i = p.clips.firstIndex(where: { $0.id == id }), t > p.clips[i].offset + self.frame * 0.5, t < p.clips[i].offset + p.clips[i].duration - self.frame * 0.5 {
                        self.splitAt(&p, t); cut += 1
                    } else if var ov = p.overlays, let i = ov.firstIndex(where: { $0.id == id }), t > ov[i].offset + 0.01, t < ov[i].offset + ov[i].duration - 0.01 {
                        var a = ov[i], b = a
                        let d = t - a.offset
                        a.duration = d
                        var n = ov.count + 1; while ov.contains(where: { $0.id == "g\(n)" }) { n += 1 }
                        b.id = "g\(n)"; b.offset = t; b.duration -= d
                        b.position = b.position.map { Keyframe(t: $0.t - d, v: $0.v) }
                        b.scale = b.scale.map { Keyframe(t: $0.t - d, v: $0.v) }
                        b.opacity = b.opacity.map { Keyframe(t: $0.t - d, v: $0.v) }
                        ov[i] = a; ov.insert(b, at: i + 1); p.overlays = ov; cut += 1
                        newPieces.append(b.id)
                    } else if var up = p.upperClips, let i = up.firstIndex(where: { $0.id == id }), t > up[i].offset + 0.01, t < up[i].offset + up[i].duration - 0.01 {
                        var a = up[i], b = a
                        let d = t - a.offset
                        a.duration = d; a.audio.fadeOut = nil
                        var n = p.clips.count + up.count + 1; while (p.clips + up).contains(where: { $0.id == "c\(n)" }) { n += 1 }
                        b.id = "c\(n)"; b.offset = t; b.sourceIn += d * a.sp; b.audioSource?.sourceIn += d * a.sp; b.duration -= d; b.audio.fadeIn = nil
                        b.audio.keys = b.audio.keys?.map { VolKey(t: $0.t - d, db: $0.db) }
                        up[i] = a; up.insert(b, at: i + 1); p.upperClips = up; cut += 1
                        if var gs = p.groups { for k in gs.indices where gs[k].members.contains(a.id) { gs[k].members.append(b.id) }; p.groups = gs }
                        // its linked sound: cut at the same point, the second piece belongs to the second picture
                        if var ac = p.audioClips {
                            for k in ac.indices.reversed() where ac[k].link == a.id {
                                if t > ac[k].offset + 0.01 && t < ac[k].offset + ac[k].duration - 0.01 {
                                    var x = ac[k], y = x; let dd = t - x.offset
                                    x.duration = dd; x.fadeOut = nil
                                    var n = ac.count + 1; while ac.contains(where: { $0.id == "au\(n)" }) { n += 1 }
                                    y.id = "au\(n)"; y.offset = t; y.sourceIn += dd; y.duration -= dd; y.fadeIn = nil; y.link = b.id
                                    y.keys = y.keys?.map { VolKey(t: $0.t - dd, db: $0.db) }
                                    ac[k] = x; ac.insert(y, at: k + 1); newPieces.append(y.id)
                                } else if ac[k].offset >= t - 0.01 { ac[k].link = b.id }
                            }
                            p.audioClips = ac
                        }
                    } else if var ac = p.audioClips, let i = ac.firstIndex(where: { $0.id == id }), t > ac[i].offset + 0.01, t < ac[i].offset + ac[i].duration - 0.01,
                              !(ac[i].link.map { l in targets.contains(l) } ?? false) {
                        var a = ac[i], b = a
                        let d = t - a.offset
                        a.duration = d
                        var n = ac.count + 1; while ac.contains(where: { $0.id == "au\(n)" }) { n += 1 }
                        b.id = "au\(n)"; b.offset = t; b.sourceIn += d; b.duration -= d; b.keys = b.keys?.map { VolKey(t: $0.t - d, db: $0.db) }; b.fadeIn = nil; a.fadeOut = nil
                        ac[i] = a; ac.insert(b, at: i + 1); p.audioClips = ac; cut += 1
                    }
                }
            }
            return ["cut": cut]
        case "delete_selected":
            // deletes every selected clip and graphic; ripple=true (or magnetic on) closes gaps left by clips
            let ids = selection.filter { lockedTrack(of: $0) == nil }      // things on locked tracks stay
            guard !ids.isEmpty else { throw RenderError.message(selection.isEmpty ? "nothing selected" : "That track is locked - unlock it to delete") }
            let ripple = c["ripple"] == nil ? magnetic : flag(c, "ripple")
            try await mutate { p in
                p.overlays?.removeAll { ids.contains($0.id) }
                p.audioClips?.removeAll { ids.contains($0.id) }
                p.audioClips?.removeAll { $0.link.map { ids.contains($0) } ?? false }
                p.upperClips?.removeAll { ids.contains($0.id) }
                let gone = p.clips.filter { ids.contains($0.id) }.sorted { $0.offset > $1.offset }   // from the end, so earlier positions stay valid
                for g in gone {
                    p.clips.removeAll { $0.id == g.id }
                    if ripple { self.rippleDelete(&p, g.offset, g.offset + g.duration) }
                }
            }
            selection = []; selectedClip = nil; selectedOverlay = nil
            return ["deleted": ids.count]
        case "skim":
            // time=<s> or off=true : testing aid for the skimmer
            if flag(c, "off") { skim(to: nil) } else { skim(to: try need(num(c, "time"), "time")) }
            try? await Task.sleep(nanoseconds: 400_000_000)
            return ["playhead": playhead, "player_time": player.currentTime().seconds, "skim": live.skim ?? -1]
        case "ui_mouse":
            // testing aid: path="x,y;x,y;..." in window points (top-left origin), mods=shift,command,option ; down at first, drag, up at last
            let pts = (str(c, "path") ?? "").split(separator: ";").compactMap { pr -> CGPoint? in
                let v = pr.split(separator: ",").compactMap { Double($0) }; return v.count == 2 ? CGPoint(x: v[0], y: v[1]) : nil }
            guard !pts.isEmpty, let f = uiMouse else { throw RenderError.message("give path=x,y;x,y") }
            let ok = f(pts, (str(c, "mods") ?? "").split(separator: ",").map(String.init))
            try? await Task.sleep(nanoseconds: 300_000_000)
            return ["ok_sent": ok]
        case "ui_open":
            guard let f = uiOpen else { throw RenderError.message("no hook") }
            let ok = f(try need(str(c, "what"), "what")); try? await Task.sleep(nanoseconds: 700_000_000); return ["ok_sent": ok]
        case "quit":
            // save (when the project has a file) and close Cutgenie cleanly; used for restarts after an install
            if projectURL != nil && flag(c, "save") { _ = try await handle(["cmd": "save"]) }
            autosave()
            Log.write("quit requested")
            let info = NSApplication.shared.windows.filter { $0.isVisible }.map { "\(type(of: $0)) sheet=\($0.attachedSheet != nil) modal=\($0.isModalPanel)" }.joined(separator: "; ")
            Log.write("quit: windows \(info); modal \(NSApplication.shared.modalWindow.map { "\(type(of: $0))" } ?? "none")")
            // an open (or left-behind) pop-up sheet stops macOS from closing the app: close them first
            for w in NSApplication.shared.windows { if let sh = w.attachedSheet { w.endSheet(sh) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApplication.shared.terminate(nil) }
            // something refused to let Cutgenie close (seen with sheets left behind): the work is saved, so close anyway
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                Log.write("quit was refused; closing directly"); self?.releaseLock(); exit(0)
            }
            return ["quitting": true]
        case "ui_size":
            // testing aid (screenshots): w= h= window points; the main window is resized and moved to the top-left
            guard let f = uiSize else { throw RenderError.message("no hook") }
            let ok = f(try need(num(c, "w"), "w"), try need(num(c, "h"), "h")); try? await Task.sleep(nanoseconds: 600_000_000); return ["ok_sent": ok]
        case "ui_split":
            // testing aid (screenshots): top= height in points of the viewer row (the line between it and the timeline)
            guard let f = uiSplit else { throw RenderError.message("no hook") }
            let ok = f(try need(num(c, "top"), "top")); try? await Task.sleep(nanoseconds: 600_000_000); return ["ok_sent": ok]
        case "ui_window":
            return ["window": uiWindowID?() ?? 0]
        case "ui_png":
            guard let f = uiPNG else { throw RenderError.message("no hook") }
            return ["ok_written": f(try need(str(c, "out"), "out"))]
        case "pointer_png":
            // testing aid: writes the blade pointer image to out=
            guard let f = pointerImage else { throw RenderError.message("no pointer image") }
            let out = try need(str(c, "out"), "out"); return ["ok_written": f(out)]
        case "ui_key":
            // testing aid: key=<character or name: space left right up down home end delete escape> mods=shift,command,option
            guard let f = uiKey else { throw RenderError.message("no key hook") }
            let ok = f(try need(str(c, "key"), "key"), (str(c, "mods") ?? "").split(separator: ",").map(String.init))
            try? await Task.sleep(nanoseconds: 400_000_000)
            return ["ok_sent": ok]
        case "ui_scroll":
            // testing aid: a scroll-wheel event at x,y (window points, top-left) with dy lines, mods=shift,command, precise=true
            guard let f = uiScroll else { throw RenderError.message("no scroll hook") }
            var m = (str(c, "mods") ?? "").split(separator: ",").map(String.init); if flag(c, "precise") { m.append("precise") }
            let ok = f(CGPoint(x: try need(num(c, "x"), "x"), y: try need(num(c, "y"), "y")), try need(num(c, "dy"), "dy"), m)
            try? await Task.sleep(nanoseconds: 500_000_000)
            return ["ok_sent": ok, "pps": pxPerSec, "zoom": zoomDebug]
        case "set_tool":
            tool = try need(str(c, "tool"), "tool"); return ["tool": tool]
        case "ui_sections":
            // testing aid: only=key1,key2 opens just those inspector sections (keys as in InspectorSection, e.g. wheels, a.eq,
            // pip.zoom) and folds every other one; all=open unfolds them all again
            let all = ["clip.volume", "clip.fades", "clip.info", "clip.speed", "a.gate", "a.eq", "a.comp", "a.out", "a.loud", "input", "basic",
                       "wheels", "looks", "project", "viewer", "fx.shape", "fx.transform", "fx.crop", "fx.mask", "fx.behave", "fx.build", "fx.fade",
                       "fx.effects", "fx.text", "pip.zoom", "pip.slide", "pip.keys", "pip.transform", "pip.shadow", "pip.crop"]
            let only = Set((str(c, "only") ?? "").split(separator: ",").map(String.init))
            for k in all { UserDefaults.standard.set(str(c, "all") == "open" || only.contains(k), forKey: "inspector.section." + k) }
            try? await Task.sleep(nanoseconds: 400_000_000)
            return ["open": Array(only)]
        case "ui_state":
            return ["tl": [timelineFrame.minX, timelineFrame.minY, timelineFrame.width, timelineFrame.height], "skim": live.skim ?? -1, "hover": hoverX ?? -1, "scroll_x": scrollX, "scroll_y": scrollY, "zoom": zoomDebug, "msg": lastMessage, "tool": tool, "selection": Array(selection), "clips": project.clips.count, "graphics": project.overlays?.count ?? 0, "playhead": playhead, "pps": pxPerSec]
        case "add_marker":
            // at= (default: skimmer, else playhead) name=
            let t = snap(num(c, "at") ?? (hoverX != nil && skimming ? live.skim : nil) ?? playhead)
            var n = (project.markers?.count ?? 0) + 1
            while project.markers?.contains(where: { $0.id == "m\(n)" }) == true { n += 1 }
            let clipID = project.clips.first { t >= $0.offset && t < $0.offset + $0.duration }?.id
            let m = Marker(id: "m\(n)", time: t, name: str(c, "name") ?? "Marker \(n)", clip: clipID)
            try await mutate { p in p.markers = (p.markers ?? []) + [m] }
            selectedMarker = m.id
            return ["id": m.id, "time": t]
        case "rename_marker":
            let id = try need(str(c, "id") ?? selectedMarker, "id"), name = str(c, "name") ?? ""
            guard let i = project.markers?.firstIndex(where: { $0.id == id }) else { throw RenderError.message("no marker \(id)") }
            try await mutate { $0.markers![i].name = name }
            return [:]
        case "delete_marker":
            let id = try need(str(c, "id") ?? selectedMarker, "id")
            guard project.markers?.contains(where: { $0.id == id }) == true else { throw RenderError.message("no marker \(id)") }
            try await mutate { $0.markers?.removeAll { $0.id == id } }
            if selectedMarker == id { selectedMarker = nil }
            return [:]
        case "move_marker":
            let id = try need(str(c, "id"), "id"), t = snap(try need(num(c, "at"), "at"))
            guard let i = project.markers?.firstIndex(where: { $0.id == id }) else { throw RenderError.message("no marker \(id)") }
            try await mutate { p in p.markers![i].time = t; p.markers![i].clip = p.clips.first { t >= $0.offset && t < $0.offset + $0.duration }?.id }
            return [:]
        case "next_marker", "previous_marker":
            let ts = (project.markers ?? []).map { $0.time }.sorted()
            let t = name == "next_marker" ? ts.first { $0 > playhead + frame * 0.5 } : ts.last { $0 < playhead - frame * 0.5 }
            guard let t else { throw RenderError.message("No more markers") }
            playhead = t
            await player.seek(to: CMTime(seconds: t, preferredTimescale: 6000), toleranceBefore: .zero, toleranceAfter: .zero)
            selectedMarker = project.markers?.first { abs($0.time - t) < 0.001 }?.id
            return ["time": t]
        case "select":
            selectedClip = str(c, "clip"); if let ids = str(c, "ids") { selection = Set(ids.split(separator: ",").map(String.init)) }
            return [:]
        case "undo":
            guard let prev = undoStack.popLast() else { throw RenderError.message("Nothing to undo") }
            let cur = project
            redoStack.append(cur); liveOv = nil; liveUp = nil; liveV1 = nil; project = prev
            if applySoft(from: cur, to: prev) { refreshFrame() } else if await applyAudioSoft(from: cur, to: prev) {} else { try await rebuild() }
            return [:]
        case "redo":
            guard let nxt = redoStack.popLast() else { throw RenderError.message("Nothing to redo") }
            let cur = project
            undoStack.append(cur); liveOv = nil; liveUp = nil; liveV1 = nil; project = nxt
            if applySoft(from: cur, to: nxt) { refreshFrame() } else if await applyAudioSoft(from: cur, to: nxt) {} else { try await rebuild() }
            return [:]
        case "playback_scale":
            // scale=1|0.5|0.25 - viewer playback resolution
            playbackScale = try need(num(c, "scale"), "scale")
            try? await Task.sleep(nanoseconds: 400_000_000)     // the change rebuilds by itself
            return ["scale": playbackScale, "render": [built?.videoComposition.renderSize.width ?? 0, built?.videoComposition.renderSize.height ?? 0]]
        case "render_frame":
            // [scale=0.5] renders the way half-resolution playback draws it (for checking)
            let b: Built
            if let k = num(c, "scale") { b = try await Renderer.build(project, base: base, scale: k) } else { b = try await fullBuilt() }
            let out = URL(fileURLWithPath: ((try need(str(c, "out"), "out")) as NSString).expandingTildeInPath)
            try await Renderer.renderFrame(b, at: try need(num(c, "time"), "time"), to: out)
            return ["file": out.path]
        case "export":
            // out= [container=mp4|mov|m4v|m4a|wav] [codec=h264|hevc|prores422lt|prores422|prores422hq|prores4444] [mbps=] [width= height=]
            // [audio=aac|pcm] [kbps=] [from= to=] [overwrite=true]
            let b = try await fullBuilt()
            let out = URL(fileURLWithPath: ((try need(str(c, "out"), "out")) as NSString).expandingTildeInPath)
            var o = ExportOptions()
            o.container = str(c, "container") ?? (["mov", "m4v", "m4a", "wav"].contains(out.pathExtension.lowercased()) ? out.pathExtension.lowercased() : "mp4")
            o.codec = str(c, "codec") ?? "h264"
            if let m = num(c, "mbps") { o.bitrateMbps = m }
            o.quality = num(c, "quality")
            if let w = num(c, "width"), let h = num(c, "height") { o.width = Int(w); o.height = Int(h) }
            o.audio = str(c, "audio") ?? "aac"
            if let k = num(c, "kbps") { o.audioKbps = Int(k) }
            o.from = num(c, "from"); o.to = num(c, "to")
            try await runExport(b, to: out, options: o, overwrite: flag(c, "overwrite"))
            return ["file": out.path]
        default:
            throw RenderError.message("unknown command '\(name)'")
        }
    }
}


/// a media file's picture size and frame rate
public struct MediaFormat: Equatable, Sendable {
    public var width: Int, height: Int, fps: Double, hdr: String?
    public var path: String?
    public static func read(_ u: URL) async -> MediaFormat? {
        guard let vt = try? await AVURLAsset(url: u).loadTracks(withMediaType: .video).first,
              let (sz, tr, r, fds) = try? await vt.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions) else { return nil }
        let s = sz.applying(tr)
        var fps = Double(r)
        for x in [23.976, 29.97, 59.94, 24, 25, 30, 50, 60, 120, 240] where abs(fps - x) < 0.02 { fps = x }
        var hdr: String?
        if let fd = fds.first, let tf = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
            if tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) { hdr = "HLG" } else if tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) { hdr = "PQ" }
        }
        return MediaFormat(width: Int(abs(s.width).rounded()), height: Int(abs(s.height).rounded()), fps: fps, hdr: hdr)
    }
    public var label: String {
        let k: String
        switch (max(width, height), min(width, height)) {
        case (3840, 2160), (4096, 2160): k = "4K"
        case (1920, 1080): k = "1080p"
        case (1280, 720): k = "720p"
        case (2560, 1440): k = "1440p"
        default: k = "\(width)×\(height)"
        }
        return "\(k)\(height > width ? " vertical" : "") · \(Editor.fpsName(fps))\(hdr.map { " · " + $0 } ?? "")"
    }
}


// colour grading reaches every video track: index n >= 0 = V1 clip n, n < 0 = upperClips[-1 - n],
// n <= adjBase = adjustment layer overlays[adjBase - n]
public extension Project {
    static let adjBase = -1_000_000
    func gradeClip(_ i: Int) -> Clip? {
        if i <= Project.adjBase {
            let k = Project.adjBase - i
            guard let ov = overlays, ov.indices.contains(k), let a = ov[k].adjust else { return nil }
            return Clip(id: ov[k].id, asset: "adjust:" + ov[k].id, duration: ov[k].duration, offset: ov[k].offset, color: a, lane: ov[k].lane)
        }
        if i >= 0 { return clips.indices.contains(i) ? clips[i] : nil }
        let u = -1 - i; return (upperClips ?? []).indices.contains(u) ? upperClips![u] : nil
    }
    func gradeIndex(of id: String) -> Int? {
        if let i = clips.firstIndex(where: { $0.id == id }) { return i }
        if let u = upperClips?.firstIndex(where: { $0.id == id }) { return -1 - u }
        if let k = overlays?.firstIndex(where: { $0.id == id && $0.adjust != nil }) { return Project.adjBase - k }
        return nil
    }
    var gradeIndices: [Int] { Array(clips.indices) + (upperClips ?? []).indices.map { -1 - $0 } }
    mutating func editColor(_ i: Int, _ f: (inout ColorParams) -> Void) {
        if i <= Project.adjBase {
            let k = Project.adjBase - i
            if var ov = overlays, ov.indices.contains(k), var a = ov[k].adjust { f(&a); ov[k].adjust = a; overlays = ov }
            return
        }
        if i >= 0 { if clips.indices.contains(i) { f(&clips[i].color) } }
        else { let u = -1 - i; if var up = upperClips, up.indices.contains(u) { f(&up[u].color); upperClips = up } }
    }
}

// MARK: saved looks, copied grades, audio presets (kept for every project in ~/Library/Application Support/Cutgenie)
public struct SavedLook: Codable, Equatable {
    public var name: String
    public var color: ColorParams
    public var lutPaths: [String: String] = [:]     // LUT asset id in `color` -> the .cube file
}

extension Editor {
    static var supportDir: URL {
        if let o = ProcessInfo.processInfo.environment["CUTGENIE_LOOKS"] { return URL(fileURLWithPath: o) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cutgenie")
    }
    static var looksDir: URL { supportDir.appendingPathComponent("Looks") }
    static var audioPresetsDir: URL { supportDir.appendingPathComponent("Audio presets") }
    static func names(_ d: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    public static func savedLooks() -> [String] { names(looksDir) }
    public static func savedAudioPresets() -> [String] { names(audioPresetsDir) }

    func lookOf(_ col: ColorParams, name: String) -> SavedLook {
        var l = SavedLook(name: name, color: col)
        for s in col.luts ?? [] { if let u = project.resolve(s.asset, base: base) { l.lutPaths[s.asset] = u.path } }
        return l
    }
    /// gives the target clips (ids= or the selection) the look's grade; its LUT files become project assets
    func applyLook(_ l: SavedLook, _ c: [String: Any]) async throws -> [String: Any] {
        let ids = str(c, "ids").map { Set($0.split(separator: ",").map(String.init)) } ?? selection
        var idx = ids.compactMap { project.gradeIndex(of: $0) }
        if idx.isEmpty { idx = gradeTargets }
        guard !idx.isEmpty else { throw RenderError.message("select the clips to give it to") }
        var col = l.color
        var newAssets: [Asset] = []
        var map: [String: String] = [:]
        for (old, path) in l.lutPaths {
            let rel = base.map { path.hasPrefix($0.path + "/") ? String(path.dropFirst($0.path.count + 1)) : path } ?? path
            if let a = project.assets.first(where: { $0.path == rel || $0.path == path }) { map[old] = a.id; continue }
            guard FileManager.default.fileExists(atPath: path) else { throw RenderError.message("LUT file is missing: \(path)") }
            var n = project.assets.count + newAssets.count + 1
            while (project.assets + newAssets).contains(where: { $0.id == "a\(n)" }) { n += 1 }
            newAssets.append(Asset(id: "a\(n)", path: path)); map[old] = "a\(n)"
        }
        col.luts = col.luts?.compactMap { s in var x = s; guard let m = map[s.asset] else { return nil }; x.asset = m; return x }
        if col.luts?.isEmpty == true { col.luts = nil }
        try await mutate { p in p.assets += newAssets; for i in idx { p.editColor(i) { $0 = col } } }
        return ["clips": idx.compactMap { project.gradeClip($0)?.id }]
    }
}
