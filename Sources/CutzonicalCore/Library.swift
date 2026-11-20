import Combine
import Foundation
import AVFoundation
import ImageIO

// Media library: your footage, sound and pictures, linked where they are on disk (never copied, moved or renamed).
// Shared by every project; saved in ~/Library/Application Support/Cutzonical/library.json (CUTZONICAL_LIBRARY overrides, for tests).

public struct LibFolder: Codable, Equatable, Hashable {
    public var path: String
    public var watched: Bool = true          // new files that appear in it are added on their own
}

public struct LibItem: Codable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var kind: String                  // "video", "audio", "image"
    public var duration: Double = 0
    public var width: Int?
    public var height: Int?
    public var fps: Double?
    public var hdr: String?                  // "HLG", "PQ" or nil (SDR)
    public var hasAudio: Bool = false
    public var camera: String?
    public var date: Date?
    public var added: Date = Date()
    public var rating: Int = 0               // 1 favourite, -1 rejected
    public var note: String?
    public var keywords: [String] = []
}

/// a marked part of a clip (I / O), with its own name, rating, note and keywords
public struct LibRange: Codable, Equatable, Identifiable {
    public var id: String
    public var path: String
    public var start: Double
    public var end: Double
    public var name: String = ""
    public var rating: Int = 0
    public var note: String?
    public var keywords: [String] = []
}

/// your own group: any clip or range can be in any number of them
public struct LibCollection: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var members: [String] = []        // item paths and range ids
}

struct LibraryFile: Codable {
    var folders: [LibFolder] = []
    var items: [LibItem] = []
    var ranges: [LibRange] = []
    var collections: [LibCollection] = []
}

@MainActor
public final class MediaLibrary: ObservableObject {
    public static let shared = MediaLibrary()
    /// goes up on every change (so views can keep a computed list until something really changed)
    public private(set) var version = 0
    private var versionWatch: Any?
    @Published public private(set) var folders: [LibFolder] = []
    @Published public private(set) var items: [LibItem] = []
    @Published public private(set) var ranges: [LibRange] = []
    @Published public private(set) var collections: [LibCollection] = []
    @Published public private(set) var scanning = 0
    @Published public private(set) var offline: Set<String> = []
    private var timer: Timer?

    nonisolated public static let videoExt: Set<String> = ["mov", "mp4", "m4v", "mxf", "avi", "mts", "m2ts", "3gp", "hevc"]
    nonisolated public static let audioExt: Set<String> = ["wav", "aif", "aiff", "mp3", "m4a", "aac", "caf", "flac"]
    nonisolated public static let imageExt: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp", "psd", "bmp"]
    nonisolated public static func kind(_ path: String) -> String? {
        let e = (path as NSString).pathExtension.lowercased()
        return videoExt.contains(e) ? "video" : audioExt.contains(e) ? "audio" : imageExt.contains(e) ? "image" : nil
    }

    var fileURL: URL {
        if let p = ProcessInfo.processInfo.environment["CUTZONICAL_LIBRARY"] { return URL(fileURLWithPath: p) }
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cutzonical")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("library.json")
    }

