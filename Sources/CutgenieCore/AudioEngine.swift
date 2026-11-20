import Foundation
import AVFoundation
import MediaToolbox

// Live, thread-safe holder of the chain; the audio thread reads a copy each buffer.
public final class AudioStore: @unchecked Sendable {
    private let lock = NSLock()
    private var chain: AudioChain
    private var version = 0
    init(_ c: AudioChain) { chain = c }
    public var meters = true      // false: a track's own effects (A2...): leaves the level meter to the main sound
    public func set(_ c: AudioChain) { lock.lock(); chain = c; version += 1; lock.unlock() }
    func get() -> (AudioChain, Int) { lock.lock(); defer { lock.unlock() }; return (chain, version) }
    /// A1 clip volume (gain + keyframes + fades + mute), applied by the audio processor itself (so it is exact in playback,
    /// changes live without touching the player, and the meter shows the real level)
    struct VolSeg { var offset: Double; var duration: Double; var gain: Double; var keys: [VolKey]?; var fadeIn: Double?; var fadeOut: Double? }
    private var segs: [VolSeg] = []
    func setVolume(_ s: [VolSeg]) { lock.lock(); segs = s.sorted { $0.offset < $1.offset }; lock.unlock() }
    func volumeSegs() -> [VolSeg] { lock.lock(); defer { lock.unlock() }; return segs }
    /// linear gain at composition time t
    static func gain(_ segs: [VolSeg], _ t: Double) -> Float {
        var lo = 0, hi = segs.count - 1, hit: VolSeg?
        while lo <= hi { let m = (lo + hi) / 2; let s = segs[m]
            if t < s.offset { hi = m - 1 } else if t >= s.offset + s.duration { lo = m + 1 } else { hit = s; break } }
        guard let s = hit else { return 1 }
        let lt = t - s.offset, db = Volume.level(gain: s.gain, keys: s.keys, at: lt)
        return db <= -95 ? 0 : Float(pow(10, db / 20) * Volume.fade(lt, duration: s.duration, fadeIn: s.fadeIn, fadeOut: s.fadeOut))
    }
}

