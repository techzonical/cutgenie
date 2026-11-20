import Foundation
import AVFoundation
import Accelerate

/// Lines recordings up by their sound (multi-camera / separate mic sync, like Final Cut "Synchronize Clips").
/// Both sounds are reduced to mono at a low rate and compared with a whitened cross-correlation (GCC-PHAT),
/// which works across different microphones and rooms.
public enum AudioSync {
    public static let rate = 2000.0

    /// mono samples of the file from `start` for `dur` seconds (or to the end)
    public static func load(_ url: URL, start: Double, dur: Double) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, start), preferredTimescale: 48000),
                                       duration: CMTime(seconds: dur, preferredTimescale: 48000))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8000.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(out)
        guard reader.startReading() else { return [] }
        var s: [Float] = []
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            var len = 0; var ptr: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            guard let p = ptr else { continue }
            s.append(contentsOf: UnsafeBufferPointer(start: UnsafeRawPointer(p).assumingMemoryBound(to: Float.self), count: len / 4))
        }
        // 8 kHz -> 2 kHz (average of 4: a simple low-pass before thinning out)
        let q = Int(8000 / rate)
        var d = [Float](repeating: 0, count: s.count / q)
        for i in 0..<d.count { var t: Float = 0; for j in 0..<q { t += s[i * q + j] }; d[i] = t / Float(q) }
        return d
    }

    /// k (samples) where b[n + k] best matches a[n]; k can be negative. confidence = main peak / next best peak (>= 1).
    public static func lag(_ a: [Float], _ b: [Float]) -> (k: Int, confidence: Double) {
        guard a.count > 100, b.count > 100 else { return (0, 0) }
        var log2n = 1; while (1 << log2n) < a.count + b.count { log2n += 1 }
        let n = 1 << log2n, h = n / 2
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return (0, 0) }
        defer { vDSP_destroy_fftsetup(setup) }
        func spectrum(_ x: [Float]) -> ([Float], [Float]) {
            var buf = [Float](repeating: 0, count: n)
            // remove the average so silence/hum offsets don't dominate
            let m = x.reduce(0, +) / Float(x.count)
            for i in 0..<x.count { buf[i] = x[i] - m }
            var re = [Float](repeating: 0, count: h), im = [Float](repeating: 0, count: h)
            re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                buf.withUnsafeBufferPointer { bp in
                    bp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: h) { vDSP_ctoz($0, 2, &sc, 1, vDSP_Length(h)) }
                }
                vDSP_fft_zrip(setup, &sc, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
            } }
            return (re, im)
        }
        let (ar, ai) = spectrum(a)
        var (br, bi) = spectrum(b)
        // cross spectrum conj(A)·B, whitened (phase transform, slightly softened), below ~80 Hz left out (rumble, wind)
        let lowBin = Int(80.0 / (rate / Double(n))) + 1
        for i in 1..<h {
            let re = ar[i] * br[i] + ai[i] * bi[i], im = ar[i] * bi[i] - ai[i] * br[i]
            let mag = (re * re + im * im).squareRoot()
            let w: Float = i < lowBin ? 0 : 1 / max(pow(mag, 0.85), 1e-9)
            br[i] = re * w; bi[i] = im * w
        }
        br[0] = 0; bi[0] = 0           // DC and Nyquist
        var r = [Float](repeating: 0, count: n)
        br.withUnsafeMutableBufferPointer { rp in bi.withUnsafeMutableBufferPointer { ip in
            var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            vDSP_fft_zrip(setup, &sc, 1, vDSP_Length(log2n), FFTDirection(FFT_INVERSE))
            r.withUnsafeMutableBufferPointer { op in
                op.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: h) { vDSP_ztoc(&sc, 1, $0, 2, vDSP_Length(h)) }
            }
        } }
        // valid lags: -(a.count-1) ... b.count-1 (negative ones wrap to the end)
        func lagOf(_ i: Int) -> Int { i < b.count ? i : i - n }
        var best = 0, bv: Float = -.infinity
        for i in 0..<n where (i < b.count || i > n - a.count) && r[i] > bv { bv = r[i]; best = i }
        let guardS = Int(0.05 * rate), bk = lagOf(best)
        var second: Float = 0
        for i in 0..<n where (i < b.count || i > n - a.count) && abs(lagOf(i) - bk) > guardS { second = max(second, r[i]) }
        return (bk, second > 0 ? Double(bv / second) : 99)
    }

    /// Offset L (seconds) with otherFile(t + L) == refFile(t). refStart/refDur: the part of the reference to listen to.
    public static func offset(ref: URL, refStart: Double, refDur: Double, other: URL) async throws -> (seconds: Double, confidence: Double) {
        let a = try await load(ref, start: refStart, dur: refDur)
        let otherDur = try await AVURLAsset(url: other).load(.duration).seconds
        let b = try await load(other, start: 0, dur: min(otherDur, 75 * 60))
        guard a.count > Int(rate), b.count > Int(rate) else { throw RenderError.message("not enough sound to compare") }
        let (k, conf) = lag(a, b)
        return (Double(k) / rate - refStart, conf)
    }
}
