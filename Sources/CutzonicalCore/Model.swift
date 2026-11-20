import Foundation

// Prototype project model. Times are plain seconds here for brevity;
// the real model uses rational time (see PLAN.md section 3.5).

public struct Project: Codable, Equatable {
    public var version = 1
    public var name = "Untitled"
    public var settings = Settings()
    public var assets: [Asset] = []
    public var clips: [Clip] = []
    public var titles: [LowerThird] = []
    public var audioChain: AudioChain?
    public var overlays: [Overlay]?
    public var markers: [Marker]?
    public var audioClips: [AudioClip]?      // extra audio tracks A2, A3, ... (music, sound effects)
    public var audioLanes: Int?              // how many extra audio tracks are shown (even when empty)
    public var gfxLanes: Int?                // how many graphics tracks are shown (even when empty)
    public var trackHeights: [String: Double]?   // track name -> height in points (you drag the line under the track name)
    public var groups: [ClipGroup]?          // clips tied together to move as one (any tracks); a tag only, the clips stay as they are
    public var hiddenTracks: [String]?       // "V3" = video track hidden, "A2" = audio track muted (playback and export)
    public var unsynced: [String]?           // tracks with sync lock OFF ("V5", "A2"...): V1 ripple edits leave them alone
    public var upperClips: [Clip]?           // video clips on V2, V3... (lane 1 = V2); drawn over the main storyline
    public var trackAudio: [String: AudioChain]?   // effects on a whole audio track ("A2", "A3"...); A1's are audioChain
    public init() {}
}

public struct Settings: Codable, Equatable {
    public var width = 1920
    public var height = 1080
    public var fps = 24.0
    public var colorSpace = "rec709"
    // "managed": the system converts every source into one working space (and tone-maps HDR). "raw": pixel values are
    // passed through untouched (HLG stays HLG-encoded), so a LUT sees exactly what Final Cut's Custom LUT sees.
    public var colorPipeline: String? = nil
    public var wheelScale: Double?     // strength of the colour wheels relative to the raw slider numbers; nil = 0.32 (fitted to a Final Cut export)
    public var wheelRange: Double?     // tonal reach of the shadows/highlights wheels: low = far-reaching, high = extremes only; nil = 0.25 (fitted)
    public var wheelMid: Double?       // height of the midtones wheel's bell; nil = 0.8 (fitted)
    public var fit: String?            // clips whose size differs from the frame: "fit" (whole picture, bars; default), "fill" (crop to fill), "none" (actual size)
    public var hdrToSdr: String?       // how HDR (HLG/PQ) highlights are brought into an SDR output: "soft" (roll-off, default) or "clip"
    public init() {}
}

public struct Asset: Codable, Equatable {
    public var id: String
    public var path: String          // absolute, or relative to the project file
}

// Audio that comes from a different file than the picture (e.g. a separate mic recording synced to the camera clip).
// sourceIn is where in THAT file the clip's first audio sample is. Edits move it together with the picture.
public struct AudioSource: Codable, Equatable {
    public var asset: String
    public var sourceIn: Double
    public init(asset: String, sourceIn: Double) { self.asset = asset; self.sourceIn = sourceIn }
}

public struct Clip: Codable, Equatable {
    public var id: String
    public var asset: String
    public var audioSource: AudioSource?
    public var sourceIn: Double = 0
    public var duration: Double
    public var offset: Double = 0
    public var audio = AudioParams()
    public var color = ColorParams()
    public var lane: Int?             // only for clips on V2+ (in Project.upperClips)
    public var motion: [Keyframe]?    // V1: position keyframes (Final Cut units, t from the clip's start) - the camera slides aside for a side panel
    public var zoom: [Keyframe]?      // V1: scale keyframes (v = [1.08] = 8 % bigger, t from the clip's start, easing per keyframe)
    public var zoomAnchor: [Double]?  // V1: point that stays still while zooming (Final Cut units from the centre, y up); nil = centre
    public var xf: ClipXf?            // V2+ only: position / scale / rotation / opacity / crop (picture-in-picture)
    public var speed: Double?         // 2 = twice as fast (half as long on the timeline), 0.5 = slow motion; nil = normal
    public var disabled: Bool?        // switched off (V key): left out of the picture and sound, stays on the timeline
    public var audioDetached: Bool?   // sound moved to its own clip on an audio track (Final Cut "Detach Audio")
}

