import AVFoundation
import CoreImage
import AppKit

public struct Built {
    public let composition: AVMutableComposition
    public let videoComposition: AVMutableVideoComposition
    public var audioMix: AVMutableAudioMix
    let store: ColorStore
    let upperStore: ColorStore          // grades of clips on V2+ (live while dragging a slider, like V1)
    public var audioStore: AudioStore
    let overlayStore: OverlayStore
    let upperXf: UpperXfStore
    let adjStore: AdjStore              // adjustment layers (grade everything below them)
    public var laneAudio: [Int: AudioStore] = [:]   // effects of audio tracks A2, A3... (live)
    let fix2020: [String: Bool]
    public let duration: Double
}

public enum RenderError: Error, CustomStringConvertible {
    case message(String)
    public var description: String { if case .message(let m) = self { return m }; return "error" }
}

// The ONE place that turns "project at time t" into pixels and sound.
// Playback, still-frame render and export all use what build() returns.
final class Counter: @unchecked Sendable { private var n = 0; private let l = NSLock(); func next() -> Int { l.lock(); defer { l.unlock() }; n += 1; return n } }
let debugCount = Counter()
let writerCount = Counter()

// Per-clip colour as the renderer sees it. The render handler reads it on every frame, so a grade can be changed
// live (while a slider is dragged) without rebuilding the whole timeline.
final class ColorStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snaps: [Renderer.ClipSnap]
    private let index: [String: Int]
    var outSpace = "rec709", toneMap = "soft", wheelScale = 0.32, wheelRange = 0.25, wheelMid = 0.8
    init(_ s: [Renderer.ClipSnap], ids: [String]) {
        snaps = s
        var d: [String: Int] = [:]; for (i, id) in ids.enumerated() { d[id] = i }
        index = d
    }
    func all() -> [Renderer.ClipSnap] { lock.lock(); defer { lock.unlock() }; return snaps }
    func get(_ id: String) -> Renderer.ClipSnap? { lock.lock(); defer { lock.unlock() }; return index[id].map { snaps[$0] } }
    func set(_ id: String, color: ColorParams, luts: [Renderer.LoadedLUT]) {
        lock.lock(); defer { lock.unlock() }
        if let i = index[id] { snaps[i].color = color; snaps[i].luts = luts }
    }
    func setZoom(_ id: String, _ z: [Keyframe]) { lock.lock(); defer { lock.unlock() }; if let i = index[id] { snaps[i].zoom = z } }
    func setMotion(_ id: String, _ m: [Keyframe]) { lock.lock(); defer { lock.unlock() }; if let i = index[id] { snaps[i].motion = m } }
}

/// adjustment layers as the renderer sees them; the grade can change live (slider drags), placement changes rebuild
final class AdjStore: @unchecked Sendable {
    struct Snap { var o: Overlay; var luts: [Renderer.LoadedLUT] }
    private let lock = NSLock()
    private var snaps: [Snap]
    init(_ s: [Snap]) { snaps = s }
    func all() -> [Snap] { lock.lock(); defer { lock.unlock() }; return snaps }
    func has(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return snaps.contains { $0.o.id == id } }
    func set(_ o: Overlay, luts: [Renderer.LoadedLUT]) { lock.lock(); if let i = snaps.firstIndex(where: { $0.o.id == o.id }) { snaps[i] = Snap(o: o, luts: luts) }; lock.unlock() }
}

/// media files and LUTs stay open between edits (a blade / undo rebuilds the timeline from them in a fraction of the time);
/// a file that changed on disk (new modification date or size) is opened again
public enum MediaCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var assets: [String: (AVURLAsset, Date?, Int?)] = [:]
    nonisolated(unsafe) private static var luts: [String: (CubeLUT, Date?)] = [:]
    // a file's date / size, asked of the disk at most every 2 s (a rebuild asks once per clip: 200+ times for the same files)
    nonisolated(unsafe) private static var stamps: [String: (at: Double, v: (Date?, Int?)?)] = [:]
    static func stamp(_ u: URL) -> (Date?, Int?)? {
        let now = CACurrentMediaTime()
        lock.lock(); if let s = stamps[u.path], now - s.at < 2 { lock.unlock(); return s.v }; lock.unlock()
        let at = try? FileManager.default.attributesOfItem(atPath: u.path)
        let v: (Date?, Int?)? = at.map { ($0[.modificationDate] as? Date, ($0[.size] as? NSNumber)?.intValue) }
        lock.lock(); stamps[u.path] = (now, v); lock.unlock()
        return v
    }
    public static func asset(_ u: URL) -> AVURLAsset? {
        guard let st = stamp(u) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let c = assets[u.path], c.1 == st.0, c.2 == st.1 { return c.0 }
        let a = AVURLAsset(url: u); assets[u.path] = (a, st.0, st.1); return a
    }
    static func lut(_ u: URL) throws -> CubeLUT {
        let st = stamp(u)
        lock.lock()
        if let c = luts[u.path], c.1 == st?.0 { lock.unlock(); return c.0 }
        lock.unlock()
        let l = try LUTLoader.load(u)
        lock.lock(); luts[u.path] = (l, st?.0); lock.unlock()
        return l
    }
}

public enum FillerDebug { nonisolated(unsafe) public static var message = "" }

public enum Renderer {
    // a file's video / sound tracks, loaded once and remembered (the file object itself is shared by MediaCache)
    nonisolated(unsafe) static var trackMemo: [ObjectIdentifier: [AVMediaType: [AVAssetTrack]]] = [:]
    static let trackLock = NSLock()
    static func tracks(_ a: AVURLAsset, _ type: AVMediaType) async -> [AVAssetTrack] {
        let k = ObjectIdentifier(a)
        trackLock.lock(); if let t = trackMemo[k]?[type] { trackLock.unlock(); return t }; trackLock.unlock()
        let t = (try? await a.loadTracks(withMediaType: type)) ?? []
        trackLock.lock(); trackMemo[k, default: [:]][type] = t; trackLock.unlock()
        return t
    }

