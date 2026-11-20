import Foundation

public enum DragMode: String {
    case trimStart = "trim_start", trimEnd = "trim_end", move
}

// The ONE place that decides what a drag on the timeline does. The mouse and the `drag_edit`
// command both call it, so what you see while dragging is exactly what gets committed.
public enum TimelineEdit {
    public static func apply(_ mode: DragMode, clip: Clip, delta: Double, clips: [Clip],
                             mediaDuration: Double?, audioMediaDuration: Double? = nil, fps: Double, magnets: [Double], magnetRange: Double) -> Clip {
        let f = 1 / fps
        func snap(_ t: Double) -> Double { (t * fps).rounded() / fps }
        func magnet(_ t: Double) -> Double {
            guard magnetRange > 0, let m = magnets.min(by: { abs($0 - t) < abs($1 - t) }), abs(m - t) <= magnetRange else { return t }
            return m
        }
        let end = clip.offset + clip.duration
        let others = clips.filter { $0.id != clip.id }
        let prevEnd = others.map { $0.offset + $0.duration }.filter { $0 <= clip.offset + f * 0.25 }.max() ?? 0
        let nextStart = others.map { $0.offset }.filter { $0 >= end - f * 0.25 }.min() ?? .infinity
        var c = clip
        switch mode {
        case .trimStart:
            var t = snap(magnet(clip.offset + delta))
            let room = min(clip.sourceIn, clip.audioSource?.sourceIn ?? .infinity) / clip.sp
            t = min(max(t, max(prevEnd, clip.offset - room)), end - f)   // not before media start / previous clip
            let d = t - clip.offset
            c.offset = t; c.sourceIn = clip.sourceIn + d * clip.sp; c.audioSource?.sourceIn += d * clip.sp; c.duration = clip.duration - d
            c.audio.keys = clip.audio.keys?.map { VolKey(t: $0.t - d, db: $0.db) }
        case .trimEnd:
            var t = snap(magnet(end + delta))
            var upper = nextStart
            if let md = mediaDuration { upper = min(upper, clip.offset + (md - clip.sourceIn) / clip.sp) }
            if let a = clip.audioSource, let am = audioMediaDuration { upper = min(upper, clip.offset + (am - a.sourceIn) / clip.sp) }   // not past media end / next clip
            t = max(min(t, upper), clip.offset + f)
            c.duration = t - clip.offset
        case .move:
            let raw = clip.offset + delta
            // snap whichever edge (start or end) is closer to a magnet
            let a = magnet(raw), b = magnet(raw + clip.duration) - clip.duration
            let da = abs(a - raw), db = abs(b - raw)       // how far each edge was pulled (0 = no magnet nearby)
            let t0 = (da == 0 && db == 0) ? raw : (da == 0 ? b : (db == 0 ? a : (da <= db ? a : b)))
            var t = snap(t0)
            t = max(prevEnd, min(t, nextStart - clip.duration))
            if t.isFinite { c.offset = max(0, t) }
        }
        return c
    }
}
