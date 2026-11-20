import Foundation
import AVFoundation

// Peak envelope of an audio file at 100 values per second (computed once in the background, then cached in memory).
public final class Waveforms: @unchecked Sendable {
    public static let shared = Waveforms()
    public static let rate = 100.0
    private let lock = NSLock()
    private var cache: [String: [Float]] = [:]
    private var busy: Set<String> = []
    public var onReady: (@Sendable () -> Void)?

    public func peaks(_ path: String) -> [Float]? { lock.lock(); defer { lock.unlock() }; return cache[path] }

    public func request(_ path: String) {
        lock.lock()
        if cache[path] != nil || busy.contains(path) { lock.unlock(); return }
        busy.insert(path); lock.unlock()
        Task.detached(priority: .utility) {
            let env = (try? await Waveforms.compute(path)) ?? []
            self.lock.lock(); self.cache[path] = env; self.busy.remove(path); self.lock.unlock()
            self.onReady?(); Thumbs.post()
        }
    }

    static func compute(_ path: String) async throws -> [Float] {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let sr = 8000.0
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(out)
        guard reader.startReading() else { return [] }
        let per = Int(sr / rate)
        var env: [Float] = []; var cur: Int16 = 0; var n = 0
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            var len = 0; var ptr: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            guard let p = ptr else { continue }
            let s = UnsafeRawPointer(p).assumingMemoryBound(to: Int16.self)
            for i in 0..<(len / 2) {
                let v = s[i] == Int16.min ? Int16.max : abs(s[i]); if v > cur { cur = v }
                n += 1
                if n == per { env.append(Float(cur) / 32767); cur = 0; n = 0 }
            }
        }
        return env
    }
}