    struct LoadedLUT { var slot: String; var lut: CubeLUT; var intensity: Double; var inSpace: String?; var outSpace: String? }
    struct ClipSnap { var offset: Double; var duration: Double; var color: ColorParams; var fix2020: Bool; var autoSpace: String; var luts: [LoadedLUT]; var off = false; var motion: [Keyframe] = []; var orient: CGAffineTransform = .identity; var zoom: [Keyframe] = []; var anchor: [Double] = [0, 0]; var id = "" }
    /// a track's turn flag (y-down, as stored in the file) as a Core Image turn (y-up)
    static func ciOrient(_ t: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(a: t.a, b: -t.b, c: -t.c, d: t.d, tx: 0, ty: 0)
    }
    /// the picture turned, moved back so its corner sits at 0,0
    static func turn(_ u: CIImage, _ r: CGAffineTransform) -> CIImage {
        let x = u.transformed(by: r)
        return x.transformed(by: CGAffineTransform(translationX: -x.extent.minX, y: -x.extent.minY))
    }
    /// a clip's picture-in-picture settings: crop, then scale / rotate around the frame centre, move, fade, drop shadow
    static func applyXf(_ u0: CIImage, _ x: ClipXf, _ extent: CGRect) -> CIImage {
        var u = u0
        if let cr = x.crop, cr.contains(where: { $0 > 0.0001 }) {
            u = u.cropped(to: CGRect(x: extent.width * cr[0], y: extent.height * cr[3], width: extent.width * max(0.02, 1 - cr[0] - cr[1]), height: extent.height * max(0.02, 1 - cr[2] - cr[3])))
        }
        let pu = extent.height / 100, pos = x.position ?? [0, 0]
        var tr = CGAffineTransform(translationX: -extent.midX, y: -extent.midY).concatenating(CGAffineTransform(scaleX: x.scale ?? 1, y: x.scale ?? 1))
        if let r = x.rotation, abs(r) > 0.001 { tr = tr.concatenating(CGAffineTransform(rotationAngle: r * .pi / 180)) }
        tr = tr.concatenating(CGAffineTransform(translationX: extent.midX + pos[0] * pu, y: extent.midY + pos[1] * pu))
        u = u.transformed(by: tr).cropped(to: extent)
        if let sh = x.shadow, sh.count >= 3, sh[0] > 0.001 {
            // shadow = the picture's outline in black, softened and moved down-right
            let s = u.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                                   "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: sh[0])])
                .clampedToExtent().cropped(to: u.extent.insetBy(dx: -1, dy: -1))
                .applyingGaussianBlur(sigma: max(0, sh[1]) / 2)
                .transformed(by: CGAffineTransform(translationX: sh[2], y: -sh[2]))
            u = u.composited(over: s)
        }
        if let o = x.opacity, o < 0.999 { u = u.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: o)]) }
        return u
    }
    struct TitleSnap { var at: Double; var duration: Double; var image: CIImage }

    /// clip volume: one level, or ramps between the volume keyframes
    /// clip volume: level line (gain or keyframes) times the fade-in / fade-out curves
    static func volume(_ pr: AVMutableAudioMixInputParameters, offset: Double, duration: Double, gain: Double, keys: [VolKey]?,
                       fadeIn: Double? = nil, fadeOut: Double? = nil) {
        func tm(_ t: Double) -> CMTime { CMTime(seconds: t, preferredTimescale: 6000) }
        let k = keys?.filter { $0.t >= 0 && $0.t <= duration }.sorted { $0.t < $1.t }
        let kk = (k?.isEmpty ?? true) ? nil : k
        func amp(_ t: Double) -> Float {
            let db = Volume.level(gain: gain, keys: kk, at: t)
            return db <= -95 ? 0 : Float(pow(10.0, db / 20.0) * Volume.fade(t, duration: duration, fadeIn: fadeIn, fadeOut: fadeOut))
        }
        // break points: clip start/end, keyframes, fade edges; between them step every 50 ms where the level changes
        var bp = [0.0, duration] + (kk ?? []).map { $0.t }
        if let i = fadeIn, i > 0.001 { bp.append(min(i, duration)) }
        if let o = fadeOut, o > 0.001 { bp.append(max(0, duration - o)) }
        bp = Array(Set(bp.map { ($0 * 10000).rounded() / 10000 })).sorted()
        pr.setVolume(amp(0), at: tm(offset))
        for i in 1..<bp.count {
            let a = bp[i - 1], b = bp[i]
            guard b - a > 0.0005 else { continue }
            let changes = abs(amp(a) - amp(b)) > 0.0001 || abs(amp((a + b) / 2) - amp(a)) > 0.0001
            let n = changes ? max(1, Int(((b - a) / 0.05).rounded(.up))) : 1
            for j in 0..<n {
                let t0 = a + (b - a) * Double(j) / Double(n), t1 = a + (b - a) * Double(j + 1) / Double(n)
                pr.setVolumeRamp(fromStartVolume: amp(t0 + 0.0001), toEndVolume: amp(t1 - 0.0001), timeRange: CMTimeRange(start: tm(offset + t0), end: tm(offset + t1)))
            }
        }
    }

    /// A1 clip volume segments for the audio processor
    static func a1Volume(_ p: Project) -> [AudioStore.VolSeg] {
        let mute = (p.hiddenTracks ?? []).contains("A1")
        return p.clips.filter { $0.audioDetached != true }.map { c in
            AudioStore.VolSeg(offset: c.offset, duration: c.duration, gain: mute || c.disabled == true ? -96 : c.audio.gainDb, keys: mute || c.disabled == true ? nil : (c.audio.keys?.isEmpty == false ? c.audio.keys : nil),
                              fadeIn: c.audio.fadeIn, fadeOut: c.audio.fadeOut)
        }
    }

    public static func build(_ p: Project, base: URL?, scale: Double = 1) async throws -> Built {
        let comp = AVMutableComposition()
        let hidden = Set(p.hiddenTracks ?? [])          // hidden video tracks / muted audio tracks
        let audioMix = AVMutableAudioMix()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw RenderError.message("cannot create video track") }
        let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        let params = aTrack.map { AVMutableAudioMixInputParameters(track: $0) }
        // one A1 track per sound format (rate + channels): a tapped track that switches format mid-way (44.1 kHz mono voice,
        // then a 48 kHz stereo video) freezes AVFoundation's player and export, so each format gets its own track
        var a1Tracks: [String: AVMutableCompositionTrack] = [:]
        var a1Extra: [AVMutableAudioMixInputParameters] = []
        func a1Track(for t: AVAssetTrack) async -> AVMutableCompositionTrack? {
            var key = "?"
            if let fd = try? await t.load(.formatDescriptions).first, let d = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                key = "\(d.mSampleRate)-\(d.mChannelsPerFrame)"
            }
            if let x = a1Tracks[key] { return x }
            if a1Tracks.isEmpty { a1Tracks[key] = aTrack; return aTrack }
            guard let n = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return aTrack }
            a1Tracks[key] = n; a1Extra.append(AVMutableAudioMixInputParameters(track: n))
            return n
        }

        // each file opened once per build (not once per clip: the file check and path lookup added up on long timelines)
        var opened: [String: AVURLAsset] = [:]
        var missing = Set<String>()
        // a missing file does not stop the whole timeline: its clips are left out (black / silent) and shown as Missing
        func open(_ id: String, for clip: String) throws -> AVURLAsset? {
            if let a = opened[id] { return a }
            guard let url = p.resolve(id, base: base) else { throw RenderError.message("clip \(clip): unknown asset \(id)") }
            guard let a = MediaCache.asset(url) else { missing.insert(url.path); return nil }
            opened[id] = a
            return a
        }
        var fix2020: [String: Bool] = [:]
        // phone clips filmed sideways carry a turn flag: the frame handler gets the stored (unturned) picture, so it is turned there
        var orient: [String: CGAffineTransform] = [:]
        func readOrient(_ id: String, _ v: AVAssetTrack) async {
            guard orient[id] == nil, let t = try? await v.load(.preferredTransform) else { return }
            orient[id] = Renderer.ciOrient(t)
        }
        // gaps in the picture are filled with a black clip (in timeline order, so nothing shifts) so graphic layers can be drawn there
        // filler = one second of the project's first picture file (same format as the rest of the track; the frame handler
        // paints these stretches black and draws the graphic layers on top, so none of it is visible)
        var blackTrack: AVAssetTrack?; var blackRange = CMTimeRange.zero
        for c in p.clips {
            if let u = p.resolve(c.asset, base: base), let oa = try? open(c.asset, for: c.id), let t = await Renderer.tracks(oa, .video).first {
                _ = u; blackTrack = t
                let r = try await t.load(.timeRange)
                blackRange = r
                break
            }
        }
        var videoEnd = 0.0
        func fill(to end: Double) {
            guard let bt = blackTrack, end > videoEnd + 0.001 else { return }
            let at = CMTime(seconds: videoEnd, preferredTimescale: 6000)
            // normal-speed filler (no stretching, so every frame is drawn), repeated if the gap is longer than the file
            var pos = videoEnd
            while end - pos > 0.001 {
                let len = min(end - pos, blackRange.duration.seconds)
                do {
                    try vTrack.insertTimeRange(CMTimeRange(start: blackRange.start, duration: CMTime(seconds: len, preferredTimescale: 6000)),
                                               of: bt, at: CMTime(seconds: pos, preferredTimescale: 6000))
                } catch { FillerDebug.message = "insert at \(pos): \(error)"; break }
                pos += len
            }
            _ = at
            videoEnd = end
        }
        for c in p.clips.sorted(by: { $0.offset < $1.offset }) {
            guard let asset = try open(c.asset, for: c.id) else { continue }
            if fix2020[c.asset] == nil, let v = await Renderer.tracks(asset, .video).first,
               let fd = try await v.load(.formatDescriptions).first {
                let m = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
                fix2020[c.asset] = (m == (kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String))
            }
            let range = CMTimeRange(start: CMTime(seconds: c.sourceIn, preferredTimescale: 6000),
                                    duration: CMTime(seconds: c.duration * c.sp, preferredTimescale: 6000))
            let speedRange = CMTimeRange(start: CMTime(seconds: c.offset, preferredTimescale: 6000), duration: CMTime(seconds: c.duration * c.sp, preferredTimescale: 6000))
            let shown = CMTime(seconds: c.duration, preferredTimescale: 6000)
            let at = CMTime(seconds: c.offset, preferredTimescale: 6000)
            if let v = await Renderer.tracks(asset, .video).first {
                fill(to: c.offset)
                try vTrack.insertTimeRange(range, of: v, at: at)
                if abs(c.sp - 1) > 0.0001 { vTrack.scaleTimeRange(speedRange, toDuration: shown) }      // speed change
                videoEnd = c.offset + c.duration
                await readOrient(c.asset, v)
            }
            let audioAsset = (try c.audioSource.map { try open($0.asset, for: c.id) } ?? asset) ?? asset
            let audioRange = CMTimeRange(start: CMTime(seconds: c.audioSource?.sourceIn ?? c.sourceIn, preferredTimescale: 6000),
                                         duration: CMTime(seconds: c.duration * c.sp, preferredTimescale: 6000))
            if c.audioDetached != true, let a = await Renderer.tracks(audioAsset, .audio).first, let at2 = await a1Track(for: a) {
                try at2.insertTimeRange(audioRange, of: a, at: at)
                if abs(c.sp - 1) > 0.0001 { at2.scaleTimeRange(speedRange, toDuration: shown) }
                // (A1 clip volume is applied by the audio processor - see AudioStore.setVolume below)
            }
        }
        fill(to: p.clips.map { $0.offset + $0.duration }.max() ?? 0)
        let audioStore = AudioStore(p.audioChain ?? AudioChain())
        audioStore.setVolume(Renderer.a1Volume(p))
        if let params {
            params.audioTapProcessor = AudioTap.make(audioStore)
            audioMix.inputParameters = [params]
            for x in a1Extra { x.audioTapProcessor = AudioTap.make(audioStore); audioMix.inputParameters.append(x) }
        }
        // extra audio tracks (A2...): one composition track per lane, volume per clip, mixed after the A1 effects chain
        let endT = p.totalDuration
        var laneAudio: [Int: AudioStore] = [:]
        for lane in Set((p.audioClips ?? []).map { $0.lane }).sorted() {
            guard let tr = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let pr = AVMutableAudioMixInputParameters(track: tr)
            // the track's own effects (EQ, compressor...), after each clip's volume
            let ls = AudioStore(p.trackAudio?["A\(lane)"] ?? AudioChain()); ls.meters = false
            pr.audioTapProcessor = AudioTap.make(ls); laneAudio[lane] = ls
            var laneEnd = 0.0
            for a0 in (p.audioClips ?? []).filter({ $0.lane == lane }).sorted(by: { $0.offset < $1.offset }) where a0.offset < endT {
                // two sounds overlapping on one track can't both play there: the later one starts where the earlier ends
                // (the volume ramps must never overlap - AVFoundation stops the app if they do)
                var a = a0
                if a.offset < laneEnd {
                    let cut = laneEnd - a.offset
                    guard cut < a.duration - 0.01 else { continue }
                    a.offset += cut; a.sourceIn += cut; a.duration -= cut; a.fadeIn = nil
                    a.keys = a.keys?.map { VolKey(t: $0.t - cut, db: $0.db) }
                }
                laneEnd = max(laneEnd, a.offset + a.duration)
                guard let srcAsset = try open(a.asset, for: a.id), let src = await Renderer.tracks(srcAsset, .audio).first else { continue }
                let d = min(a.duration, endT - a.offset)
                try tr.insertTimeRange(CMTimeRange(start: CMTime(seconds: a.sourceIn, preferredTimescale: 6000), duration: CMTime(seconds: d, preferredTimescale: 6000)),
                                       of: src, at: CMTime(seconds: a.offset, preferredTimescale: 6000))
                // muted track, or the sound of a clip on a video track whose sound is switched off (track header speaker)
                let vl = (a.link ?? a.syncWith).flatMap { id in (p.upperClips ?? []).first { $0.id == id }?.lane }
                let muted = a.disabled == true || hidden.contains("A\(a.lane)") || vl.map { hidden.contains("V\($0 + 1) SOUND") } == true
                Renderer.volume(pr, offset: a.offset, duration: d, gain: muted ? -96 : a.gainDb, keys: muted ? nil : a.keys, fadeIn: a.fadeIn, fadeOut: d < a.duration - 0.001 ? nil : a.fadeOut)
            }
            audioMix.inputParameters.append(pr)
        }

        // scale < 1: playback at half / quarter resolution (lighter on the CPU); exports always build at 1
        let sc = min(1, max(0.25, scale))
        OverlayRender.projectHeight = Double(p.settings.height)
        let W = max(2, Int((Double(p.settings.width) * sc / 2).rounded()) * 2), H = max(2, Int((Double(p.settings.height) * sc / 2).rounded()) * 2)
        // video tracks V2, V3...: one composition video track per track number, plus the clips' own sound
        var upperTracks: [Int: CMPersistentTrackID] = [:]
        var upperSnaps: [(lane: Int, snap: ClipSnap, id: String)] = []
        let upperXf = UpperXfStore((p.clips + (p.upperClips ?? [])).reduce(into: [:]) { d, c in if let x = c.xf { d[c.id] = x } })
        let ups = p.upperClips ?? []
        for lane in Set(ups.map { $0.lane ?? 1 }).sorted() {
            guard let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            let apr = at.map { AVMutableAudioMixInputParameters(track: $0) }
            for c in ups.filter({ ($0.lane ?? 1) == lane }).sorted(by: { $0.offset < $1.offset }) {
                guard let asset = try open(c.asset, for: c.id) else { continue }
                let start = CMTime(seconds: c.offset, preferredTimescale: 6000)
                if let v = await Renderer.tracks(asset, .video).first {
                    await readOrient(c.asset, v)
                    if fix2020[c.asset] == nil, let fd = try await v.load(.formatDescriptions).first {
                        let m = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
                        fix2020[c.asset] = (m == (kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String))
                    }
                    try vt.insertTimeRange(CMTimeRange(start: CMTime(seconds: c.sourceIn, preferredTimescale: 6000), duration: CMTime(seconds: c.duration * c.sp, preferredTimescale: 6000)), of: v, at: start)
                    if abs(c.sp - 1) > 0.0001 { vt.scaleTimeRange(CMTimeRange(start: start, duration: CMTime(seconds: c.duration * c.sp, preferredTimescale: 6000)), toDuration: CMTime(seconds: c.duration, preferredTimescale: 6000)) }
                }
                let aAsset = (try c.audioSource.map { try open($0.asset, for: c.id) } ?? asset) ?? asset
                if c.audioDetached != true, let a = await Renderer.tracks(aAsset, .audio).first, let at, let apr {
                    try at.insertTimeRange(CMTimeRange(start: CMTime(seconds: c.audioSource?.sourceIn ?? c.sourceIn, preferredTimescale: 6000), duration: CMTime(seconds: c.duration * c.sp, preferredTimescale: 6000)), of: a, at: start)
                    if abs(c.sp - 1) > 0.0001 { at.scaleTimeRange(CMTimeRange(start: start, duration: CMTime(seconds: c.duration * c.sp, preferredTimescale: 6000)), toDuration: CMTime(seconds: c.duration, preferredTimescale: 6000)) }
                    Renderer.volume(apr, offset: c.offset, duration: c.duration, gain: c.disabled == true ? -96 : c.audio.gainDb, keys: c.audio.keys, fadeIn: c.audio.fadeIn, fadeOut: c.audio.fadeOut)
                }
            }
            if let apr { audioMix.inputParameters.append(apr) }
            upperTracks[lane] = vt.trackID
        }
        var clips: [ClipSnap] = []
        for c in p.clips {
            // A clip that is not HLG itself, in a timeline that has HLG clips, is converted by AVFoundation into HLG before we see it,
            // so the chain must treat it as HLG too (the final conversion then brings it back to the project's output space).
            let anyHLG = fix2020.values.contains(true)
            let auto = (fix2020[c.asset] ?? false) || anyHLG ? "rec2020hlg" : "rec709"
            clips.append(ClipSnap(offset: c.offset, duration: c.duration, color: c.color, fix2020: fix2020[c.asset] ?? false, autoSpace: auto,
                                  luts: try loadLUTs(c.color, project: p, base: base, clip: c.id), off: c.disabled == true, motion: c.motion ?? [], orient: orient[c.asset] ?? .identity, zoom: c.zoom ?? [], anchor: c.zoomAnchor ?? [0, 0], id: c.id))
        }
        for c in ups where c.disabled != true {
            let anyHLG = fix2020.values.contains(true)
            let auto = (fix2020[c.asset] ?? false) || anyHLG ? "rec2020hlg" : "rec709"
            upperSnaps.append((c.lane ?? 1, ClipSnap(offset: c.offset, duration: c.duration, color: c.color, fix2020: fix2020[c.asset] ?? false, autoSpace: auto,
                                                     luts: try loadLUTs(c.color, project: p, base: base, clip: c.id), orient: orient[c.asset] ?? .identity), c.id))
        }
        let store = ColorStore(clips, ids: p.clips.map { $0.id })
        let upperStore = ColorStore(upperSnaps.map { $0.snap }, ids: upperSnaps.map { $0.id })
        store.outSpace = p.settings.colorSpace
        store.toneMap = p.settings.hdrToSdr ?? "soft"
        store.wheelScale = p.settings.wheelScale ?? 0.32
        store.wheelRange = p.settings.wheelRange ?? 0.25
        store.wheelMid = p.settings.wheelMid ?? 0.8
        let adjStore = AdjStore(try (p.overlays ?? []).filter { $0.adjust != nil && $0.disabled != true }.map { o in
            AdjStore.Snap(o: o, luts: try loadLUTs(o.adjust!, project: p, base: base, clip: o.id)) })
        let overlayStore = OverlayStore((p.overlays ?? []).filter { $0.adjust == nil && $0.disabled != true }.compactMap { o in
            p.layerPath(o, base: base).map { OverlayRender.Snap(o: o, path: $0) } }.sorted { $0.o.lane < $1.o.lane })
        let clipRanges = p.clips.filter { (fix2020[$0.asset] != nil) }.map { ($0.offset, $0.offset + $0.duration) }
        let titles: [TitleSnap] = p.titles.compactMap { lt in
            LowerThirdImage.make(lt, width: W, height: H).map { TitleSnap(at: lt.at, duration: lt.duration, image: $0) }
        }

        let raw = (p.settings.colorPipeline ?? "raw") == "raw"
        let ciContext: CIContext? = raw ? CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()]) : nil
        let fitMode = p.settings.fit ?? "fit"
        let frameRect = CGRect(x: 0, y: 0, width: W, height: H)
        /// a picture of another size placed in the project frame (Fit / Fill / actual size), centred, on black
        func conform(_ u: CIImage) -> CIImage {
            let e = u.extent
            guard e.width > 0, e.height > 0, abs(e.width - frameRect.width) > 0.5 || abs(e.height - frameRect.height) > 0.5 || e.origin != .zero else { return u }
            let k = fitMode == "none" ? 1 : (fitMode == "fill" ? max(frameRect.width / e.width, frameRect.height / e.height) : min(frameRect.width / e.width, frameRect.height / e.height))
            return u.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).concatenating(CGAffineTransform(scaleX: k, y: k))
                                    .concatenating(CGAffineTransform(translationX: (frameRect.width - e.width * k) / 2, y: (frameRect.height - e.height * k) / 2)))
                .cropped(to: frameRect)
        }
        let renderFn: (Double, CIImage, [Int: CIImage]) -> CIImage = { t, source, upper in
            // the camera picture placed in the project frame (a 4K clip in a 1080p project, a landscape clip in a 9:16 project...)
            var source = source
            if let c = store.all().first(where: { t >= $0.offset && t < $0.offset + $0.duration }), !c.orient.isIdentity { source = Renderer.turn(source, c.orient) }
            var img = source.extent.size == frameRect.size && source.extent.origin == .zero ? source
                : conform(source).composited(over: CIImage(color: .black).cropped(to: frameRect))
            let overlaySnaps = overlayStore.all().filter { t >= $0.o.offset && t < $0.o.offset + $0.o.duration }   // only layers on screen now
            if ProcessInfo.processInfo.environment["CUTGENIE_DEBUG"] != nil, debugCount.next() < 400 {
                var s = "handler t=\(t) colorSpace=\(img.colorSpace?.name.map { $0 as String } ?? "none") extent=\(img.extent)"
                if let pb = img.pixelBuffer {
                    s += " fmt=\(CVPixelBufferGetPixelFormatType(pb))"
                    let at = CVBufferCopyAttachments(pb, .shouldPropagate) as? [String: Any] ?? [:]
                    s += " attach=\(at.filter { $0.key.contains("Color") || $0.key.contains("Transfer") || $0.key.contains("YCbCr") }.mapValues { "\($0)" })"
                }
                let dctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
                let avg = img.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: img.extent)])
                var px = [Float](repeating: 0, count: 4)
                dctx.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                s += String(format: " AVG_IN rgb=%.4f %.4f %.4f", px[0], px[1], px[2])
                FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
            }
            let extent = frameRect
            if hidden.contains("V1") { img = CIImage(color: .black).cropped(to: extent) }
            else if let c = store.all().first(where: { t >= $0.offset && t < $0.offset + $0.duration }), c.off { img = CIImage(color: .black).cropped(to: extent) }
            else if let c = store.all().first(where: { t >= $0.offset && t < $0.offset + $0.duration }) {
                if c.fix2020 { img = fixMatrix2020(img) }
                img = applyColor(img, c.color, auto: c.autoSpace, out: store.outSpace, toneMap: store.toneMap, wheelScale: store.wheelScale, wheelShape: (store.wheelRange, store.wheelMid), luts: c.luts)
            }
            // V1 sliding aside (docked panel): the layers under V1 show in the space it leaves
            // V1 zoom (scaled about its anchor, picture kept inside the frame), then V1 sliding aside (docked panel)
            if let c = store.all().first(where: { t >= $0.offset && t < $0.offset + $0.duration }), !c.off, !hidden.contains("V1") {
                let pu = extent.height / 100
                if !c.zoom.isEmpty {
                    let k = KF.at(c.zoom, t - c.offset, [1])[0]
                    if abs(k - 1) > 0.0001 {
                        let ax = extent.midX + c.anchor[0] * pu, ay = extent.midY + (c.anchor.count > 1 ? c.anchor[1] : 0) * pu
                        img = img.transformed(by: CGAffineTransform(translationX: -ax, y: -ay).concatenating(CGAffineTransform(scaleX: k, y: k))
                                                .concatenating(CGAffineTransform(translationX: ax, y: ay))).cropped(to: extent)
                    }
                }
                // V1 transform (position / scale / crop / rotation / opacity / shadow): what it uncovers shows the layers under V1
                if let x0 = upperXf.get(c.id), !x0.isIdentity {
                    let x = x0.at(t - c.offset)
                    var under = CIImage(color: .black).cropped(to: extent)
                    for o in overlaySnaps where o.o.lane < 0 { under = OverlayRender.draw(o, t: t, frame: extent, over: under) }
                    img = Renderer.applyXf(img, x, extent).cropped(to: extent).composited(over: under)
                }
                if !c.motion.isEmpty {
                    let pv = KF.at(c.motion, t - c.offset, [0, 0])
                    if abs(pv[0]) > 0.0001 || abs(pv[1]) > 0.0001 {
                        var under = CIImage(color: .black).cropped(to: extent)
                        for o in overlaySnaps where o.o.lane < 0 { under = OverlayRender.draw(o, t: t, frame: extent, over: under) }
                        img = img.transformed(by: CGAffineTransform(translationX: pv[0] * pu, y: pv[1] * pu)).cropped(to: extent).composited(over: under)
                    }
                }
            }
            // graphic layers: below-the-storyline lanes only show where there is no main picture
            let hasPicture = !hidden.contains("V1") && clipRanges.contains { t >= $0.0 && t < $0.1 }
            if !hasPicture { img = CIImage(color: .black).cropped(to: extent) }
            for o in overlaySnaps where o.o.lane < 0 && !hasPicture {
                img = OverlayRender.draw(o, t: t, frame: extent, over: img)
            }
            // tracks above V1, bottom to top: the video clip on that track (graded like V1), then the layers on it
            let adjNow = adjStore.all().filter { t >= $0.o.offset && t < $0.o.offset + $0.o.duration && $0.o.lane > 0 }
            let lanes = Set(overlaySnaps.map { $0.o.lane }.filter { $0 > 0 } + upper.keys + adjNow.map { $0.o.lane }).sorted()
            for lane in lanes where !hidden.contains("V\(lane + 1)") {
                if var u = upper[lane], let us = upperSnaps.first(where: { $0.lane == lane && t >= $0.snap.offset && t < $0.snap.offset + $0.snap.duration }) {
                    let c = upperStore.get(us.id) ?? us.snap
                    if !us.snap.orient.isIdentity { u = Renderer.turn(u, us.snap.orient) }
                    if c.fix2020 { u = fixMatrix2020(u) }
                    u = applyColor(u, c.color, auto: c.autoSpace, out: store.outSpace, toneMap: store.toneMap, wheelScale: store.wheelScale, wheelShape: (store.wheelRange, store.wheelMid), luts: c.luts)
                    u = conform(u)   // a different-size video placed in the frame (Fit / Fill)
                    u = u.cropped(to: extent)
                    if let x0 = upperXf.get(us.id), !x0.isIdentity {
                        let x = x0.at(t - us.snap.offset)
                        u = Renderer.applyXf(u, x, extent)
                    }
                    img = u.cropped(to: extent).composited(over: img)
                }
                for o in overlaySnaps where o.o.lane == lane {
                    img = OverlayRender.draw(o, t: t, frame: extent, over: img)
                }
                // adjustment layer on this track: grades the finished picture of everything below it; opacity mixes it in
                for a in adjNow where a.o.lane == lane {
                    let g = applyColor(img, a.o.adjust!, auto: store.outSpace, out: store.outSpace, toneMap: store.toneMap, wheelScale: store.wheelScale,
                                       wheelShape: (store.wheelRange, store.wheelMid), luts: a.luts).cropped(to: extent)
                    let mix = KF.at(a.o.opacity, t - a.o.offset, [1])[0]
                    img = mix >= 0.999 ? g : g.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, mix))]).composited(over: img)
                }
            }
            for lt in titles {
                let local = t - lt.at
                guard local >= 0 && local <= lt.duration else { continue }
                let fade = 0.35
                let a = max(0, min(1, min(local / fade, (lt.duration - local) / fade)))
                let ease = 1 - pow(1 - min(1, local / 0.5), 3)
                let dx = -90.0 * (1 - ease)
                let o = lt.image
                    .transformed(by: CGAffineTransform(translationX: dx, y: 0))
                    .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)])
                img = o.composited(over: img)
            }
            return img.cropped(to: extent)
        }
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = CutgenieCompositor.self
        vc.instructions = [CutgenieInstruction(range: CMTimeRange(start: .zero, duration: comp.duration), main: vTrack.trackID, lanes: upperTracks,
                                              size: CGSize(width: W, height: H), context: ciContext ?? CIContext(), render: renderFn)]
        vc.renderSize = CGSize(width: W, height: H)
        // exact frame length: 23.98 = 1001/24000, 29.97 = 1001/30000, 59.94 = 1001/60000
        let fpsX = p.settings.fps
        vc.frameDuration = [(23.976, CMTime(value: 1001, timescale: 24000)), (29.97, CMTime(value: 1001, timescale: 30000)), (59.94, CMTime(value: 1001, timescale: 60000))]
            .first { abs(fpsX - $0.0) < 0.01 }?.1 ?? CMTime(value: 1000, timescale: CMTimeScale((fpsX * 1000).rounded()))
        // frames always on the project's own frame grid (Final Cut does the same): following the camera files gave extra
        // short frames and doubled frame times at every cut with phone footage (variable frame rate), seen as a blink
        vc.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        // Output as Rec.709 (SDR). How HLG sources are converted is NOT yet verified (see PLAN.md 6.4).
        // If the project has HLG footage, declare the whole composition HLG so AVFoundation converts every clip into HLG the same
        // way everywhere (player, still, export). Left undeclared, it decides per time range, so a still taken inside an SDR clip
        // saw different numbers than the export.
        let declared = ProcessInfo.processInfo.environment["CUTGENIE_CS"] ?? (fix2020.values.contains(true) ? "hlg" : "none")
        switch declared {
        case "hlg":
            vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
            vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_2100_HLG
            vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
        case "none": break
        default:
            vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        }
        return Built(composition: comp, videoComposition: vc, audioMix: audioMix, store: store, upperStore: upperStore, audioStore: audioStore, overlayStore: overlayStore, upperXf: upperXf, adjStore: adjStore, laneAudio: laneAudio, fix2020: fix2020, duration: comp.duration.seconds)
    }

    // AVFoundation hands us Rec.2020 camera frames decoded with the Rec.709 YCbCr matrix. Undo that in the encoded
    // (non-linear) domain: re-encode to Y'CbCr with 709 coefficients, decode with 2020 coefficients. Exact 3x3.
    static let matrix2020Fix: [Double] = {
        func dec(_ kr: Double, _ kb: Double) -> [[Double]] {      // Y'CbCr(Cb,Cr in +-0.5) -> R'G'B'
            let kg = 1 - kr - kb
            return [[1, 0, 2 * (1 - kr)],
                    [1, -2 * (1 - kb) * kb / kg, -2 * (1 - kr) * kr / kg],
                    [1, 2 * (1 - kb), 0]]
        }
        func enc(_ kr: Double, _ kb: Double) -> [[Double]] {      // R'G'B' -> Y'CbCr
            let kg = 1 - kr - kb
            return [[kr, kg, kb],
                    [-kr / (2 * (1 - kb)), -kg / (2 * (1 - kb)), 0.5],
                    [0.5, -kg / (2 * (1 - kr)), -kb / (2 * (1 - kr))]]
        }
        let d = dec(0.2627, 0.0593), e = enc(0.2126, 0.0722)
        var m = [Double](repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 { m[i * 3 + j] = (0..<3).reduce(0.0) { $0 + d[i][$1] * e[$1][j] } } }
        return m
    }()
    static func fixMatrix2020(_ img: CIImage) -> CIImage {
        let m = matrix2020Fix
        return img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: m[0], y: m[1], z: m[2], w: 0),
            "inputGVector": CIVector(x: m[3], y: m[4], z: m[5], w: 0),
            "inputBVector": CIVector(x: m[6], y: m[7], z: m[8], w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    }

    static func loadLUTs(_ color: ColorParams, project p: Project, base: URL?, clip: String) throws -> [LoadedLUT] {
        var loaded: [LoadedLUT] = []
        for slot in ["input", "creative", "output"] {
            for l in (color.luts ?? []) where l.slot == slot && l.enabled {
                guard let url = p.resolve(l.asset, base: base) else { throw RenderError.message("clip \(clip): LUT asset \(l.asset) not found") }
                guard MediaCache.stamp(url) != nil else { throw RenderError.message("LUT file not found: \(url.path)") }
                let lut = try MediaCache.lut(url)
                guard lut.domainMin == [0, 0, 0], lut.domainMax == [1, 1, 1] else {
                    throw RenderError.message("\(url.lastPathComponent): LUTs with a DOMAIN other than 0..1 are not supported yet")
                }
                loaded.append(LoadedLUT(slot: slot, lut: lut, intensity: l.intensity, inSpace: l.inputSpace, outSpace: l.outputSpace))
            }
        }
        return loaded
    }

    static let lumaRec709 = [0.2126, 0.7152, 0.0722]
    static let lumaRec2020 = [0.2627, 0.6780, 0.0593]

    // Core Image Metal kernel compiled by scripts/build_app.sh into the app bundle.
    static let wheelKernel: CIColorKernel? = {
        guard let url = Bundle.main.url(forResource: "ColorKernels", withExtension: "metallib"),
              let d = try? Data(contentsOf: url) else { return nil }
        return try? CIColorKernel(functionName: "cutgenieWheels", fromMetalLibraryData: d)
    }()

    static let convertKernel: CIColorKernel? = {
        guard let url = Bundle.main.url(forResource: "ColorKernels", withExtension: "metallib"),
              let d = try? Data(contentsOf: url) else { return nil }
        return try? CIColorKernel(functionName: "cutgenieConvert", fromMetalLibraryData: d)
    }()

    /// Converts the picture from one colour space to another (transfer function + primaries; HDR->SDR tone map when needed).
    static func convert(_ img: CIImage, from: String, to: String, toneMap: String) -> CIImage {
        guard from != to, let k = convertKernel else { return img }
        let m = ColorSpaces.matrix(from: from, to: to)
        let hdrToSdr = ColorSpaces.isHDR(from) && !ColorSpaces.isHDR(to)
        func row(_ i: Int) -> CIVector { CIVector(x: m[i * 3], y: m[i * 3 + 1], z: m[i * 3 + 2]) }
        let tf = CIVector(x: Double(ColorSpaces.tf(from)), y: Double(ColorSpaces.tf(to)), z: toneMap == "clip" ? 0 : 1, w: hdrToSdr ? 1 : 0)
        return k.apply(extent: img.extent, arguments: [img, tf, row(0), row(1), row(2)]) ?? img
    }

    /// Testing aid: converts one RGB value (0...1) between colour spaces and returns the result.
    public static func probeConvert(from: String, to: String, rgb: [Double], toneMap: String) -> [Double] {
        var f4 = [Float](repeating: 0, count: 4 * 16)
        for i in 0..<16 { f4[i * 4] = Float(rgb[0]); f4[i * 4 + 1] = Float(rgb[1]); f4[i * 4 + 2] = Float(rgb[2]); f4[i * 4 + 3] = 1 }
        let px = CIImage(bitmapData: Data(bytes: f4, count: f4.count * 4), bytesPerRow: 64, size: CGSize(width: 4, height: 4), format: .RGBAf, colorSpace: nil)
        let out = convert(px, from: from, to: to, toneMap: toneMap)
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        var f = [Float](repeating: 0, count: 4)
        ctx.render(out, toBitmap: &f, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return f.prefix(3).map { Double($0) }
    }

    static func hsvToRGB(_ hDeg: Double) -> [Double] {       // pure hue, full saturation and value
        let h = (hDeg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        switch Int(h) {
        case 0: return [1, x, 0]
        case 1: return [x, 1, 0]
        case 2: return [0, 1, x]
        case 3: return [0, x, 1]
        case 4: return [x, 0, 1]
        default: return [1, 0, x]
        }
    }

    // Colour offset for a puck at (hue, amount). Amount 1 pushes the encoded signal by 0.25 at full strength.
    // (This scale is Cutgenie's own, not Final Cut's.) With Preserve Luma the offset is made luma-neutral.
    static func wheelOffset(_ w: WheelParams, luma: [Double], preserve: Bool) -> [Double] {
        if let o = w.rgb, o.count == 3 {                       // direct RGB offset
            var d = o
            if preserve { let y = zip(d, luma).reduce(0) { $0 + $1.0 * $1.1 }; d = d.map { $0 - y } }
            return d
        }
        guard w.amount != 0 else { return [0, 0, 0] }
        let c = hsvToRGB(w.hue)
        let m = (c[0] + c[1] + c[2]) / 3
        var d = c.map { $0 - m }
        let mx = max(d.map { abs($0) }.max() ?? 1, 1e-9)
        d = d.map { $0 / mx }
        if preserve { let y = zip(d, luma).reduce(0) { $0 + $1.0 * $1.1 }; d = d.map { $0 - y } }
        return d.map { $0 * w.amount * 0.25 }
    }

    static func applyColor(_ input: CIImage, _ c: ColorParams, auto: String, out: String, toneMap: String, wheelScale: Double, wheelShape: (Double, Double), luts: [LoadedLUT]) -> CIImage {
        var img = input
        var cur = c.sourceSpace ?? auto                       // the colour space the picture is in at this point of the chain

        func applyLUTs(_ list: [LoadedLUT]) {
            for l in list {
                if let inS = l.inSpace, inS != cur { img = convert(img, from: cur, to: inS, toneMap: toneMap); cur = inS }
                let before = img
                guard let f = CIFilter(name: "CIColorCube") else { continue }
                f.setValue(l.lut.size, forKey: "inputCubeDimension")
                f.setValue(l.lut.data, forKey: "inputCubeData")
                f.setValue(before, forKey: kCIInputImageKey)
                guard var o = f.outputImage else { continue }
                if l.intensity < 1 {
                    o = before.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": o, "inputTime": max(0, l.intensity)])
                }
                img = o
                if let os = l.outSpace { cur = os }            // the LUT's output is declared to be in this space
            }
        }

        // 1. Input LUT (e.g. camera log/HLG -> Rec.709), before any grading
        applyLUTs(luts.filter { $0.slot == "input" })
        let luma = (ColorSpaces.isHDR(cur) || cur == "slog3") ? lumaRec2020 : lumaRec709

        // 2. basic controls
        if c.temperature != 6500 || (c.tint ?? 0) != 0 {
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: c.temperature, y: c.tint ?? 0),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)])
        }
        if c.exposure != 0 { img = img.applyingFilter("CIExposureAdjust", parameters: ["inputEV": c.exposure]) }
        if c.contrast != 1 || c.saturation != 1 {
            img = img.applyingFilter("CIColorControls", parameters: [
                "inputContrast": c.contrast, "inputSaturation": c.saturation, "inputBrightness": 0])
        }
        if let h = c.hue, h != 0 { img = img.applyingFilter("CIHueAdjust", parameters: ["inputAngle": h * .pi / 180]) }

        // 3. colour wheels
        if let w = c.wheels, let k = wheelKernel {
            let all = [w.global, w.shadows, w.midtones, w.highlights]
            let neutral = all.allSatisfy { $0.amount == 0 && $0.saturation == 1 && $0.brightness == 0 && ($0.rgb ?? [0, 0, 0]).allSatisfy { $0 == 0 } }
            if !neutral {
                func v(_ a: [Double]) -> CIVector { CIVector(x: a[0], y: a[1], z: a[2]) }
                let off = all.map { wheelOffset($0, luma: luma, preserve: w.preserveLuma).map { $0 * wheelScale } }
                let args: [Any] = [img, v(luma), v(off[0]), v(off[1]), v(off[2]), v(off[3]),
                                   CIVector(x: w.global.saturation, y: w.shadows.saturation, z: w.midtones.saturation, w: w.highlights.saturation),
                                   CIVector(x: w.global.brightness * wheelScale, y: w.shadows.brightness * wheelScale, z: w.midtones.brightness * wheelScale, w: w.highlights.brightness * wheelScale),
                                   CIVector(x: wheelShape.0, y: wheelShape.1)]
                if let o = k.apply(extent: img.extent, arguments: args) {
                    if let m = w.mix, m < 1 {
                        img = img.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": o, "inputTime": max(0, m)])
                    } else { img = o }
                }
            }
        }

        // 4. Creative and Output LUTs
        applyLUTs(luts.filter { $0.slot != "input" })
        return convert(img, from: cur, to: out, toneMap: toneMap)   // finally into the project's output space
    }

    public static func writePNG(_ pb: CVPixelBuffer, to url: URL) throws {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA, let base = CVPixelBufferGetBaseAddress(pb) else {
            throw RenderError.message("unexpected frame format")
        }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), rb = CVPixelBufferGetBytesPerRow(pb)
        let cs = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()   // a label only; the numbers are not converted
        guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: rb, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let cg = ctx.makeImage() else { throw RenderError.message("cannot make image") }
        guard let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw RenderError.message("PNG encode failed") }
        try png.write(to: url)
    }

    /// One frame through exactly the same reader pipeline as export (so a still is what the export contains).
    public static func renderFrame(_ b: Built, at time: Double, to url: URL) async throws {
        let reader = try AVAssetReader(asset: b.composition)
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: b.composition.tracks(withMediaType: .video), videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out.videoComposition = b.videoComposition
        guard reader.canAdd(out) else { throw RenderError.message("cannot read video") }
        reader.add(out)
        let t = min(max(0, time), max(0, b.duration - 0.05))
        // Start a little before t so AVFoundation sets up its colour conversion the same way as in a continuous read (export),
        // then keep the frame at t.
        let lead = min(t, 2.0)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: t - lead, preferredTimescale: 6000), duration: CMTime(seconds: min(lead + 0.25, max(0.05, b.duration - (t - lead))), preferredTimescale: 6000))
        guard reader.startReading() else { throw RenderError.message("read failed: \(reader.error?.localizedDescription ?? "?")") }
        var chosen: CVPixelBuffer?
        while let sb = out.copyNextSampleBuffer() {
            guard let b = CMSampleBufferGetImageBuffer(sb) else { continue }
            chosen = b
            if CMSampleBufferGetPresentationTimeStamp(sb).seconds >= t - 0.0005 { break }
        }
        guard let pb = chosen else { throw RenderError.message("no picture at \(t) s (gap on the timeline?)") }
        try writePNG(pb, to: url)
        reader.cancelReading()
    }

    public static func export(_ b: Built, to url: URL, codec: String, overwrite: Bool, bitrateMbps: Double = 24) async throws {
        var o = ExportOptions(); o.codec = codec; o.bitrateMbps = bitrateMbps
        try await export(b, to: url, options: o, overwrite: overwrite)
    }

    /// writes the timeline to a file. progress: 0...1 (called often, from a background queue); cancelled: checked while writing
    public static func export(_ b: Built, to url: URL, options o: ExportOptions, overwrite: Bool,
                              progress: (@Sendable (Double) -> Void)? = nil, cancelled: (@Sendable () -> Bool)? = nil) async throws {
        if FileManager.default.fileExists(atPath: url.path) {
            guard overwrite else { throw RenderError.message("output exists: \(url.path) (pass overwrite=true to replace it)") }
            try FileManager.default.removeItem(at: url)
        }
        let audioOnly = o.container == "m4a" || o.container == "wav"
        let size = b.videoComposition.renderSize
        let reader = try AVAssetReader(asset: b.composition)
        let total = b.composition.duration.seconds
        let from = max(0, o.from ?? 0), to = min(total, o.to ?? total)
        guard to > from else { throw RenderError.message("nothing to export (the range is empty)") }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 6000), end: CMTime(seconds: to, preferredTimescale: 6000))
        let vTracks = b.composition.tracks(withMediaType: .video)
        let aTracks = b.composition.tracks(withMediaType: .audio)
        var vOut: AVAssetReaderVideoCompositionOutput?
        if !audioOnly {
            let v = AVAssetReaderVideoCompositionOutput(videoTracks: vTracks, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            v.videoComposition = b.videoComposition
            guard reader.canAdd(v) else { throw RenderError.message("cannot read video") }
            reader.add(v); vOut = v
        }
        var aOut: AVAssetReaderAudioMixOutput?   // (pitch kept for speed changes: .spectral)
        if !aTracks.isEmpty {
            let a = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false])
            a.audioMix = b.audioMix
            a.audioTimePitchAlgorithm = .spectral      // speed-changed clips keep their natural pitch
            if reader.canAdd(a) { reader.add(a); aOut = a }
        }
        if audioOnly && aOut == nil { throw RenderError.message("the timeline has no sound to export") }
        let fileType: AVFileType = ["mov": .mov, "m4v": .m4v, "m4a": .m4a, "wav": .wav][o.container] ?? .mp4
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        var vIn: AVAssetWriterInput?
        if let _ = vOut {
            let ow = o.width ?? Int(size.width), oh = o.height ?? Int(size.height)
            let codecType: AVVideoCodecType = ["hevc": .hevc, "prores422": .proRes422, "prores422hq": .proRes422HQ,
                                               "prores422lt": .proRes422LT, "prores4444": .proRes4444][o.codec.lowercased()] ?? .h264
            var vs: [String: Any] = [AVVideoCodecKey: codecType, AVVideoWidthKey: ow, AVVideoHeightKey: oh,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]]
            if ow != Int(size.width) || oh != Int(size.height) { vs[AVVideoScalingModeKey] = AVVideoScalingModeResizeAspect }
            if codecType == .h264 || codecType == .hevc {
                var cp: [String: Any] = [:]
                if let q = o.quality {
                    // quality-based: simple shots (a face on a plain wall) get few bits, busy B-roll gets more
                    cp[AVVideoQualityKey] = q
                    cp[AVVideoExpectedSourceFrameRateKey] = Int((b.videoComposition.frameDuration.seconds > 0 ? 1 / b.videoComposition.frameDuration.seconds : 30).rounded())
                } else {
                    cp[AVVideoAverageBitRateKey] = Int(o.bitrateMbps * 1_000_000)
                }
                cp[AVVideoMaxKeyFrameIntervalDurationKey] = 2
                if codecType == .h264 { cp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
                vs[AVVideoCompressionPropertiesKey] = cp
            }
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: vs)
            i.expectsMediaDataInRealTime = false
            guard writer.canAdd(i) else { throw RenderError.message("\(o.codec) cannot go in a .\(o.container) file") }
            writer.add(i); vIn = i
        }
        var aIn: AVAssetWriterInput?
        if aOut != nil {
            let pcm = o.audio == "pcm" || o.container == "wav"
            let settings: [String: Any] = pcm
                ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24,
                   AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
                : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: o.audioKbps * 1000]
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            i.expectsMediaDataInRealTime = false
            guard writer.canAdd(i) else { throw RenderError.message("this sound format cannot go in a .\(o.container) file") }
            writer.add(i); aIn = i
        }
        guard reader.startReading() else { throw RenderError.message("read failed: \(reader.error?.localizedDescription ?? "?")") }
        guard writer.startWriting() else { throw RenderError.message("write failed: \(writer.error?.localizedDescription ?? "?")") }
        writer.startSession(atSourceTime: CMTime(seconds: from, preferredTimescale: 6000))
        let span = to - from
        let stop = Stop()
        let dbg = ProcessInfo.processInfo.environment["CUTGENIE_AUDDBG"] != nil
        nonisolated(unsafe) var lastT = -1.0

        func pump(_ input: AVAssetWriterInput, _ next: @escaping () -> CMSampleBuffer?, tag709: Bool, reports: Bool) async {
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                let q = DispatchQueue(label: "cutgenie.export.\(input.mediaType.rawValue)")
                input.requestMediaDataWhenReady(on: q) {
                    while input.isReadyForMoreMediaData {
                        if stop.flag || cancelled?() == true { stop.flag = true; input.markAsFinished(); k.resume(); return }
                        guard let sb = next() else { input.markAsFinished(); k.resume(); return }
                        if dbg, input.mediaType == .audio { let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds; if abs(t - lastT) > 1.5 || Int(t) % 10 == 0 && Int(lastT) % 10 != 0 { FileHandle.standardError.write("AUD \(t) n=\(CMSampleBufferGetNumSamples(sb))\n".data(using: .utf8)!) }; lastT = t }
                        if reports { progress?(min(1, max(0, (CMSampleBufferGetPresentationTimeStamp(sb).seconds - from) / span))) }
                        if tag709, let pb = CMSampleBufferGetImageBuffer(sb) {
                            // the pixels are already final Rec.709 numbers; say so, so the encoder does not convert them again
                            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                        }
                        if !input.append(sb) { input.markAsFinished(); k.resume(); return }
                    }
                }
            }
        }
        if let vIn, let vOut {
            async let v: Void = pump(vIn, { vOut.copyNextSampleBuffer() }, tag709: true, reports: true)
            if let aIn, let aOut { async let a: Void = pump(aIn, { aOut.copyNextSampleBuffer() }, tag709: false, reports: false); await a }
            await v
        } else if let aIn, let aOut {
            await pump(aIn, { aOut.copyNextSampleBuffer() }, tag709: false, reports: true)
        }
        if stop.flag {
            reader.cancelReading(); writer.cancelWriting(); try? FileManager.default.removeItem(at: url)
            throw RenderError.message("export cancelled")
        }
        if reader.status == .failed { writer.cancelWriting(); throw RenderError.message("export failed (read): \(reader.error?.localizedDescription ?? "?")") }
        await writer.finishWriting()
        if writer.status != .completed { throw RenderError.message("export failed: \(writer.error?.localizedDescription ?? "unknown")") }
        progress?(1)
    }
}

