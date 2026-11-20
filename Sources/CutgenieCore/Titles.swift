import Foundation
import AppKit
import CoreImage

// Saved titles: one or more text / shape layers (look, builds, keyframes, mask) kept for every project, with a small picture.
// Saved in ~/Library/Application Support/Cutgenie/Titles/<name>.json + <name>.png (CUTGENIE_TITLES overrides, for tests).

public enum Titles {
    static var dir: URL {
        if let d = ProcessInfo.processInfo.environment["CUTGENIE_TITLES"] { return URL(fileURLWithPath: d) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cutgenie/Titles")
    }
    static func safe(_ n: String) -> String { n.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") }
    public static var names: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }
    public static func thumbnail(_ name: String) -> NSImage? { NSImage(contentsOf: dir.appendingPathComponent(safe(name) + ".png")) }

    /// layers keep their timing relative to the first one; their place on the timeline is chosen when the title is added
    static func save(_ name: String, _ layers: [Overlay], paths: [String]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let start = layers.map(\.offset).min() ?? 0
        let ls = layers.map { o -> Overlay in var o = o; o.offset -= start; o.connectedTo = nil; o.disabled = nil; return o }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(ls).write(to: dir.appendingPathComponent(safe(name) + ".json"))
        // picture: the layers drawn as they look when fully in, on a dark background
        let snaps = zip(ls, paths).map { OverlayRender.Snap(o: $0.0, path: $0.1) }.sorted { $0.o.lane < $1.o.lane }
        let H = OverlayRender.projectHeight > 0 ? OverlayRender.projectHeight : 1080, W = H * 16 / 9
        let frame = CGRect(x: 0, y: 0, width: W, height: H)
        var img = CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.14)).cropped(to: frame)
        for s in snaps {
            let mid = s.o.offset + s.o.duration / 2
            img = OverlayRender.draw(s, t: mid, frame: frame, over: img)
        }
        let small = img.transformed(by: CGAffineTransform(scaleX: 320 / W, y: 320 / W))
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        if let cg = ctx.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)),
           let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent(safe(name) + ".png"))
        }
    }
    static func load(_ name: String) -> [Overlay]? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(safe(name) + ".json")) else { return nil }
        return try? JSONDecoder().decode([Overlay].self, from: d)
    }
    static func delete(_ name: String) {
        for x in [".json", ".png"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(safe(name) + x)) }
    }
}