// Neutral defaults only. No baked "look" values.
public struct AudioParams: Codable, Equatable {
    public var gainDb: Double = 0
    public var keys: [VolKey]?      // volume keyframes (t = seconds from the clip's start); when present they set the level
    public var fadeIn: Double?      // seconds
    public var fadeOut: Double?
}

/// One volume keyframe: level in dB at a time inside the clip.
public struct VolKey: Codable, Equatable {
    public var t: Double
    public var db: Double
    public init(t: Double, db: Double) { self.t = t; self.db = db }
}

public enum Volume {
    /// level (dB) at time t inside a clip: the clip volume (gain) plus the keyframe shape (keyframes are relative to the clip
    /// volume, so turning the clip down lowers the whole keyframed line)
    public static func level(gain: Double, keys: [VolKey]?, at t: Double) -> Double {
        guard let k = keys, !k.isEmpty else { return gain }
        if t <= k[0].t { return gain + k[0].db }
        for i in 1..<k.count where t <= k[i].t {
            let a = k[i - 1], b = k[i], f = b.t > a.t ? (t - a.t) / (b.t - a.t) : 1
            return gain + a.db + (b.db - a.db) * f
        }
        return gain + k[k.count - 1].db
    }
    /// fade multiplier (0...1) at time t inside a clip of length d; smooth (equal-power) curve like Final Cut's default
    public static func fade(_ t: Double, duration d: Double, fadeIn: Double?, fadeOut: Double?) -> Double {
        var f = 1.0
        if let i = fadeIn, i > 0.001, t < i { f *= sin(max(0, t / i) * .pi / 2) }
        if let o = fadeOut, o > 0.001, t > d - o { f *= sin(max(0, (d - t) / o) * .pi / 2) }
        return f
    }
}

public struct ColorParams: Codable, Equatable {
    public var exposure: Double = 0       // EV, 0 = unchanged
    public var contrast: Double = 1       // 1 = unchanged
    public var saturation: Double = 1     // 1 = unchanged
    public var temperature: Double = 6500 // Kelvin, 6500 = unchanged
    public var tint: Double?              // Core Image scale, 0 = unchanged
    public var hue: Double?               // degrees, 0 = unchanged
    public var sourceSpace: String?       // colour space of the picture as the chain sees it; nil = Auto
    public var wheels: Wheels?            // colour wheels; nil = untouched
    public var luts: [LUTSlot]?           // applied in this order after the wheels: input, creative, output
    public init(luts: [LUTSlot]? = nil) { self.luts = luts }
}

// One colour wheel. hue/amount place the puck (angle in degrees, 0 = red, 120 = green, 240 = blue; amount 0 = centre).
public struct WheelParams: Codable, Equatable {
    public var hue: Double = 0
    public var amount: Double = 0
    public var saturation: Double = 1     // 1 = unchanged
    public var brightness: Double = 0     // 0 = unchanged; added to the encoded signal (1.0 = full range)
    public var rgb: [Double]?             // direct colour offset in encoded-signal units (0.01 = 1%); when set it replaces hue/amount
    public init() {}
}

public struct Wheels: Codable, Equatable {
    public var global = WheelParams()
    public var shadows = WheelParams()
    public var midtones = WheelParams()
    public var highlights = WheelParams()
    public var mix: Double?               // 0...1, blends the whole Color Wheels effect with the original; nil = 1
    public var preserveLuma = true        // colour offsets are made luma-neutral so the picture does not get lighter/darker
    public init() {}
}

