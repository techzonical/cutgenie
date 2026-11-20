import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Small picture thumbnails for video clips on the timeline (made in the background, cached in memory and on disk in
// ~/Library/Caches/Cutgenie/Thumbs, so a long project shows its pictures at once the next time it opens).
// They show the camera picture as stored in the file (no grade), only to help find your place.
public final class Thumbs: @unchecked Sendable {
    public static let shared = Thumbs()
    private let lock = NSLock()
    private var cache: [String: CGImage] = [:]
    private var pending: [String: Set<Double>] = [:]      // path -> times waiting
    private var running: Set<String> = []
    public var onReady: (@Sendable () -> Void)?

    static func key(_ path: String, _ t: Double) -> String { "\(path)#\(Int((t * 10).rounded()))" }

    /// thumbnail of `path` at media time t, or nil (and it gets made in the background)
    public func image(_ path: String, at t: Double) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[Thumbs.key(path, t)] { return c }
        pending[path, default: []].insert((t * 10).rounded() / 10)
        if !running.contains(path) { running.insert(path); Task.detached(priority: .utility) { await self.work(path) } }
        return nil
    }

    private func work(_ path: String) async {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
        gen.maximumSize = CGSize(width: 192, height: 108)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        while true {
            lock.lock()
            guard let times = pending[path], !times.isEmpty else { running.remove(path); lock.unlock(); return }
            pending[path] = []
            lock.unlock()
            var made = 0
            let dir = Thumbs.diskDir(path)
            for t in times.sorted() {
                let f = dir?.appendingPathComponent("\(Int((t * 10).rounded())).jpg")
                if let f, let src = CGImageSourceCreateWithURL(f as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    store(Thumbs.key(path, t), img); made += 1
                    if made % 24 == 0 { onReady?(); Thumbs.post() }
                    continue
                }
                if let (img, _) = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)) {
                    store(Thumbs.key(path, t), img); made += 1
                    if let f, let d = CGImageDestinationCreateWithURL(f as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                        CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary); CGImageDestinationFinalize(d)
                    }
                    if made % 6 == 0 { onReady?(); Thumbs.post() }
                }
            }
            onReady?(); Thumbs.post()
        }
    }
}

extension Thumbs {
    /// memory is kept in check on very long projects: past 6000 pictures the cache starts again (the disk copy stays)
    func store(_ k: String, _ img: CGImage) {
        lock.lock(); if cache.count > 6000 { cache.removeAll(keepingCapacity: true) }; cache[k] = img; lock.unlock()
    }
    /// one folder per media file and its date (a changed file gets new pictures)
    static func diskDir(_ path: String) -> URL? {
        let fm = FileManager.default
        let mt = ((try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
        var h: UInt64 = 1469598103934665603
        for b in "\(path)|\(Int(mt))".utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        guard let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let d = base.appendingPathComponent("Cutgenie/Thumbs/" + String(h, radix: 16))
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// posted (on the main thread) whenever new thumbnails or waveforms are ready, for every view that shows them
    public static let readyNote = Notification.Name("CutgenieMediaPicturesReady")
    static func post() { DispatchQueue.main.async { NotificationCenter.default.post(name: readyNote, object: nil) } }
}