    init() {
        versionWatch = objectWillChange.sink { [weak self] _ in self?.version &+= 1 }
        if let d = try? Data(contentsOf: fileURL), let f = try? JSONDecoder().decode(LibraryFile.self, from: d) {
            folders = f.folders; items = f.items; ranges = f.ranges; collections = f.collections
        }
        checkOffline()
        // watched folders: look for new files every 15 s (cheap: only names are listed; new ones are read)
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in self?.rescan() } }
    }

    func save() {
        let f = LibraryFile(folders: folders, items: items, ranges: ranges, collections: collections)
        if let d = try? JSONEncoder().encode(f) { try? d.write(to: fileURL, options: .atomic) }
    }

    public func checkOffline() {
        offline = Set(items.map { $0.path }.filter { !FileManager.default.fileExists(atPath: $0) })
    }

    // MARK: adding

    /// a folder (all media inside, sub-folders too) or single files
    public func add(paths: [String], watch: Bool = true) async {
        var files: [String] = []
        for p in paths {
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &dir) else { continue }
            if dir.boolValue {
                if !folders.contains(where: { $0.path == p }) { folders.append(LibFolder(path: p, watched: watch)) }
                files += Self.mediaFiles(in: p)
            } else if Self.kind(p) != nil { files.append(p) }
        }
        await addFiles(files)
        save()
    }

    nonisolated static func mediaFiles(in dir: String) -> [String] {
        guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [String] = []
        for case let u as URL in en where kind(u.path) != nil { out.append(u.path) }
        return out.sorted()
    }

    func addFiles(_ files: [String]) async {
        let known = Set(items.map { $0.path })
        let new = files.filter { !known.contains($0) }
        guard !new.isEmpty else { return }
        scanning += new.count
        // read file details a few at a time
        var i = 0
        while i < new.count {
            let batch = Array(new[i..<min(i + 6, new.count)])
            let got = await withTaskGroup(of: LibItem?.self) { g in
                for p in batch { g.addTask { await Self.probe(p) } }
                var r: [LibItem] = []; for await x in g { if let x { r.append(x) } }; return r
            }
            items.append(contentsOf: got.sorted { $0.path < $1.path })
            scanning -= batch.count
            i += batch.count
        }
        save()
    }

    public func rescan() {
        let watched = folders.filter { $0.watched }
        guard !watched.isEmpty, scanning == 0 else { checkOffline(); return }
        Task.detached(priority: .utility) {
            let files = watched.flatMap { Self.mediaFiles(in: $0.path) }
            await MainActor.run { Task { await self.addFiles(files); self.checkOffline() } }
        }
    }

    /// file details (length, size, frame rate, HDR, sound, camera, date)
    nonisolated static func probe(_ path: String) async -> LibItem? {
        guard let k = kind(path) else { return nil }
        let url = URL(fileURLWithPath: path)
        var it = LibItem(path: path, name: url.lastPathComponent, kind: k)
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        it.date = attrs?[.creationDate] as? Date
        if k == "image" {
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let pr = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                it.width = pr[kCGImagePropertyPixelWidth] as? Int; it.height = pr[kCGImagePropertyPixelHeight] as? Int
                if let tiff = pr[kCGImagePropertyTIFFDictionary] as? [CFString: Any] { it.camera = tiff[kCGImagePropertyTIFFModel] as? String }
            }
            return it
        }
        let a = AVURLAsset(url: url)
        it.duration = (try? await a.load(.duration).seconds) ?? 0
        if !it.duration.isFinite { it.duration = 0 }
        it.hasAudio = !((try? await a.loadTracks(withMediaType: .audio)) ?? []).isEmpty
        if let v = try? await a.loadTracks(withMediaType: .video).first {
            if let s = try? await v.load(.naturalSize), let t = try? await v.load(.preferredTransform) {
                let r = s.applying(t); it.width = Int(abs(r.width)); it.height = Int(abs(r.height))
            }
            it.fps = (try? await v.load(.nominalFrameRate)).map { Double($0) }
            if let f = try? await v.load(.formatDescriptions).first,
               let tf = CMFormatDescriptionGetExtension(f, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
                if tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) { it.hdr = "HLG" }
                else if tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) { it.hdr = "PQ" }
            }
        } else if k == "video" { it.kind = "audio" }
        if let md = try? await a.load(.metadata) {
            for m in md {
                if m.commonKey == .commonKeyModel || m.identifier == .quickTimeMetadataModel, let s = try? await m.load(.stringValue) { it.camera = s }
                if m.commonKey == .commonKeyCreationDate, let s = try? await m.load(.dateValue) { it.date = s }
            }
        }
        return it
    }

    // MARK: editing

    public func item(_ path: String) -> LibItem? { items.first { $0.path == path } }
    public func update(_ path: String, _ f: (inout LibItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.path == path }) else { return }
        f(&items[i]); save()
    }
    public func updateRange(_ id: String, _ f: (inout LibRange) -> Void) {
        guard let i = ranges.firstIndex(where: { $0.id == id }) else { return }
        f(&ranges[i]); save()
    }
    @discardableResult public func addRange(path: String, start: Double, end: Double, name: String = "") -> LibRange {
        let r = LibRange(id: UUID().uuidString, path: path, start: min(start, end), end: max(start, end), name: name)
        ranges.append(r); save(); return r
    }
    public func deleteRange(_ id: String) {
        ranges.removeAll { $0.id == id }
        for i in collections.indices { collections[i].members.removeAll { $0 == id } }
        save()
    }
    /// takes the file out of the library (the file itself stays where it is)
    public func remove(paths: Set<String>) {
        items.removeAll { paths.contains($0.path) }
        let rids = Set(ranges.filter { paths.contains($0.path) }.map { $0.id })
        ranges.removeAll { rids.contains($0.id) }
        for i in collections.indices { collections[i].members.removeAll { paths.contains($0) || rids.contains($0) } }
        save()
    }
    public func removeFolder(_ path: String) {
        folders.removeAll { $0.path == path }
        remove(paths: Set(items.map { $0.path }.filter { $0.hasPrefix(path + "/") }))
    }
    public func setWatched(_ path: String, _ on: Bool) {
        if let i = folders.firstIndex(where: { $0.path == path }) { folders[i].watched = on; save() }
    }
    /// a moved / renamed / re-plugged file: point the library (ranges, collections) at its new place
    public func relink(_ old: String, to new: String) async {
        guard var it = await Self.probe(new) else { return }
        if let o = item(old) { it.rating = o.rating; it.note = o.note; it.keywords = o.keywords; it.added = o.added }
        items.removeAll { $0.path == old || $0.path == new }; items.append(it)
        for i in ranges.indices where ranges[i].path == old { ranges[i].path = new }
        for i in collections.indices { collections[i].members = collections[i].members.map { $0 == old ? new : $0 } }
        save(); checkOffline()
    }
    @discardableResult public func newCollection(_ name: String) -> LibCollection {
        let c = LibCollection(id: UUID().uuidString, name: name); collections.append(c); save(); return c
    }
    public func renameCollection(_ id: String, _ name: String) { if let i = collections.firstIndex(where: { $0.id == id }) { collections[i].name = name; save() } }
    public func deleteCollection(_ id: String) { collections.removeAll { $0.id == id }; save() }
    public func addToCollection(_ id: String, _ members: [String]) {
        guard let i = collections.firstIndex(where: { $0.id == id }) else { return }
        for m in members where !collections[i].members.contains(m) { collections[i].members.append(m) }
        save()
    }
    public func removeFromCollection(_ id: String, _ members: Set<String>) {
        guard let i = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[i].members.removeAll { members.contains($0) }; save()
    }

    /// which parts (media seconds) of each file the project already uses
    public static func used(in p: Project, base: URL?) -> [String: [ClosedRange<Double>]] {
        var out: [String: [ClosedRange<Double>]] = [:]
        // each file's path worked out once (not once per clip: 500+ clips and layers x 400 files was slow)
        var paths: [String: String] = [:]
        for a in p.assets { if let u = p.resolve(a.id, base: base) { paths[a.id] = u.standardizedFileURL.path } }
        func add(_ asset: String, _ a: Double, _ b: Double) {
            guard let path = paths[asset] else { return }
            out[path, default: []].append(a...max(a, b))
        }
        for c in p.clips + (p.upperClips ?? []) { add(c.asset, c.sourceIn, c.sourceIn + c.duration * c.sp) }
        for a in p.audioClips ?? [] { add(a.asset, a.sourceIn, a.sourceIn + a.duration) }
        for o in p.overlays ?? [] { add(o.asset, 0, 1e9) }
        return out
    }
}