// RBJ biquad
public struct BiquadCoef { var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0 }
public enum DSP {
    public static func coef(_ b: EQBand, fs: Double) -> BiquadCoef {
        let f = min(max(b.freq, 10), fs * 0.49), q = max(b.q, 0.05)
        let w0 = 2 * Double.pi * f / fs, c = cos(w0), s = sin(w0), al = s / (2 * q), A = pow(10, b.gainDb / 40)
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch b.type {
        case "lowshelf":
            let r = 2 * A.squareRoot() * al
            b0 = A * ((A + 1) - (A - 1) * c + r); b1 = 2 * A * ((A - 1) - (A + 1) * c); b2 = A * ((A + 1) - (A - 1) * c - r)
            a0 = (A + 1) + (A - 1) * c + r; a1 = -2 * ((A - 1) + (A + 1) * c); a2 = (A + 1) + (A - 1) * c - r
        case "highshelf":
            let r = 2 * A.squareRoot() * al
            b0 = A * ((A + 1) + (A - 1) * c + r); b1 = -2 * A * ((A - 1) + (A + 1) * c); b2 = A * ((A + 1) + (A - 1) * c - r)
            a0 = (A + 1) - (A - 1) * c + r; a1 = 2 * ((A - 1) - (A + 1) * c); a2 = (A + 1) - (A - 1) * c - r
        case "highpass": b0 = (1 + c) / 2; b1 = -(1 + c); b2 = (1 + c) / 2; a0 = 1 + al; a1 = -2 * c; a2 = 1 - al
        case "lowpass": b0 = (1 - c) / 2; b1 = 1 - c; b2 = (1 - c) / 2; a0 = 1 + al; a1 = -2 * c; a2 = 1 - al
        case "notch": b0 = 1; b1 = -2 * c; b2 = 1; a0 = 1 + al; a1 = -2 * c; a2 = 1 - al
        default: b0 = 1 + al * A; b1 = -2 * c; b2 = 1 - al * A; a0 = 1 + al / A; a1 = -2 * c; a2 = 1 - al / A
        }
        return BiquadCoef(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
    /// magnitude in dB of the whole EQ at frequency f (for the graph)
    public static func responseDb(_ bands: [EQBand], f: Double, fs: Double = 48000) -> Double {
        var db = 0.0
        let w = 2 * Double.pi * f / fs
        for b in bands where b.enabled {
            let k = coef(b, fs: fs)
            // H = (b0 + b1 z^-1 + b2 z^-2)/(1 + a1 z^-1 + a2 z^-2), z = e^{jw}
            let nr = k.b0 + k.b1 * cos(w) + k.b2 * cos(2 * w), ni = -(k.b1 * sin(w) + k.b2 * sin(2 * w))
            let dr = 1 + k.a1 * cos(w) + k.a2 * cos(2 * w), di = -(k.a1 * sin(w) + k.a2 * sin(2 * w))
            db += 10 * log10(max((nr * nr + ni * ni) / max(dr * dr + di * di, 1e-30), 1e-30))
        }
        return db
    }
}

public enum AudioDebug { nonisolated(unsafe) public static var calls = 0, frames = 0, peakIn: Float = 0, peakOut: Float = 0, fmt = "", resets = 0, overs = 0, meter: Float = 0,
        sumSq = 0.0, kSumSq = 0.0, count = 0 }   // meter accumulators (read and cleared by the UI ~20x per second)

final class AudioProcessor {
    let store: AudioStore
    var fs = 48000.0
    var chain = AudioChain(); var version = -1
    var coefs: [BiquadCoef] = []
    var z1: [[Double]] = [], z2: [[Double]] = []        // [band][channel]
    var gateEnv = 0.0, gateGainDb = 0.0, compGR = 0.0, limGain = 1.0
    var delay: [[Float]] = [], dpos = 0, look = 0
    var peakWin: [Float] = []; var pwPos = 0
    var kz = [[Double]](); var kc: (BiquadCoef, BiquadCoef)?
    static func kWeighting(_ fs: Double) -> (BiquadCoef, BiquadCoef) {     // ITU-R BS.1770 pre-filter + RLB high-pass at any sample rate
        var b1 = EQBand(); b1.type = "highshelf"; b1.freq = 1681.974450955533; b1.gainDb = 3.999843853973347; b1.q = 0.7071752369554196
        var b2 = EQBand(); b2.type = "highpass"; b2.freq = 38.13547087602444; b2.q = 0.5003270373238773
        return (DSP.coef(b1, fs: fs), DSP.coef(b2, fs: fs))
    }
    init(_ s: AudioStore) { store = s }

    func update(channels: Int) {
        let (c, v) = store.get()
        guard v != version || z1.count != c.eq.count || (z1.first?.count ?? channels) != channels else { return }
        let old = chain; chain = c; version = v
        coefs = c.eq.map { b in let k = DSP.coef(b, fs: fs); return [k.b0, k.b1, k.b2, k.a1, k.a2].allSatisfy { $0.isFinite } ? k : BiquadCoef() }
        if z1.count != c.eq.count || old.eq.map({ $0.type }) != c.eq.map({ $0.type }) || (z1.first?.count ?? 0) != channels {
            z1 = Array(repeating: Array(repeating: 0, count: channels), count: c.eq.count); z2 = z1
        }
        let newLook = c.limiter.enabled ? max(0, Int(c.limiter.lookaheadMs / 1000 * fs)) : 0
        if newLook != look || delay.count != channels {
            look = newLook
            delay = Array(repeating: Array(repeating: 0, count: max(look, 1)), count: channels); dpos = 0
            peakWin = Array(repeating: 0, count: max(look, 1)); pwPos = 0
        }
    }

    func process(_ abl: UnsafeMutablePointer<AudioBufferList>, frames: Int, start: Double? = nil) {
        let bufs = UnsafeMutableAudioBufferListPointer(abl)
        // collect channel pointers (works for interleaved and non-interleaved float32)
        var ch: [(UnsafeMutablePointer<Float>, Int)] = []   // pointer, stride
        for b in bufs {
            guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let n = Int(b.mNumberChannels)
            for k in 0..<n { ch.append((d + k, n)) }
        }
        let C = ch.count
        let meters = store.meters
        if meters {
            AudioDebug.calls += 1; AudioDebug.frames += frames
            for (p, st) in ch { for i in 0..<frames { AudioDebug.peakIn = max(AudioDebug.peakIn, abs(p[i * st])) } }
        }
        defer { if meters { for (p, st) in ch { for i in 0..<frames { let a = abs(p[i * st]); AudioDebug.peakOut = max(AudioDebug.peakOut, a); AudioDebug.meter = max(AudioDebug.meter, a) } } } }
        guard C > 0 else { return }
        // clip volume first (gain / keyframes / fades), smoothly per 32 samples, then the effect chain
        if let t0 = start, t0.isFinite {
            let segs = store.volumeSegs()
            if !segs.isEmpty {
                var i = 0
                var g0 = AudioStore.gain(segs, t0)
                while i < frames {
                    let n = min(32, frames - i)
                    let g1 = AudioStore.gain(segs, t0 + Double(i + n) / fs)
                    if g0 != 1 || g1 != 1 {
                        for j in 0..<n { let g = g0 + (g1 - g0) * Float(j) / Float(n); for (p, st) in ch { p[(i + j) * st] *= g } }
                    }
                    g0 = g1; i += n
                }
            }
        }
        update(channels: C)
        let c = chain
        let atk = { (ms: Double) in exp(-1 / max(ms / 1000 * self.fs, 1)) }
        let gA = atk(c.gate.attackMs), gR = atk(c.gate.releaseMs)
        let cA = atk(c.compressor.attackMs), cR = atk(c.compressor.releaseMs)
        let lR = atk(c.limiter.releaseMs)
        let ceiling = Float(pow(10, c.limiter.ceilingDb / 20))
        let outGain = pow(10, c.outputGainDb / 20)
        var x = [Double](repeating: 0, count: C)
        for i in 0..<frames {
            for k in 0..<C { x[k] = Double(ch[k].0[i * ch[k].1]) }
            // gate
            if c.gate.enabled && c.gate.rangeDb < 0 {
                let lvl = x.map { abs($0) }.max() ?? 0
                gateEnv = max(lvl, gateEnv * 0.9995)
                let open = 20 * log10(gateEnv + 1e-12) >= c.gate.thresholdDb
                let target = open ? 0.0 : c.gate.rangeDb
                let coef = target > gateGainDb ? gA : gR
                gateGainDb = target + (gateGainDb - target) * coef
                let g = pow(10, gateGainDb / 20); for k in 0..<C { x[k] *= g }
            }
            // EQ
            if c.eqEnabled {
                for (bi, b) in c.eq.enumerated() where b.enabled && bi < coefs.count {
                    let q = coefs[bi]
                    for k in 0..<C {
                        let y = q.b0 * x[k] + z1[bi][k]
                        if !y.isFinite || abs(y) > 1e3 {      // filter blew up: reset it instead of silencing everything
                            z1[bi][k] = 0; z2[bi][k] = 0; AudioDebug.resets += 1; continue
                        }
                        z1[bi][k] = q.b1 * x[k] - q.a1 * y + z2[bi][k]
                        z2[bi][k] = q.b2 * x[k] - q.a2 * y
                        x[k] = y
                    }
                }
            }
            // compressor (stereo-linked, peak detector, soft knee)
            if c.compressor.enabled && c.compressor.ratio > 1 {
                let lvl = 20 * log10((x.map { abs($0) }.max() ?? 0) + 1e-12)
                let over = lvl - c.compressor.thresholdDb, W = c.compressor.kneeDb, sl = 1 - 1 / c.compressor.ratio
                var gr = 0.0
                if W > 0 && abs(over) <= W / 2 { gr = sl * pow(over + W / 2, 2) / (2 * W) } else if over > 0 { gr = sl * over }
                compGR = gr + (compGR - gr) * (gr > compGR ? cA : cR)
                let g = pow(10, (c.compressor.makeupDb - compGR) / 20); for k in 0..<C { x[k] *= g }
            } else if c.compressor.enabled && c.compressor.makeupDb != 0 {
                let g = pow(10, c.compressor.makeupDb / 20); for k in 0..<C { x[k] *= g }
            }
            for k in 0..<C { x[k] *= outGain }
            // limiter with look-ahead: gain is the smallest needed over the window, then released smoothly
            if c.limiter.enabled {
                let pk = Float(x.map { abs($0) }.max() ?? 0)
                var need = Float(1)
                if look > 0 {
                    peakWin[pwPos] = pk; pwPos = (pwPos + 1) % look
                    let m = peakWin.max() ?? 0
                    need = m > ceiling ? ceiling / m : 1
                } else { need = pk > ceiling ? ceiling / pk : 1 }
                if Double(need) < limGain { limGain = Double(need) } else { limGain = Double(need) + (limGain - Double(need)) * lR }
                for k in 0..<C {
                    var v = Float(x[k])
                    if look > 0 { let o = delay[k][dpos]; delay[k][dpos] = v; v = o }
                    v *= Float(limGain)
                    x[k] = Double(min(max(v, -ceiling), ceiling))   // safety: never above the ceiling
                }
                if look > 0 { dpos = (dpos + 1) % look }
            }
            for k in 0..<C {
                var v = x[k]
                if !v.isFinite { v = 0; AudioDebug.resets += 1; gateGainDb = 0; compGR = 0; limGain = 1 }
                if abs(v) >= 1 { AudioDebug.overs += 1 }
                // meters: plain and K-weighted energy of what goes out
                let o = min(max(v, -1), 1)
                if meters {
                if kc == nil || kz.count != C { kc = AudioProcessor.kWeighting(fs); kz = Array(repeating: [0, 0, 0, 0], count: C) }
                let (s1, s2) = kc!
                let y1 = s1.b0 * o + kz[k][0]; kz[k][0] = s1.b1 * o - s1.a1 * y1 + kz[k][1]; kz[k][1] = s1.b2 * o - s1.a2 * y1
                let y2 = s2.b0 * y1 + kz[k][2]; kz[k][2] = s2.b1 * y1 - s2.a1 * y2 + kz[k][3]; kz[k][3] = s2.b2 * y1 - s2.a2 * y2
                AudioDebug.sumSq += o * o / Double(C); AudioDebug.kSumSq += (C == 1 ? 2 : 1) * y2 * y2 / Double(C == 1 ? 1 : 1)
                if k == C - 1 { AudioDebug.count += 1 }
                }
                ch[k].0[i * ch[k].1] = Float(min(max(v, -1), 1))      // safety: never more than full scale (overloads clip, as in Premiere)
            }
        }
    }
}

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in storageOut.pointee = clientInfo }
private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<AudioProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}
private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, asbd in
    let p = Unmanaged<AudioProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    p.fs = asbd.pointee.mSampleRate; p.version = -1
    AudioDebug.fmt = "rate \(asbd.pointee.mSampleRate) ch \(asbd.pointee.mChannelsPerFrame) flags \(asbd.pointee.mFormatFlags) bits \(asbd.pointee.mBitsPerChannel)"
}
private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, abl, framesOut, flagsOut in
    var range = CMTimeRange()
    let st = MTAudioProcessingTapGetSourceAudio(tap, frames, abl, flagsOut, &range, framesOut)
    guard st == noErr else { AudioDebug.fmt += " ERR \(st)"; return }
    let p = Unmanaged<AudioProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    p.process(abl, frames: Int(framesOut.pointee), start: range.start.isValid ? range.start.seconds : nil)
}