// A 3D LUT in one of three places in the chain. intensity 0...1 mixes between before and after.
public struct LUTSlot: Codable, Equatable {
    public var slot: String               // "input" | "creative" | "output"
    public var asset: String              // project asset id of the .cube file
    public var intensity: Double = 1
    public var enabled: Bool = true
    public var inputSpace: String?        // colour space the LUT expects (the picture is converted to it first); nil = leave as is
    public var outputSpace: String?       // colour space the LUT produces; nil = same as its input
    public init(slot: String, asset: String, intensity: Double = 1, enabled: Bool = true, inputSpace: String? = nil, outputSpace: String? = nil) {
        self.slot = slot; self.asset = asset; self.intensity = intensity; self.enabled = enabled
        self.inputSpace = inputSpace; self.outputSpace = outputSpace
    }
}

public struct LowerThird: Codable, Equatable {
    public var id: String
    public var at: Double
    public var duration: Double
    public var tag: String
    public var title: String
    public var sub: String
    public var look = "a"   // look A "HUD scan" colours only, in the prototype
}

public extension Project {
    static func load(from url: URL) throws -> Project {
        try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
    }
    func save(to url: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: url, options: .atomic)     // a crash mid-save never leaves half a file
    }
    var totalDuration: Double { (clips + (upperClips ?? [])).map { $0.offset + $0.duration }.max() ?? 0 }
    /// what a layer draws: its picture file, or its text ("text:<key>")
    public func layerPath(_ o: Overlay, base: URL?) -> String? {
        if let t = o.text { return TextRender.key(t) }
        if let s = o.shape { return ShapeRender.key(s) }
        return resolve(o.asset, base: base)?.path
    }
    public func resolve(_ asset: String, base: URL?) -> URL? {
        guard let a = assets.first(where: { $0.id == asset }) else { return nil }
        if a.path.hasPrefix("/") { return URL(fileURLWithPath: a.path) }
        return (base ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).appendingPathComponent(a.path)
    }
}

