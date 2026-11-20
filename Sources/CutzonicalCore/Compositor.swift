import AVFoundation
import CoreImage

// Cutzonical's own video compositor: it receives a frame from EVERY video track (V1 = main storyline, plus one track per
// upper video track V2, V3, ...) and hands them to the render function from Renderer.build. The frames are requested in
// the same format AVFoundation's single-track Core Image path used (10-bit 4:2:0, tagged by the file), so V1 looks identical.
final class CutzonicalInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let mainTrack: CMPersistentTrackID
    let laneTracks: [Int: CMPersistentTrackID]          // video track number (1 = V2) -> composition track
    let render: (_ t: Double, _ main: CIImage, _ upper: [Int: CIImage]) -> CIImage
    let context: CIContext
    let size: CGSize
    init(range: CMTimeRange, main: CMPersistentTrackID, lanes: [Int: CMPersistentTrackID], size: CGSize, context: CIContext,
         render: @escaping (Double, CIImage, [Int: CIImage]) -> CIImage) {
        timeRange = range; mainTrack = main; laneTracks = lanes; self.render = render; self.context = context; self.size = size
        requiredSourceTrackIDs = ([main] + lanes.values.sorted()).map { NSNumber(value: $0) }
    }
}

final class CutzonicalCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange],
         kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_64RGBAHalf],
         kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
    }
    var supportsWideColorSourceFrames: Bool { true }
    var supportsHDRSourceFrames: Bool { true }
    private var renderContext: AVVideoCompositionRenderContext?
    private let lock = NSLock()
    func renderContextChanged(_ c: AVVideoCompositionRenderContext) { lock.lock(); renderContext = c; lock.unlock() }

    func startRequest(_ req: AVAsynchronousVideoCompositionRequest) {
        guard let ins = req.videoCompositionInstruction as? CutzonicalInstruction else { req.finish(with: RenderError.message("no instruction")); return }
        lock.lock(); let rc = renderContext; lock.unlock()
        guard let out = rc?.newPixelBuffer() else { req.finish(with: RenderError.message("no output buffer")); return }
        let extent = CGRect(origin: .zero, size: ins.size)
        let main = req.sourceFrame(byTrackID: ins.mainTrack).map { CIImage(cvPixelBuffer: $0) } ?? CIImage(color: .black).cropped(to: extent)
        var upper: [Int: CIImage] = [:]
        for (lane, id) in ins.laneTracks { if let pb = req.sourceFrame(byTrackID: id) { upper[lane] = CIImage(cvPixelBuffer: pb) } }
        LastFrame.store(req.compositionTime.seconds, main, upper, ins)
        let img = ins.render(req.compositionTime.seconds, main, upper)
        ins.context.render(img.cropped(to: extent), to: out)
        req.finish(withComposedVideoFrame: out)
    }
    func cancelAllPendingVideoCompositionRequests() {}
}

/// The last frame the compositor made (its source pictures). Live edits redraw THIS frame directly
/// (no seeking the player back and forth), so dragging a slider or a graphic is smooth.
public enum LastFrame {
    nonisolated(unsafe) static var t = -1.0
    nonisolated(unsafe) static var main: CIImage?
    nonisolated(unsafe) static var upper: [Int: CIImage] = [:]
    nonisolated(unsafe) static var ins: CutzonicalInstruction?
    static let lock = NSLock()
    static let queue = DispatchQueue(label: "cutzonical.liveframe", qos: .userInteractive)
    nonisolated(unsafe) static var busy = false, again = false
    static func store(_ t: Double, _ m: CIImage, _ u: [Int: CIImage], _ i: CutzonicalInstruction) {
        lock.lock(); self.t = t; main = m; upper = u; ins = i; lock.unlock()
    }
    public static var time: Double { lock.lock(); defer { lock.unlock() }; return t }
    /// redraw the last frame with the current settings and hand it to `show` (latest request wins, never queues up)
    public static func redraw(_ show: @escaping @Sendable (CVPixelBuffer) -> Void) {
        lock.lock()
        if busy { again = true; lock.unlock(); return }
        busy = true; lock.unlock()
        queue.async {
            while true {
                lock.lock(); let (tt, m, u, i) = (t, main, upper, ins); again = false; lock.unlock()
                if let m, let i {
                    let img = i.render(tt, m, u).cropped(to: CGRect(origin: .zero, size: i.size))
                    var pb: CVPixelBuffer?
                    CVPixelBufferCreate(nil, Int(i.size.width), Int(i.size.height), kCVPixelFormatType_32BGRA,
                                        [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
                    if let pb { i.context.render(img, to: pb); show(pb) }
                }
                lock.lock(); if !again { busy = false; lock.unlock(); return }; lock.unlock()
            }
        }
    }
}