enum AudioTap {
    static func make(_ store: AudioStore) -> MTAudioProcessingTap? {
        let proc = AudioProcessor(store)
        var cb = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0,
                                               clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(proc).toOpaque()),
                                               init: tapInit, finalize: tapFinalize, prepare: tapPrepare, unprepare: nil, process: tapProcess)
        var tap: MTAudioProcessingTap?
        let st = MTAudioProcessingTapCreate(kCFAllocatorDefault, &cb, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        return st == noErr ? tap : nil
    }
}

// ITU-R BS.1770-4 loudness (48 kHz), sample peak
public enum Loudness {
    public static func measure(_ b: Built, from: Double? = nil, to: Double? = nil) throws -> (lufs: Double, peakDb: Double, seconds: Double) {
        let reader = try AVAssetReader(asset: b.composition)
        let tracks = b.composition.tracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw RenderError.message("no audio") }
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        out.audioMix = b.audioMix
        reader.add(out)
        if let f = from, let t = to, t > f { reader.timeRange = CMTimeRange(start: CMTime(seconds: f, preferredTimescale: 48000), end: CMTime(seconds: t, preferredTimescale: 48000)) }
        guard reader.startReading() else { throw RenderError.message("read failed") }
        // K-weighting (48 kHz coefficients from the standard)
        let s1b = [1.53512485958697, -2.69169618940638, 1.19839281085285], s1a = [-1.69065929318241, 0.73248077421585]
        let s2b = [1.0, -2.0, 1.0], s2a = [-1.99004745483398, 0.99007225036621]
        var st = [[Double]](repeating: [0, 0, 0, 0], count: 2)
        var block: [Double] = []           // mean square per 100 ms
        var acc = 0.0, n = 0, peak: Float = 0, total = 0
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            var len = 0; var ptr: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            guard let p = ptr else { continue }
            let f = UnsafeRawPointer(p).assumingMemoryBound(to: Float.self)
            let frames = len / 8
            for i in 0..<frames {
                var e = 0.0
                for c in 0..<2 {
                    let x = Double(f[i * 2 + c]); peak = max(peak, abs(Float(x)))
                    let y1 = s1b[0] * x + st[c][0]; st[c][0] = s1b[1] * x - s1a[0] * y1 + st[c][1]; st[c][1] = s1b[2] * x - s1a[1] * y1
                    let y2 = s2b[0] * y1 + st[c][2]; st[c][2] = s2b[1] * y1 - s2a[0] * y2 + st[c][3]; st[c][3] = s2b[2] * y1 - s2a[1] * y2
                    e += y2 * y2
                }
                acc += e; n += 1; total += 1
                if n == 4800 { block.append(acc / 4800); acc = 0; n = 0 }
            }
        }
        // 400 ms gating blocks with 75 % overlap = 4 consecutive 100 ms blocks
        var g: [Double] = []
        if block.count >= 4 { for i in 0...(block.count - 4) { g.append((block[i] + block[i + 1] + block[i + 2] + block[i + 3]) / 4) } }
        func L(_ z: Double) -> Double { -0.691 + 10 * log10(max(z, 1e-20)) }
        let abs1 = g.filter { L($0) > -70 }
        guard !abs1.isEmpty else { return (-70, 20 * log10(Double(max(peak, 1e-9))), Double(total) / 48000) }
        let rel = L(abs1.reduce(0, +) / Double(abs1.count)) - 10
        let gated = abs1.filter { L($0) > rel }
        return (L(gated.reduce(0, +) / Double(max(gated.count, 1))), 20 * log10(Double(max(peak, 1e-9))), Double(total) / 48000)
    }
}