// Colour spaces the chain understands: (transfer id for the shader, primaries as CIE xy of R, G, B and white).
public enum ColorSpaces {
    public static let all: [(id: String, name: String)] = [
        ("rec709", "Rec. 709"), ("srgb", "sRGB"), ("displayp3", "Display P3"),
        ("rec2020hlg", "Rec. 2020 HLG"), ("rec2020pq", "Rec. 2020 PQ"), ("slog3", "S-Log3 (S-Gamut3.Cine)")]
    static let d65 = (0.3127, 0.3290)
    static func tf(_ id: String) -> Int { ["rec709": 0, "srgb": 1, "displayp3": 1, "rec2020hlg": 2, "rec2020pq": 3, "slog3": 4][id] ?? 0 }
    public static func isHDR(_ id: String) -> Bool { id == "rec2020hlg" || id == "rec2020pq" }
    static func primaries(_ id: String) -> [(Double, Double)] {
        switch id {
        case "displayp3": return [(0.680, 0.320), (0.265, 0.690), (0.150, 0.060)]
        case "rec2020hlg", "rec2020pq": return [(0.708, 0.292), (0.170, 0.797), (0.131, 0.046)]
        case "slog3": return [(0.766, 0.275), (0.225, 0.800), (0.089, -0.087)]
        default: return [(0.640, 0.330), (0.300, 0.600), (0.150, 0.060)]
        }
    }
    static func inv3(_ m: [Double]) -> [Double] {
        let a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        return [(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
                (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
                (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]
    }
    static func mul3(_ a: [Double], _ b: [Double]) -> [Double] {
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 { r[i * 3 + j] = (0..<3).reduce(0.0) { $0 + a[i * 3 + $1] * b[$1 * 3 + j] } } }
        return r
    }
    /// linear RGB -> XYZ for a space
    static func toXYZ(_ id: String) -> [Double] {
        let p = primaries(id)
        func xyz(_ q: (Double, Double)) -> [Double] { [q.0 / q.1, 1, (1 - q.0 - q.1) / q.1] }
        let r = xyz(p[0]), g = xyz(p[1]), b = xyz(p[2]), w = xyz(d65)
        let m = [r[0], g[0], b[0], r[1], g[1], b[1], r[2], g[2], b[2]]
        let s = mul3(inv3(m), [w[0], 0, 0, w[1], 0, 0, w[2], 0, 0])   // column 0 holds the scale vector
        let sv = [s[0], s[3], s[6]]
        return [m[0] * sv[0], m[1] * sv[1], m[2] * sv[2], m[3] * sv[0], m[4] * sv[1], m[5] * sv[2], m[6] * sv[0], m[7] * sv[1], m[8] * sv[2]]
    }
    /// 3x3 (row-major) taking linear RGB of `from` to linear RGB of `to`
    public static func matrix(from: String, to: String) -> [Double] { mul3(inv3(toXYZ(to)), toXYZ(from)) }
}

// A marker on the timeline. If it sits on a clip it belongs to that clip and moves with it (Final Cut style).
public struct Marker: Codable, Equatable {
    public var id: String
    public var time: Double
    public var name: String = ""
    public var clip: String?
    public init(id: String, time: Double, name: String = "", clip: String? = nil) { self.id = id; self.time = time; self.name = name; self.clip = clip }
}

// A clip on an extra audio track (A2 and up). Independent of the main storyline: it does not ripple with it.
public struct AudioClip: Codable, Equatable {
    public var id: String
    public var asset: String
    public var name: String = ""
    public var lane: Int = 2
    public var offset: Double
    public var sourceIn: Double = 0
    public var duration: Double
    public var gainDb: Double = 0
    public var keys: [VolKey]?
    public var fadeIn: Double?
    public var fadeOut: Double?
    public var link: String?          // video clip on V2+ this sound belongs to (moves / trims with it)
    public var disabled: Bool?        // switched off (V key): silent, stays on the timeline
    public var syncWith: String?      // unlinked from this video clip: moves on its own, the timeline shows if it slips out of sync
}

extension Project {
    /// Layers that Final Cut keeps under the main storyline (background stills, grids) become the lowest video tracks above V1
    /// (V2, V3, ...), and everything that was above moves up by as many tracks. They only ever fill gaps in the camera picture,
    /// so the frame looks the same; the timeline just has plain video tracks.
    public mutating func liftBackgroundLanes() {
        guard var ov = overlays else { return }
        // a timeline whose V1 clips slide aside (docked panels) needs its backgrounds under V1, where Final Cut put them
        if clips.contains(where: { !($0.motion ?? []).isEmpty }) { return }
        let neg = Set(ov.map { $0.lane }.filter { $0 < 0 }).sorted()     // -3 (lowest) ... -1
        guard !neg.isEmpty else { return }
        let k = neg.count
        var map: [Int: Int] = [:]
        for (i, l) in neg.enumerated() { map[l] = i + 1 }
        for i in ov.indices { ov[i].lane = ov[i].lane < 0 ? map[ov[i].lane]! : ov[i].lane + k }
        overlays = ov
        if var up = upperClips { for i in up.indices { up[i].lane = (up[i].lane ?? 1) + k }; upperClips = up }
        gfxLanes = (gfxLanes ?? 0) + k
    }
}

extension Clip {
    /// playback speed (1 = normal). One second on the timeline uses `sp` seconds of the media.
    public var sp: Double { speed ?? 1 }
}

/// a set of clips / sound / graphics that select and move together (Premiere "Group")
public struct ClipGroup: Codable, Equatable {
    public var id: String
    public var name: String
    public var color: Int
    public var members: [String]
}