final class Stop: @unchecked Sendable { var flag = false }

/// what an export writes: file type, picture codec, size, quality, sound
public struct ExportOptions: Equatable, Sendable {
    public var container = "mp4"        // mp4 | mov | m4v | m4a (sound only) | wav (sound only)
    public var codec = "h264"           // h264 | hevc | prores422lt | prores422 | prores422hq | prores4444
    public var bitrateMbps = 24.0       // h264 / hevc
    public var quality: Double?         // h264 / hevc: constant quality 0...1 instead of a fixed bitrate (bitrateMbps is then the ceiling)
    public var width: Int?              // nil = the project's size
    public var height: Int?
    public var audio = "aac"            // aac | pcm
    public var audioKbps = 256
    public var from: Double?            // part of the timeline (seconds); nil = from the start / to the end
    public var to: Double?
    public init() {}
}

/// picture-in-picture settings of V2+ clips, read every frame (so dragging a slider updates live, no rebuild)
final class UpperXfStore: @unchecked Sendable {
    private let lock = NSLock(); private var d: [String: ClipXf]
    init(_ d: [String: ClipXf]) { self.d = d }
    func get(_ id: String) -> ClipXf? { lock.lock(); defer { lock.unlock() }; return d[id] }
    func set(_ id: String, _ x: ClipXf?) { lock.lock(); d[id] = x; lock.unlock() }
}
