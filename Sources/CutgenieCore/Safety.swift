import Foundation

/// Cutgenie's own folders under ~/Library (never next to the user's projects or media)
enum SafetyDirs {
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cutgenie")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static func sub(_ n: String) -> URL {
        let u = support.appendingPathComponent(n); try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }
    static func key(_ path: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 16)
    }
}

/// Plain-text log of problems: ~/Library/Logs/Cutgenie/cutgenie.log (kept under 2 MB; the old part moves to cutgenie.old.log)
public enum Log {
    static let url: URL = {
        let d = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Cutgenie")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("cutgenie.log")
    }()
    static let q = DispatchQueue(label: "cutgenie.log")
    public static func write(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(f.string(from: Date()))  [\(getpid())]  \(s)\n"
        q.async {
            if let sz = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, sz > 2_000_000 {
                let old = url.deletingLastPathComponent().appendingPathComponent("cutgenie.old.log")
                try? FileManager.default.removeItem(at: old); try? FileManager.default.moveItem(at: url, to: old)
            }
            if let h = FileHandle(forWritingAtPath: url.path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
            else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        }
    }
}

/// Unsaved work, written every minute to ~/Library/Application Support/Cutgenie/Recovery (one file per project path)
enum Recovery {
    struct Meta: Codable { var path: String; var time: Date }
    static func file(_ path: String) -> URL { SafetyDirs.sub("Recovery").appendingPathComponent(SafetyDirs.key(path) + ".cutgenie.json") }
    static func meta(_ path: String) -> URL { SafetyDirs.sub("Recovery").appendingPathComponent(SafetyDirs.key(path) + ".meta.json") }
    static func save(_ p: Project, for path: String) {
        do {
            try p.save(to: file(path))
            try JSONEncoder().encode(Meta(path: path, time: Date())).write(to: meta(path), options: .atomic)
        } catch { Log.write("recovery save failed for \(path): \(error)") }
    }
    static func load(for path: String) -> (Project, Date)? {
        guard let d = try? Data(contentsOf: meta(path)), let m = try? JSONDecoder().decode(Meta.self, from: d),
              let p = try? Project.load(from: file(path)) else { return nil }
        return (p, m.time)
    }
    static func all() -> [(path: String, time: Date)] {
        let d = SafetyDirs.sub("Recovery")
        return ((try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasSuffix(".meta.json") }
            .compactMap { u in (try? Data(contentsOf: u)).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }.map { ($0.path, $0.time) } }
            .sorted { $0.time > $1.time }
    }
    static func clear(for path: String) {
        try? FileManager.default.removeItem(at: file(path)); try? FileManager.default.removeItem(at: meta(path))
    }
}

/// Before a save replaces a project file, the old file is kept: ~/Library/Application Support/Cutgenie/Versions/<name>/ (last 10)
enum Versions {
    static func folder(_ u: URL) -> URL {
        let stem = u.deletingPathExtension().deletingPathExtension().lastPathComponent
        return SafetyDirs.sub("Versions").appendingPathComponent(stem + " - " + SafetyDirs.key(u.path))
    }
    static func keep(_ u: URL) {
        guard FileManager.default.fileExists(atPath: u.path) else { return }
        let d = folder(u); try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let to = d.appendingPathComponent(f.string(from: Date()) + ".cutgenie.json")
        try? FileManager.default.removeItem(at: to)
        do { try FileManager.default.copyItem(at: u, to: to) } catch { Log.write("version copy failed for \(u.path): \(error)") }
        let all = ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).filter { $0.hasSuffix(".cutgenie.json") }.sorted()
        for old in all.dropLast(10) { try? FileManager.default.removeItem(at: d.appendingPathComponent(old)) }
    }
}
