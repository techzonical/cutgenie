import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CutzonicalCore

// Media panel (left of the viewer): one Finder-like browser. Added folders and your collections are tiles;
// double-click one to go in, the path bar takes you back. One filter menu, one search box, and a slim bar
// for the selected clip (marks, ranges, add to timeline). Files are linked where they are, never copied.

/// one tile in the grid
enum MediaEntry: Identifiable {
    case folder(String, Int)                 // path, media files inside (all levels)
    case collection(LibCollection)
    case item(LibItem)
    case range(LibRange, LibItem)
    var id: String {
        switch self { case .folder(let p, _): return "dir:" + p; case .collection(let c): return "col:" + c.id
        case .item(let i): return i.path; case .range(let r, _): return r.id }
    }
    var media: LibItem? { switch self { case .item(let i): return i; case .range(_, let i): return i; default: return nil } }
    var span: (Double, Double) { switch self { case .range(let r, _): return (r.start, r.end); default: return (0, media?.duration ?? 0) } }
    var title: String {
        switch self {
        case .folder(let p, _): return (p as NSString).lastPathComponent
        case .collection(let c): return c.name
        case .item(let i): return i.name
        case .range(let r, let i): return r.name.isEmpty ? i.name : r.name
        }
    }
    var rating: Int { switch self { case .item(let i): return i.rating; case .range(let r, _): return r.rating; default: return 0 } }
}

enum MediaPlace: Hashable { case folder(String), collection(String), projects }

@MainActor
final class MediaState: ObservableObject {
    static let shared = MediaState()
    nonisolated(unsafe) static var searchClicked = false
    @Published var path: [MediaPlace] = []       // empty = the top of the library
    @Published var show = "all"                  // all, favourites, unused, rejected
    @Published var type = "all"                  // all, video, audio, image, hdr
    @Published var search = ""
    @Published var selected: String?
    @Published var expanded: Set<String> = []     // list view: folders / collections / Projects opened in place (arrow)             // entry id (file path or range id)
    @Published var markIn: Double?
    @Published var markOut: Double?
    /// the tile under the pointer and the moment of the file being skimmed there (Final Cut: I / O mark where you skim)
    var hoverEntry: MediaEntry?
    var hoverTime: Double?
    @Published var sort = UserDefaults.standard.string(forKey: "mediaSort") ?? "name" { didSet { UserDefaults.standard.set(sort, forKey: "mediaSort") } }
    @Published var tile = UserDefaults.standard.object(forKey: "mediaTile") as? Double ?? 130 { didSet { UserDefaults.standard.set(tile, forKey: "mediaTile") } }
    /// sound of clips connected above V1 (Q): on, or muted
    @Published var connectMuted = UserDefaults.standard.bool(forKey: "mediaConnectMuted") { didSet { UserDefaults.standard.set(connectMuted, forKey: "mediaConnectMuted") } }
    /// the main monitor shows this clip (Premiere-style source monitor) instead of the timeline; keys act on it
    @Published var sourceActive = false
    var panelRect: CGRect = .zero        // window points, top-left origin
    var viewerRect: CGRect = .zero
    func pointer(in r: CGRect) -> Bool {
        guard let w = NSApp.keyWindow, let cv = w.contentView else { return false }
        let p = w.mouseLocationOutsideOfEventStream
        return r.contains(CGPoint(x: p.x, y: cv.bounds.height - p.y))
    }
    func openSource(play: Bool) {
        guard let s = selected, previewPath != nil, MediaLibrary.kind(previewPath!) != "image" else { return }
        _ = s; sourceActive = true
        if play { player.play() }
    }
    func leaveSource() { player.pause(); sourceActive = false }
    let player = AVPlayer()
    @Published var previewPath: String?

    func preview(_ path: String?) {
        guard path != previewPath else { return }
        previewPath = path; markIn = nil; markOut = nil
        player.pause()
        if let p = path, MediaLibrary.kind(p) != "image" { player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: p))) }
        else { player.replaceCurrentItem(with: nil) }
    }
    var previewTime: Double { let t = player.currentTime().seconds; return t.isFinite ? t : 0 }
    func seekPreview(_ t: Double) { player.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    /// what is on screen, in order, and how many tiles fit in a row (arrow keys move through these)
    var order: [MediaEntry] = []
    var columns = 1
    func step(_ d: Int) {
        guard !order.isEmpty else { return }
        let i = order.firstIndex { $0.id == selected } ?? (d > 0 ? -1 : order.count)
        let n = max(0, min(order.count - 1, i + d))
        select(order[n])
    }
    func select(_ e: MediaEntry) {
        selected = e.id
        if let m = e.media { preview(m.path); if case .range(let r, _) = e { seekPreview(r.start) } }
    }
}

/// the preview picture (plain player layer; Apple's SwiftUI VideoPlayer crashes in this kind of app build)
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    final class V: NSView {
        override func makeBackingLayer() -> CALayer { let l = AVPlayerLayer(); l.videoGravity = .resizeAspect; return l }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.wantsLayer = true; v.playerLayer.player = player; return v }
    func updateNSView(_ v: V, context: Context) { if v.playerLayer.player !== player { v.playerLayer.player = player } }
}

struct MediaPanel: View {
    @ObservedObject var editor: Editor
    @ObservedObject var lib = MediaLibrary.shared
    @ObservedObject var st = MediaState.shared
    @State private var tick = 0
    @AppStorage("mediaListView") private var listView = false
    @AppStorage("brollGainDb") private var brollGainDb = 0.0

    // worked out again only when the timeline or the library really changed (not on every redraw)
    nonisolated(unsafe) static var usedMemo: (key: String, value: [String: [ClosedRange<Double>]])?
    nonisolated(unsafe) static var entriesMemo: [String: [MediaEntry]] = [:]
    var usedKey: String { "\(editor.revision)|\(editor.project.assets.count)|\(editor.project.clips.count)|\(editor.project.overlays?.count ?? 0)|\(editor.project.audioClips?.count ?? 0)|\(editor.projectURL?.path ?? "")" }
    var used: [String: [ClosedRange<Double>]] {
        let k = usedKey
        if let m = Self.usedMemo, m.key == k { return m.value }
        let v = MediaLibrary.used(in: editor.project, base: editor.base); Self.usedMemo = (k, v); return v
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .animation(.easeInOut(duration: 0.18), value: st.path)
            Divider()
            grid
                .id(st.path)
                .transition(.opacity.combined(with: .offset(x: 10)))
        }
        .background(Color(white: 0.11))
        .background(GeometryReader { g in Color.clear.onAppear { st.panelRect = g.frame(in: .global) }.onChange(of: g.frame(in: .global)) { _, r in st.panelRect = r } })
        // the search box must not take the keyboard when the window opens (Space, J/K/L... belong to the editor)
        .onAppear {
            // AppKit puts the keyboard in the first text box when the window opens; take it back (also each time the window
            // becomes active), unless you clicked into the search box yourself
            func release() { for w in NSApp.windows where w.firstResponder is NSText && !MediaState.searchClicked { w.makeFirstResponder(nil) } }
            for d in [0.1, 0.5, 1.5] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { release() } }
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { release() } } }
        }
        .onReceive(NotificationCenter.default.publisher(for: Thumbs.readyNote).throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)) { _ in tick += 1 }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for pr in providers {
                _ = pr.loadObject(ofClass: URL.self) { u, _ in if let u { Task { @MainActor in await MediaLibrary.shared.add(paths: [u.standardizedFileURL.path]) } } }
            }
            return true
        }
    }

    // MARK: header: title, add, filter, path bar, search

    var filtered: Bool { st.show != "all" || st.type != "all" }
    var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("Media").font(.system(size: 13, weight: .semibold))
                if lib.scanning > 0 { ProgressView().controlSize(.mini); Text("Reading \(lib.scanning)…").font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer()
                Picker("", selection: $listView) {
                    Image(systemName: "square.grid.2x2").help("Thumbnail view: hover over a clip to skim it").tag(false)
                    Image(systemName: "list.bullet").help("List view").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 64).controlSize(.small)
                Menu {
                    Button("Add folder…") { pick(folders: true) }
                    Button("Add files…") { pick(folders: false) }
                    Divider()
                    Button("New collection…") { if let n = ask("New collection", "") { _ = lib.newCollection(n) } }
                } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Add media or a collection")
                Menu {
                    Picker("Show", selection: $st.show) {
                        Text("Everything").tag("all"); Text("Favourites").tag("favourites"); Text("Not used in this project").tag("unused"); Text("Rejected").tag("rejected")
                    }
                    Picker("Type", selection: $st.type) {
                        Text("All types").tag("all"); Text("Video").tag("video"); Text("Audio").tag("audio"); Text("Images").tag("image"); Text("HDR (HLG / PQ)").tag("hdr")
                    }
                    Picker("Sort by", selection: $st.sort) { Text("Name").tag("name"); Text("Date recorded").tag("date"); Text("Length").tag("length"); Text("Recently added").tag("added") }
                    Divider()
                    Toggle("Mute sound of connected clips (Q)", isOn: $st.connectMuted)
                    Picker("Sound level of clips on V2 and up", selection: $brollGainDb) {
                        Text("0 dB (as recorded)").tag(0.0); Text("−6 dB").tag(-6.0); Text("−12 dB").tag(-12.0); Text("−18 dB").tag(-18.0); Text("−24 dB").tag(-24.0)
                    }
                    if filtered { Divider(); Button("Clear filters") { st.show = "all"; st.type = "all" } }
                } label: { Image(systemName: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Filter, sort and options")
            }
            // inside a folder / collection / Projects: a clear back button (to the level above) and where you are
            if !st.path.isEmpty {
                HStack(spacing: 8) {
                    BackButton(title: st.path.count > 1 ? placeName(st.path[st.path.count - 2]) : "Media") { goBack() }
                    Spacer(minLength: 4)
                    Image(systemName: placeIcon(st.path.last!)).font(.system(size: 12)).symbolRenderingMode(.hierarchical).foregroundStyle(Color(red: 0.42, green: 0.66, blue: 1.0))
                    Text(placeName(st.path.last!)).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    if st.path.count > 1 {
                        Menu {
                            Button("Media") { goTo(0) }
                            ForEach(Array(st.path.dropLast().enumerated()), id: \.offset) { i, p in Button(placeName(p)) { goTo(i + 1) } }
                        } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Jump to a level above")
                    }
                }
                .transition(.opacity)
            }
            // quick filters, always one click away
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    filterChip("All", on: st.type == "all" && st.show == "all") { st.type = "all"; st.show = "all" }
                    filterChip("Video", icon: "film", on: st.type == "video") { st.type = st.type == "video" ? "all" : "video" }
                    filterChip("Audio", icon: "waveform", on: st.type == "audio") { st.type = st.type == "audio" ? "all" : "audio" }
                    filterChip("Images", icon: "photo", on: st.type == "image") { st.type = st.type == "image" ? "all" : "image" }
                    filterChip("Favourites", icon: "star.fill", on: st.show == "favourites") { st.show = st.show == "favourites" ? "all" : "favourites" }
                    filterChip("Unused", icon: "circle.dashed", on: st.show == "unused") { st.show = st.show == "unused" ? "all" : "unused" }
                }.padding(.horizontal, 8)
            }.padding(.bottom, 2)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("Search everything", text: $st.search).textFieldStyle(.plain).font(.system(size: 12))
                    .simultaneousGesture(TapGesture().onEnded { MediaState.searchClicked = true })
                    .onSubmit { MediaState.searchClicked = false; NSApp.keyWindow?.makeFirstResponder(nil) }
                if !st.search.isEmpty { Button { st.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).font(.system(size: 10)) }
            }.padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(white: 0.15)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.07), lineWidth: 0.5))
        }.padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 6)
    }
    var filterName: String {
        [["favourites": "Favourites", "unused": "Not used", "rejected": "Rejected"][st.show], ["video": "Video", "audio": "Audio", "image": "Images", "hdr": "HDR"][st.type]]
            .compactMap { $0 }.joined(separator: ", ")
    }
    func filterChip(_ t: String, icon: String? = nil, on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.easeOut(duration: 0.15)) { act() } }) {
            HStack(spacing: 4) {
                if let i = icon { Image(systemName: i).font(.system(size: 9)) }
                Text(t).font(.system(size: 11, weight: on ? .semibold : .regular))
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(on ? Brand.accent : Color.white.opacity(0.07)))
            .foregroundStyle(on ? Brand.onAccent : Color.primary)
        }.buttonStyle(.plain)
    }
    func goBack() { withAnimation(.easeInOut(duration: 0.18)) { _ = st.path.popLast(); st.selected = nil } }
    func goTo(_ level: Int) { withAnimation(.easeInOut(duration: 0.18)) { st.path = Array(st.path.prefix(level)); st.selected = nil } }
    func placeIcon(_ p: MediaPlace) -> String {
        switch p { case .folder: return "folder.fill"; case .collection: return "rectangle.stack.fill"; case .projects: return "film.stack" }
    }
    func crumb(_ s: String, level: Int) -> some View {
        Button { st.path = Array(st.path.prefix(level)) } label: {
            Text(s).font(.system(size: 11, weight: level == st.path.count ? .semibold : .regular)).lineLimit(1)
                .foregroundStyle(level == st.path.count ? Color.primary : Color.secondary)
        }.buttonStyle(.borderless)
    }
    func placeName(_ p: MediaPlace) -> String {
        switch p { case .folder(let f): return (f as NSString).lastPathComponent
        case .collection(let c): return lib.collections.first { $0.id == c }?.name ?? "Collection"
        case .projects: return "Projects" }
    }

    // MARK: what the grid shows

    var entries: [MediaEntry] { entries(in: st.path.last) }
    /// what a place holds (the current one, or a folder opened in place with its arrow in list view)
    func entries(in place: MediaPlace?) -> [MediaEntry] {
        let key = "\(lib.version)|\(usedKey)|\(String(describing: place))|\(st.path.last.map { String(describing: $0) } ?? "")|\(st.search)|\(st.show)|\(st.type)|\(st.sort)|\(filtered)"
        if let m = Self.entriesMemo[key] { return m }
        let r = computeEntries(in: place)
        if Self.entriesMemo.count > 50 { Self.entriesMemo.removeAll() }
        Self.entriesMemo[key] = r
        return r
    }
    func computeEntries(in place: MediaPlace?) -> [MediaEntry] {
        let q = place == st.path.last ? st.search.lowercased().trimmingCharacters(in: .whitespaces) : "".lowercased().trimmingCharacters(in: .whitespaces)
        let u = used
        let byPath = Dictionary(lib.items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        func passes(_ i: LibItem, rating: Int) -> Bool {
            switch st.show {
            case "favourites": if rating <= 0 { return false }
            case "rejected": if rating >= 0 { return false }
            case "unused": if !(u[i.path] ?? []).isEmpty || rating < 0 { return false }
            default: if rating < 0 { return false }
            }
            switch st.type {
            case "video": return i.kind == "video"
            case "audio": return i.kind == "audio"
            case "image": return i.kind == "image"
            case "hdr": return i.hdr != nil
            default: return true
            }
        }
        func matches(_ f: [String?]) -> Bool { q.isEmpty || f.contains { ($0 ?? "").lowercased().contains(q) } }
        // the files this place holds: everything at the top (search / filter) or inside a folder / collection
        let flat = place == nil && (!q.isEmpty || filtered)
        func inPlace(_ i: LibItem) -> Bool {
            switch place {
            case .folder(let f)?: return (i.path as NSString).deletingLastPathComponent == f || (flat && i.path.hasPrefix(f + "/"))
            case .collection(let c)?: return lib.collections.first { $0.id == c }?.members.contains(i.path) ?? false
            case nil: return flat || !lib.folders.contains { i.path.hasPrefix($0.path + "/") }    // top: loose files only
            case .projects?: return false
            }
        }
        var out: [MediaEntry] = []
        // folders and collections first
        if q.isEmpty {
            switch place {
            case nil where !filtered:
                for f in lib.folders { out.append(.folder(f.path, lib.items.filter { $0.path.hasPrefix(f.path + "/") }.count)) }
                for c in lib.collections { out.append(.collection(c)) }
            case .folder(let f)?:
                // sub-folders that hold media
                var subs: [String: Int] = [:]
                for i in lib.items where i.path.hasPrefix(f + "/") {
                    let rest = i.path.dropFirst(f.count + 1).split(separator: "/")
                    if rest.count > 1 { subs[f + "/" + rest[0], default: 0] += 1 }
                }
                for (p, n) in subs.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) { out.append(.folder(p, n)) }
            default: break
            }
        }
        var files: [MediaEntry] = []
        for i in lib.items where inPlace(i) && passes(i, rating: i.rating) && matches([i.name, i.note, i.camera, i.keywords.joined(separator: " "), i.hdr]) {
            files.append(.item(i))
        }
        // marked ranges show as their own tiles
        for r in lib.ranges {
            guard let i = byPath[r.path] else { continue }
            let here: Bool
            if case .collection(let c)? = place { here = lib.collections.first { $0.id == c }?.members.contains(r.id) ?? false } else { here = inPlace(i) }
            if here && passes(i, rating: r.rating) && matches([r.name, r.note, r.keywords.joined(separator: " "), i.name]) { files.append(.range(r, i)) }
        }
        switch st.sort {
        case "date": files.sort { ($0.media?.date ?? .distantPast) > ($1.media?.date ?? .distantPast) }
        case "length": files.sort { ($0.span.1 - $0.span.0) > ($1.span.1 - $1.span.0) }
        case "added": files.sort { ($0.media?.added ?? .distantPast) > ($1.media?.added ?? .distantPast) }
        default:
            // by name, each range right after its clip
            files.sort { a, b in
                let ka = (a.media?.name ?? ""), kb = (b.media?.name ?? "")
                if ka != kb { return ka.localizedStandardCompare(kb) == .orderedAscending }
                return a.span.0 < b.span.0 || (a.span.0 == b.span.0 && { if case .item = a { return true }; return false }())
            }
        }
        return out + files
    }
    var selectedEntry: MediaEntry? {
        guard let s = st.selected else { return nil }
        if let i = lib.items.first(where: { $0.path == s }) { return .item(i) }
        if let r = lib.ranges.first(where: { $0.id == s }), let i = lib.item(r.path) { return .range(r, i) }
        return nil
    }

    var grid: some View {
        let es = st.path.last == .projects ? [] : entries, u = used
        let atTop = st.path.isEmpty && st.search.isEmpty
        return VStack(spacing: 0) {
            if st.path.last == .projects {
                ProjectsBrowser(editor: editor, listView: listView)
            } else if lib.items.isEmpty && lib.collections.isEmpty {
                if atTop { projectsTile.frame(width: listView ? nil : st.tile).padding(8) }
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Drop folders or files here, or use + to add them.\nFiles stay where they are; nothing is copied.").font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Add folder…") { pick(folders: true) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if es.isEmpty {
                Text(st.search.isEmpty ? (filtered ? "Nothing matches the filter" : "Empty") : "No matches").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    if listView {
                        LazyVStack(spacing: 1) {
                            if atTop {
                                projectsTile
                                if st.expanded.contains("projects") { ProjectsBrowser(editor: editor, listView: true, inline: true).padding(.leading, 18) }
                            }
                            ForEach(es) { e in treeRow(e, u, depth: 0) }
                        }.padding(.vertical, 4)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: st.tile, maximum: st.tile * 1.6), spacing: 8)], spacing: 10) {
                            if atTop { projectsTile }
                            ForEach(es) { e in tile(e, u) }
                        }.padding(8)
                    }
                }
                .modifier(MediaNav(st: st, es: es, listView: listView, proxy: proxy))
                }
            }
            HStack(spacing: 6) {
                Text("\(es.count) item\(es.count == 1 ? "" : "s")").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if !listView {
                    Image(systemName: "square.grid.3x3").font(.system(size: 9)).foregroundStyle(.secondary)
                    Slider(value: $st.tile, in: 90...260).frame(width: 80).controlSize(.mini)
                }
            }.padding(.horizontal, 8).padding(.vertical, 3)
        }
    }

    /// a row and, when its arrow is open, everything inside it (folders inside folders too)
    func treeRow(_ e: MediaEntry, _ u: [String: [ClosedRange<Double>]], depth: Int) -> AnyView {
        AnyView(VStack(spacing: 1) {
            tile(e, u).padding(.leading, CGFloat(depth) * 18)
            if let k = expandKey(e), st.expanded.contains(k) {
                let kids = entries(in: k.hasPrefix("c:") ? .collection(String(k.dropFirst(2))) : .folder(String(k.dropFirst(2))))
                ForEach(kids) { c in treeRow(c, u, depth: depth + 1) }
                if kids.isEmpty { Text("Empty").font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, CGFloat(depth + 1) * 18 + 70).frame(maxWidth: .infinity, minHeight: 22, alignment: .leading) }
            }
        })
    }
    func expandKey(_ e: MediaEntry) -> String? {
        switch e { case .folder(let p, _): return "f:" + p; case .collection(let c): return "c:" + c.id; default: return nil }
    }
    func toggle(_ k: String) { if st.expanded.contains(k) { st.expanded.remove(k) } else { st.expanded.insert(k) } }

    /// "Projects" at the top of the library: every project in this project's folder
    var projectsTile: some View {
        let n = editor.projectURL.map { ProjectFile.list(in: $0.deletingLastPathComponent()).count } ?? 0
        return PlaceTile(title: "Projects", icon: "film.stack", count: n, row: listView, open: st.expanded.contains("projects"), toggle: { toggle("projects") })
            .onTapGesture(count: 2) { withAnimation(.easeInOut(duration: 0.18)) { st.path = [.projects]; st.selected = nil } }
            .contextMenu { Button("Open") { st.path = [.projects] }; Button("New project…") { NotificationCenter.default.post(name: .newProject, object: nil) } }
    }

    @ViewBuilder func tile(_ e: MediaEntry, _ u: [String: [ClosedRange<Double>]]) -> some View {
        switch e {
        case .folder(let p, let n):
            PlaceTile(title: e.title, icon: lib.folders.first { $0.path == p }?.watched == true ? "folder.fill.badge.gearshape" : "folder.fill", count: n, row: listView,
                      open: st.expanded.contains("f:" + p), toggle: { toggle("f:" + p) })
                .onTapGesture(count: 2) { withAnimation(.easeInOut(duration: 0.18)) { st.path.append(.folder(p)); st.selected = nil } }
                .contextMenu {
                    Button("Open") { st.path.append(.folder(p)) }
                    if let f = lib.folders.first(where: { $0.path == p }) {
                        Button(f.watched ? "Stop watching for new files" : "Watch for new files") { lib.setWatched(p, !f.watched) }
                        Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: p) }
                        Divider()
                        Button("Remove from library (files stay on disk)") { lib.removeFolder(p) }
                    } else { Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: p) } }
                }
        case .collection(let c):
            PlaceTile(title: c.name, icon: "rectangle.stack.fill", count: c.members.count, row: listView, open: st.expanded.contains("c:" + c.id), toggle: { toggle("c:" + c.id) })
                .onTapGesture(count: 2) { withAnimation(.easeInOut(duration: 0.18)) { st.path.append(.collection(c.id)); st.selected = nil } }
                .onDrop(of: [.text], isTargeted: nil) { prs in
                    for pr in prs { _ = pr.loadObject(ofClass: NSString.self) { s, _ in
                        if let s = s as? String { Task { @MainActor in MediaLibrary.shared.addToCollection(c.id, [s]) } } } }
                    return true
                }
                .contextMenu {
                    Button("Open") { st.path.append(.collection(c.id)) }
                    Button("Rename…") { if let n = ask("Rename collection", c.name) { lib.renameCollection(c.id, n) } }
                    Button("Delete collection (media stays)") { lib.deleteCollection(c.id) }
                }
        default:
            let m = e.media!
            Group {
                if listView { MediaRow(entry: e, used: u[m.path] ?? [], selected: st.selected == e.id, offline: lib.offline.contains(m.path), tick: tick,
                                       markIn: st.selected == e.id ? st.markIn : nil, markOut: st.selected == e.id ? st.markOut : nil) }
                else { MediaTile(entry: e, used: u[m.path] ?? [], selected: st.selected == e.id, offline: lib.offline.contains(m.path), tick: tick,
                                 markIn: st.selected == e.id ? st.markIn : nil, markOut: st.selected == e.id ? st.markOut : nil) }
            }
                .onTapGesture(count: 2) { NSApp.keyWindow?.makeFirstResponder(nil); st.select(e); st.openSource(play: true) }
                .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil); st.select(e); if st.sourceActive { st.openSource(play: false) } }
                .onDrag {
                    // onto the timeline: the file; onto a collection tile: this clip or range
                    let p = NSItemProvider(object: URL(fileURLWithPath: m.path) as NSURL)
                    p.registerObject(e.id as NSString, visibility: .ownProcess)
                    return p
                }
                .contextMenu { tileMenu(e, m) }
        }
    }

    @ViewBuilder func tileMenu(_ e: MediaEntry, _ m: LibItem) -> some View {
        let id = e.id
        Button("Connect to timeline (Q)") { st.select(e); MediaActions.add(editor, .connect) }
        Button("Insert at playhead (W)") { st.select(e); MediaActions.add(editor, .insert) }
        Button("Append to end (E)") { st.select(e); MediaActions.add(editor, .append) }
        if m.kind == "video" && m.hasAudio { Button("Add sound only") { st.select(e); MediaActions.add(editor, .soundOnly) } }
        Divider()
        Button(e.rating > 0 ? "Remove favourite" : "Favourite (F)") { MediaActions.rate(id, e.rating > 0 ? 0 : 1) }
        Button(e.rating < 0 ? "Unreject" : "Reject (⌫)") { MediaActions.rate(id, e.rating < 0 ? 0 : -1) }
        Button("Keywords and note…") { editMeta(e) }
        if case .range(let r, _) = e { Button("Rename range…") { if let n = ask("Range name", r.name) { lib.updateRange(r.id) { $0.name = n } } } }
        if !lib.collections.isEmpty {
            Menu("Add to collection") { ForEach(lib.collections) { c in Button(c.name) { lib.addToCollection(c.id, [id]) } } }
        }
        if case .collection(let c)? = st.path.last { Button("Remove from this collection") { lib.removeFromCollection(c, [id]) } }
        Divider()
        if lib.offline.contains(m.path) { Button("Locate file…") { relink(m.path) } }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: m.path)]) }
        if case .range(let r, _) = e { Button("Delete range") { lib.deleteRange(r.id); if st.selected == r.id { st.selected = nil } } }
        else { Button("Remove from library (file stays on disk)") { lib.remove(paths: [m.path]); if st.selected == id { st.selected = nil; st.preview(nil) } } }
    }

    // MARK: small dialogs

    func ask(_ title: String, _ value: String) -> String? {
        let a = NSAlert(); a.messageText = title; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); f.stringValue = value; a.accessoryView = f
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let s = f.stringValue.trimmingCharacters(in: .whitespaces); return s.isEmpty ? nil : s
    }
    func editMeta(_ e: MediaEntry) {
        var kw: [String] = [], note = ""
        switch e { case .item(let i): kw = i.keywords; note = i.note ?? ""; case .range(let r, _): kw = r.keywords; note = r.note ?? ""; default: return }
        let a = NSAlert(); a.messageText = "Keywords and note"; a.informativeText = e.title
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        let v = NSStackView(frame: NSRect(x: 0, y: 0, width: 300, height: 56)); v.orientation = .vertical; v.alignment = .leading; v.spacing = 8
        let k = NSTextField(); k.placeholderString = "Keywords, comma separated"; k.stringValue = kw.joined(separator: ", ")
        let n = NSTextField(); n.placeholderString = "Note"; n.stringValue = note
        for f in [k, n] { f.translatesAutoresizingMaskIntoConstraints = false; v.addArrangedSubview(f); f.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        a.accessoryView = v; a.window.initialFirstResponder = k
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let keys = k.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let nt = n.stringValue.trimmingCharacters(in: .whitespaces)
        switch e {
        case .item(let i): lib.update(i.path) { $0.keywords = keys; $0.note = nt.isEmpty ? nil : nt }
        case .range(let r, _): lib.updateRange(r.id) { $0.keywords = keys; $0.note = nt.isEmpty ? nil : nt }
        default: break
        }
    }
    func pick(folders: Bool) {
        let op = NSOpenPanel()
        op.canChooseDirectories = folders; op.canChooseFiles = !folders; op.allowsMultipleSelection = true
        if !folders { op.allowedContentTypes = [.movie, .audio, .image] }
        op.prompt = "Add to library"
        guard op.runModal() == .OK else { return }
        let paths = op.urls.map { $0.standardizedFileURL.path }
        Task { await lib.add(paths: paths) }
    }
    func relink(_ old: String) {
        let op = NSOpenPanel(); op.canChooseFiles = true; op.message = "Where is \((old as NSString).lastPathComponent) now?"
        guard op.runModal() == .OK, let u = op.url else { return }
        Task { await lib.relink(old, to: u.standardizedFileURL.path); if st.selected == old { st.selected = u.standardizedFileURL.path } }
    }
}

/// a folder or collection tile
struct PlaceTile: View {
    let title: String, icon: String, count: Int
    var row = false
    var open = false
    var toggle: (() -> Void)? = nil
    @State private var hover = false
    var body: some View {
        if row {
            HStack(spacing: 6) {
                // Finder-style arrow: show what's inside right here
                Button { withAnimation(.easeOut(duration: 0.12)) { toggle?() } } label: {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 14, height: 26).contentShape(Rectangle())
                }.buttonStyle(.plain).opacity(toggle == nil ? 0 : 1).help(open ? "Close" : "Show what's inside")
                Image(systemName: icon).font(.system(size: 15)).symbolRenderingMode(.hierarchical).foregroundStyle(Color(red: 0.42, green: 0.66, blue: 1.0)).frame(width: 22)
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                if count > 0 {
                    Text("\(count)").font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.white.opacity(0.07)))
                }
            }.padding(.horizontal, 8).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.white.opacity(0.05) : Color.clear))
            .padding(.horizontal, 6)
            .contentShape(Rectangle()).onHover { hover = $0 }.help("Click the arrow to show what's inside, double-click to go into it")
        } else { tileBody }
    }
    var tileBody: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack {
                LinearGradient(colors: [Color(white: hover ? 0.2 : 0.17), Color(white: hover ? 0.15 : 0.12)], startPoint: .top, endPoint: .bottom)
                Image(systemName: icon).font(.system(size: 30)).symbolRenderingMode(.hierarchical).foregroundStyle(Color(red: 0.42, green: 0.66, blue: 1.0))
                if count > 0 {
                    Text("\(count)").font(.system(size: 9, weight: .semibold).monospacedDigit()).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.black.opacity(0.45))).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(5)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(hover ? 0.15 : 0.07)))
            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle()).onHover { hover = $0 }
        .help("Double-click to open")
    }
}

// MARK: - tile

struct MediaTile: View {
    let entry: MediaEntry
    let used: [ClosedRange<Double>]
    let selected: Bool
    let offline: Bool
    let tick: Int
    var markIn: Double? = nil
    var markOut: Double? = nil
    @State private var skim: Double?        // 0...1 across the tile while the pointer is over it

    var body: some View {
        let it = entry.media!, (a, b) = entry.span
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .bottomLeading) {
                Color.black
                picture(it, a, b)
                if let s = skim, it.kind != "image" {
                    GeometryReader { g in Rectangle().fill(Color.red).frame(width: 1.5).offset(x: g.size.width * s) }
                }
                // the part marked with I / O (yellow box, outside dimmed), like Final Cut's browser
                if markIn != nil || markOut != nil, b > a {
                    GeometryReader { g in
                        let x0 = max(0, min(1, ((markIn ?? a) - a) / (b - a))), x1 = max(0, min(1, ((markOut ?? b) - a) / (b - a)))
                        let w = g.size.width
                        ZStack(alignment: .topLeading) {
                            Rectangle().fill(Color.black.opacity(0.45)).frame(width: w * x0)
                            Rectangle().fill(Color.black.opacity(0.45)).frame(width: w * (1 - x1)).offset(x: w * x1)
                            Rectangle().stroke(Brand.accent, lineWidth: 2).frame(width: max(2, w * (x1 - x0)), height: g.size.height).offset(x: w * x0)
                        }
                    }.allowsHitTesting(false)
                }
                // used in this project (orange), across the tile's span
                GeometryReader { g in
                    ForEach(Array(used.enumerated()), id: \.offset) { _, r in
                        let x0 = max(0, (r.lowerBound - a) / max(b - a, 0.001)), x1 = min(1, (r.upperBound - a) / max(b - a, 0.001))
                        if x1 > x0 { Rectangle().fill(Brand.accent).frame(width: max(2, g.size.width * (x1 - x0)), height: 3).offset(x: g.size.width * x0, y: g.size.height - 3) }
                    }
                }
                HStack(spacing: 3) {
                    if entry.rating > 0 { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                    if entry.rating < 0 { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
                    if case .range = entry { Image(systemName: "scissors").foregroundStyle(.white) }
                    if let h = it.hdr { Text(h).font(.system(size: 8, weight: .bold)).padding(.horizontal, 3).background(Color.purple.opacity(0.8)).clipShape(RoundedRectangle(cornerRadius: 2)) }
                    if it.kind == "video" && !it.hasAudio { Image(systemName: "speaker.slash.fill") }
                    Spacer()
                    if it.kind != "image" { Text(Self.dur(b - a)).font(.system(size: 9, weight: .medium).monospacedDigit()).padding(.horizontal, 3).background(Color.black.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 2)) }
                }.font(.system(size: 9)).padding(4).frame(maxHeight: .infinity, alignment: .top)
                if offline {
                    Text("Offline").font(.system(size: 10, weight: .bold)).padding(4).background(Color.red.opacity(0.85)).clipShape(RoundedRectangle(cornerRadius: 3))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.yellow : Color.white.opacity(0.08), lineWidth: selected ? 2 : 1))
            .onContinuousHover { ph in
                switch ph {
                case .active(let p):
                    let f = max(0, min(1, p.x / max(1, tileWidth))); if abs(f - (skim ?? -1)) > 0.01 { skim = f }
                    MediaState.shared.hoverEntry = entry; MediaState.shared.hoverTime = a + (b - a) * f
                case .ended:
                    skim = nil
                    if MediaState.shared.hoverEntry?.id == entry.id { MediaState.shared.hoverEntry = nil; MediaState.shared.hoverTime = nil }
                }
            }
            .background(GeometryReader { g in Color.clear.onAppear { tileWidth = g.size.width }.onChange(of: g.size.width) { _, w in tileWidth = w } })
            Text(entry.title).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
        }
        .contentShape(Rectangle())
        .help(info(it))
    }
    @State private var tileWidth: CGFloat = 130

    @ViewBuilder func picture(_ it: LibItem, _ a: Double, _ b: Double) -> some View {
        let _ = tick
        switch it.kind {
        case "image":
            if let im = StillThumbs.image(it.path) { Image(decorative: im, scale: 1).resizable().aspectRatio(contentMode: .fit) }
        case "audio":
            WaveThumb(path: it.path, a: a, b: b, tick: tick).padding(.vertical, 6)
        default:
            // 24 skim steps per tile, so the thumbnails are shared and quick
            let f = skim ?? 0.3
            let t = a + (b - a) * (Double(Int(f * 23.999)) + 0.5) / 24
            if let im = Thumbs.shared.image(it.path, at: (t * 10).rounded() / 10) ?? (skim != nil ? Thumbs.shared.image(it.path, at: ((a + (b - a) * 0.3) * 10).rounded() / 10) : nil) {
                Image(decorative: im, scale: 1).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.animation(.easeOut(duration: 0.25)))
            }
        }
    }
    func info(_ it: LibItem) -> String {
        var s = [it.name]
        if let w = it.width, let h = it.height { s.append("\(w) × \(h)" + (it.fps.map { String(format: "  %.3g fps", $0) } ?? "")) }
        if let h = it.hdr { s.append("HDR: \(h)") }
        if let c = it.camera { s.append("Camera: \(c)") }
        if let d = it.date { s.append("Recorded: " + d.formatted(date: .abbreviated, time: .shortened)) }
        if let n = it.note, !n.isEmpty { s.append("Note: \(n)") }
        if !it.keywords.isEmpty { s.append("Keywords: " + it.keywords.joined(separator: ", ")) }
        s.append(it.path)
        return s.joined(separator: "\n")
    }
    static func dur(_ d: Double) -> String {
        let s = Int(d.rounded()); return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct WaveThumb: View {
    let path: String, a: Double, b: Double, tick: Int
    var body: some View {
        Canvas { ctx, size in
            _ = tick
            guard let pk = Waveforms.shared.peaks(path) else { Waveforms.shared.request(path); return }
            let n = Int(size.width / 2)
            var p = Path()
            for i in 0..<max(1, n) {
                let t0 = a + (b - a) * Double(i) / Double(n), t1 = a + (b - a) * Double(i + 1) / Double(n)
                let i0 = Int(t0 * Waveforms.rate), i1 = max(i0 + 1, Int(t1 * Waveforms.rate))
                var m: Float = 0; var k = i0; while k < min(i1, pk.count) { m = max(m, pk[k]); k += 1 }
                let h = Double(m) * size.height
                p.addRect(CGRect(x: Double(i) * 2, y: (size.height - h) / 2, width: 1.4, height: max(1, h)))
            }
            ctx.fill(p, with: .color(Color(red: 0.45, green: 0.85, blue: 0.6)))
        }
    }
}

/// small thumbnails of still images (made once, kept in memory)
@MainActor enum StillThumbs {
    static var cache: [String: CGImage] = [:]
    static var busy: Set<String> = []
    static func image(_ path: String) -> CGImage? {
        if let c = cache[path] { return c }
        if busy.insert(path).inserted {
            Task.detached(priority: .utility) {
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 320, kCGImageSourceCreateThumbnailWithTransform: true]
                let im = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil).flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, opts as CFDictionary) }
                await MainActor.run { if let im { cache[path] = im }; NotificationCenter.default.post(name: Thumbs.readyNote, object: nil) }
            }
        }
        return nil
    }
}


// MARK: - selected clip bar (one slim strip under the grid)

// MARK: - actions (buttons and keys share these)

@MainActor enum MediaActions {
    enum Kind { case connect, insert, append, soundOnly }
    static var st: MediaState { .shared }
    static var lib: MediaLibrary { .shared }

    static func current() -> (LibItem, Double, Double)? {
        guard let s = st.selected else { return nil }
        if let r = lib.ranges.first(where: { $0.id == s }), let i = lib.item(r.path) {
            if st.markIn != nil || st.markOut != nil { return (i, st.markIn ?? r.start, st.markOut ?? r.end) }
            return (i, r.start, r.end)
        }
        guard let i = lib.item(s) else { return nil }
        let a = st.markIn ?? 0, b = st.markOut ?? i.duration
        return (i, min(a, b), max(a, b))
    }

    static func add(_ ed: Editor, _ k: Kind) {
        guard let (i, a, b) = current() else { ed.lastMessage = "Select something in the media panel first"; return }
        if MediaLibrary.shared.offline.contains(i.path) { ed.lastMessage = "\(i.name) is offline - locate the file first"; return }
        let at = ed.playhead, end = ed.project.totalDuration
        var c: [String: Any]
        switch i.kind {
        case "image":
            c = ["cmd": "add_graphic", "path": i.path, "at": k == .append ? end : at]
        case "audio":
            c = ["cmd": "add_audio", "path": i.path, "at": k == .append ? end : at, "source_in": a, "dur": b - a]
        default:
            switch k {
            case .connect: c = ["cmd": "add_clip", "path": i.path, "source_in": a, "dur": b - a, "offset": at, "lane": 1, "mute": st.connectMuted, "gain_db": UserDefaults.standard.double(forKey: "brollGainDb")]
            case .insert: c = ["cmd": "add_clip", "path": i.path, "source_in": a, "dur": b - a, "offset": at, "insert": true]
            case .append: c = ["cmd": "add_clip", "path": i.path, "source_in": a, "dur": b - a, "offset": end]
            case .soundOnly: c = ["cmd": "add_audio", "path": i.path, "at": at, "source_in": a, "dur": b - a]
            }
        }
        Task { _ = await ed.handle(c) }
    }

    /// where I / O mark: the skim point of the tile under the pointer (selecting that tile), else the monitor's position
    static func markTime() -> Double {
        if !st.sourceActive, let e = st.hoverEntry, let t = st.hoverTime {
            if st.selected != e.id { st.select(e) }
            if case .range(let r, _) = e { return max(r.start, min(r.end, t)) }
            return t
        }
        return st.previewTime
    }
    static func markIn() { st.markIn = markTime(); if let o = st.markOut, o <= st.markIn! { st.markOut = nil } }
    static func markOut() { st.markOut = markTime(); if let i = st.markIn, i >= st.markOut! { st.markIn = nil } }
    static func saveRange() {
        guard let (i, a, b) = current(), b - a > 0.05 else { return }
        let r = lib.addRange(path: i.path, start: a, end: b)
        st.markIn = nil; st.markOut = nil; st.selected = r.id
    }
    static func rate(_ id: String, _ v: Int) {
        if lib.item(id) != nil { lib.update(id) { $0.rating = v } } else { lib.updateRange(id) { $0.rating = v } }
    }

    /// keys while the pointer is over the media panel; true = handled
    static func key(_ e: NSEvent, _ ed: Editor) -> Bool {
        let f = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let ch = (e.charactersIgnoringModifiers ?? "").lowercased()
        // ⌘[ or ⌘↑: back to the level above (Finder)
        if f == [.command], (ch == "[" || e.keyCode == 126), !st.sourceActive, !st.path.isEmpty {
            withAnimation(.easeInOut(duration: 0.18)) { _ = st.path.popLast(); st.selected = nil }; return true
        }
        guard f.isEmpty else { return false }
        if e.keyCode == 53 { st.leaveSource(); return true }   // escape: back to the timeline
        if e.keyCode == 49 {   // space: the media clip if one is loaded, otherwise the timeline as usual
            guard st.player.currentItem != nil, st.selected != nil || st.sourceActive else { return false }
            if st.player.rate == 0 { st.openSource(play: true) } else { st.player.pause() }; return true
        }
        // arrows: move through the clips (up / down = a row in the grid)
        if [123, 124, 125, 126].contains(e.keyCode), !st.sourceActive {
            let row = st.columns
            switch e.keyCode { case 123: st.step(-1); case 124: st.step(1); case 125: st.step(row); default: st.step(-row) }
            return true
        }
        if e.keyCode == 36, let s = st.selected, s.hasPrefix("/"), FileManager.default.fileExists(atPath: s),
           (try? URL(fileURLWithPath: s).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {   // return: open a folder
            withAnimation(.easeInOut(duration: 0.18)) { st.path.append(.folder(s)); st.selected = nil }; return true
        }
        if e.keyCode == 51 || e.keyCode == 117 {   // delete = reject the clip; with nothing selected = back a level
            if let s = st.selected { rate(s, -1) } else if !st.path.isEmpty { withAnimation(.easeInOut(duration: 0.18)) { _ = st.path.popLast() } }
            return true
        }
        switch ch {
        case "i": markIn()
        case "o": markOut()
        case "q": add(ed, .connect)
        case "w": add(ed, .insert)
        case "e": add(ed, .append)
        case "f": if let s = st.selected { rate(s, 1) }
        case "u": if let s = st.selected { rate(s, 0) }
        case "j": st.openSource(play: false); st.player.rate = st.player.rate < 0 ? max(st.player.rate * 2, -8) : -1
        case "k": st.player.pause()
        case "l": st.openSource(play: false); st.player.rate = st.player.rate > 0 ? min(st.player.rate * 2, 8) : 1
        case "x": st.markIn = nil; st.markOut = nil
        default: return false
        }
        return true
    }
}

/// one line in list view: small picture, name, length, type, badges, used marker
struct MediaRow: View {
    let entry: MediaEntry
    let used: [ClosedRange<Double>]
    let selected: Bool
    let offline: Bool
    let tick: Int
    var markIn: Double? = nil
    var markOut: Double? = nil
    @State private var hover = false
    @State private var skim: Double?          // 0...1 across the row while the pointer is over it (Final Cut: skim, then I / O)
    @State private var rowW: CGFloat = 300
    var body: some View {
        let it = entry.media!, (a, b) = entry.span
        HStack(spacing: 10) {
            ZStack {
                Color(white: 0.06)
                switch it.kind {
                case "image": if let im = StillThumbs.image(it.path) { Image(decorative: im, scale: 1).resizable().aspectRatio(contentMode: .fill) }
                case "audio": WaveThumb(path: it.path, a: a, b: b, tick: tick).padding(.vertical, 4)
                default:
                    let f = skim ?? 0.3
                    let t = a + (b - a) * (Double(Int(f * 23.999)) + 0.5) / 24
                    if let im = Thumbs.shared.image(it.path, at: (t * 10).rounded() / 10) ?? Thumbs.shared.image(it.path, at: ((a + (b - a) * 0.3) * 10).rounded() / 10) {
                        Image(decorative: im, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    }
                }
                if !used.isEmpty { VStack { Spacer(); Rectangle().fill(Color.orange).frame(height: 2) } }
            }
            .frame(width: 64, height: 36).clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if case .range = entry { Image(systemName: "scissors").font(.system(size: 9)).foregroundStyle(.secondary) }
                    Text(entry.title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 5) {
                    if let w = it.width { Text("\(w)×\(it.height ?? 0)") }
                    if let h = it.hdr { Text(h).font(.system(size: 8, weight: .bold)).padding(.horizontal, 3).padding(.vertical, 1).background(Color.purple.opacity(0.7)).clipShape(RoundedRectangle(cornerRadius: 2)).foregroundStyle(.white) }
                    if offline { Text("Offline").foregroundStyle(.red) }
                    if it.kind == "video" && !it.hasAudio { Image(systemName: "speaker.slash.fill") }
                }.font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if entry.rating > 0 { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.yellow) }
            if entry.rating < 0 { Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.red) }
            if it.kind != "image" { Text(MediaTile.dur(b - a)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 38, alignment: .trailing) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        // the clip's length across the row: marked part (yellow), skim point (red)
        .overlay(alignment: .bottom) {
            if it.kind != "image", b > a, hover || markIn != nil || markOut != nil {
                GeometryReader { g in
                    let w = g.size.width
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.06))
                        if markIn != nil || markOut != nil {
                            let x0 = max(0, min(1, ((markIn ?? a) - a) / (b - a))), x1 = max(0, min(1, ((markOut ?? b) - a) / (b - a)))
                            Rectangle().fill(Color.yellow).frame(width: max(2, w * (x1 - x0))).offset(x: w * x0)
                        }
                        if let sk = skim { Rectangle().fill(Color.red).frame(width: 2).offset(x: w * sk - 1) }
                    }
                }.frame(height: 3).padding(.horizontal, 8).allowsHitTesting(false)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Brand.accent.opacity(0.35) : (hover ? Color.white.opacity(0.05) : Color.clear)))
        .background(GeometryReader { g in Color.clear.onAppear { rowW = g.size.width }.onChange(of: g.size.width) { _, w in rowW = w } })
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onContinuousHover { ph in
            switch ph {
            case .active(let p):
                hover = true
                guard it.kind != "image" else { MediaState.shared.hoverEntry = entry; MediaState.shared.hoverTime = a; return }
                let f = max(0, min(1, (p.x - 8) / max(1, rowW - 16)))
                if abs(f - (skim ?? -1)) > 0.005 { skim = f }
                MediaState.shared.hoverEntry = entry; MediaState.shared.hoverTime = a + (b - a) * f
            case .ended:
                hover = false; skim = nil
                if MediaState.shared.hoverEntry?.id == entry.id { MediaState.shared.hoverEntry = nil; MediaState.shared.hoverTime = nil }
            }
        }
    }
}

/// the main monitor while it shows a media clip (source): picture, name, in/out and position. Esc or "Timeline" goes back.
struct SourceMonitor: View {
    @ObservedObject var st = MediaState.shared
    @ObservedObject var lib = MediaLibrary.shared
    @State private var now = 0.0
    private let tick = Timer.publish(every: 1.0 / 15, on: .main, in: .common).autoconnect()
    var body: some View {
        if st.sourceActive, let p = st.previewPath, let it = lib.item(p) {
            ZStack {
                Color.black
                PlayerLayerView(player: st.player)
                if it.kind == "audio" { WaveThumb(path: p, a: 0, b: it.duration, tick: 0).padding(40).opacity(0.6) }
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("SOURCE").font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 2).background(Color.orange).foregroundStyle(.black).clipShape(RoundedRectangle(cornerRadius: 3))
                        Text(it.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text("\(MediaTile.dur(now)) / \(MediaTile.dur(it.duration))").font(.system(size: 10).monospacedDigit())
                        Button("Timeline (Esc)") { st.leaveSource() }.controlSize(.small)
                    }.padding(6).background(Color.black.opacity(0.55))
                    Spacer()
                    GeometryReader { g in
                        let d = max(it.duration, 0.001), w = g.size.width
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.15))
                            if st.markIn != nil || st.markOut != nil {
                                let a = st.markIn ?? 0, b = st.markOut ?? d
                                Rectangle().fill(Color.yellow.opacity(0.45)).frame(width: max(2, w * (b - a) / d)).offset(x: w * a / d)
                            }
                            Rectangle().fill(Color.red).frame(width: 2).offset(x: w * min(now, d) / d - 1)
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in let t = max(0, min(1, Double(v.location.x / w))) * d; st.seekPreview(t); now = t })
                    }.frame(height: 10).padding(.horizontal, 6).padding(.bottom, 6)
                }
            }
            .onReceive(tick) { _ in now = st.previewTime }
        }
    }
}


// MARK: - projects in the library

/// the projects in the current project's folder: open, duplicate (also as vertical), rename, trash, new
struct ProjectsBrowser: View {
    @ObservedObject var editor: Editor
    let listView: Bool
    var inline = false
    @ObservedObject var st = MediaState.shared
    @State private var tick = 0
    var dir: URL? { editor.projectURL?.deletingLastPathComponent() }
    var paths: [String] {
        let _ = tick
        guard let d = dir else { return [] }
        return ProjectFile.list(in: d).sorted {
            let a = (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast
            let b = (try? FileManager.default.attributesOfItem(atPath: $1)[.modificationDate] as? Date) ?? .distantPast
            return a > b
        }
    }
    var body: some View {
        if inline {
            VStack(spacing: 1) { ForEach(paths, id: \.self) { p in item(p) }; newTile }
                .onReceive(NotificationCenter.default.publisher(for: Thumbs.readyNote)) { _ in tick += 1 }
        } else { full }
    }
    var full: some View {
        ScrollView {
            if listView {
                LazyVStack(spacing: 1) { newTile; ForEach(paths, id: \.self) { p in item(p) } }.padding(.vertical, 4)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: st.tile, maximum: st.tile * 1.6), spacing: 8)], spacing: 10) {
                    newTile; ForEach(paths, id: \.self) { p in item(p) }
                }.padding(8)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Thumbs.readyNote)) { _ in tick += 1 }
        .onChange(of: editor.projectURL) { _, _ in tick += 1 }
    }
    var newTile: some View {
        PlaceTile(title: "New project…", icon: "plus.rectangle.on.rectangle", count: 0, row: listView)
            .onTapGesture { NotificationCenter.default.post(name: .newProject, object: nil) }
    }
    @ViewBuilder func item(_ path: String) -> some View {
        let cur = editor.projectURL?.path == path
        let p = cur ? editor.project : ProjectFile.load(path)
        let info = p.map { "\(MediaTile.dur($0.totalDuration)) · \(formatLabel($0.settings))" } ?? "Can't read this project"
        Group {
            if listView {
                HStack(spacing: 8) {
                    thumb(p, path).frame(width: 60, height: 34).clipShape(RoundedRectangle(cornerRadius: 3))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ProjectFile.name(path)).font(.system(size: 11, weight: cur ? .semibold : .regular)).lineLimit(1)
                        Text(info).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if cur { Text("Open").font(.system(size: 9, weight: .bold)).foregroundStyle(.yellow) }
                }.padding(.horizontal, 8).frame(height: 40).contentShape(Rectangle())
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    thumb(p, path)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(cur ? Color.yellow : Color.white.opacity(0.08), lineWidth: cur ? 2 : 1))
                    Text(ProjectFile.name(path)).font(.system(size: 10, weight: cur ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                    Text(info).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }.contentShape(Rectangle())
            }
        }
        .help(cur ? "This project is open" : "Double-click to open")
        .onTapGesture(count: 2) { ProjectTabs.switchTo(editor, path) }
        .contextMenu {
            if cur { Button("Project settings…") { NotificationCenter.default.post(name: .openProjectSettings, object: nil) } }
            else { Button("Open") { ProjectTabs.switchTo(editor, path) } }
            Button("Duplicate") { duplicate(path, vertical: false) }
            Button("Duplicate as vertical (9:16)") { duplicate(path, vertical: true) }
            Button("Rename…") { rename(path) }
            Button("Show in Finder") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
            if !cur { Divider(); Button("Move to Trash") { try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil); ProjectTabs.closeTab(path); tick += 1 } }
        }
    }
    /// first frame of the project's first clip, letterboxed into the tile (vertical projects show tall)
    @ViewBuilder func thumb(_ p: Project?, _ path: String) -> some View {
        ZStack {
            Color.black
            if let p, let c = p.clips.first ?? p.upperClips?.first, let u = p.resolve(c.asset, base: URL(fileURLWithPath: path).deletingLastPathComponent()),
               let im = Thumbs.shared.image(u.path, at: (c.sourceIn * 10).rounded() / 10) {
                let ar = Double(max(1, p.settings.width)) / Double(max(1, p.settings.height))
                Image(decorative: im, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).aspectRatio(ar, contentMode: .fit).clipped()
            } else {
                Image(systemName: "film").font(.system(size: 22)).foregroundStyle(.secondary)
            }
        }
    }
    func uniquePath(_ base: String) -> String {
        guard let d = dir else { return base }
        var n = d.appendingPathComponent(base + ".cutzonical.json").path, i = 2
        while FileManager.default.fileExists(atPath: n) { n = d.appendingPathComponent("\(base) \(i).cutzonical.json").path; i += 1 }
        return n
    }
    func duplicate(_ path: String, vertical: Bool) {
        let ed = editor
        Task {
            if ed.projectURL?.path == path { _ = await ed.handle(["cmd": "save"]) }
            guard var p = ProjectFile.load(path) else { return }
            if vertical {
                let short = min(p.settings.width, p.settings.height)
                p.settings.width = short; p.settings.height = short * 16 / 9 / 2 * 2; p.settings.fit = "fill"
            }
            let dest = uniquePath(ProjectFile.name(path) + (vertical ? " vertical" : " copy"))
            try? p.save(to: URL(fileURLWithPath: dest))
            tick += 1
            ed.lastMessage = "Made \(ProjectFile.name(dest))"
        }
    }
    func rename(_ path: String) {
        let al = NSAlert(); al.messageText = "Rename project"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); f.stringValue = ProjectFile.name(path); al.accessoryView = f
        al.addButton(withTitle: "Rename"); al.addButton(withTitle: "Cancel")
        guard al.runModal() == .alertFirstButtonReturn else { return }
        let nm = f.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        guard !nm.isEmpty, let d = dir else { return }
        let dest = d.appendingPathComponent(nm + ".cutzonical.json").path
        guard !FileManager.default.fileExists(atPath: dest) else { editor.lastMessage = "A project with that name already exists"; return }
        let ed = editor, cur = ed.projectURL?.path == path
        Task {
            if cur { _ = await ed.handle(["cmd": "save"]) }
            do { try FileManager.default.moveItem(atPath: path, toPath: dest) } catch { ed.lastMessage = "Couldn't rename: \(error.localizedDescription)"; return }
            ProjectTabs.closeTab(path)
            if cur { _ = await ed.handle(["cmd": "open", "path": dest]) }
            tick += 1
        }
    }
}


/// "‹ Folder" back button: big enough to hit, highlights on hover
struct BackButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hover ? 0.12 : 0.06)))
            .foregroundStyle(Brand.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .help("Back to \(title) (⌘[ or ⌫ while not on a clip)")
        .frame(maxWidth: 170, alignment: .leading)
    }
}

/// keeps the arrow-key order and the number of tiles per row up to date, and scrolls the chosen clip into view
struct MediaNav: ViewModifier {
    @ObservedObject var st: MediaState
    let es: [MediaEntry]
    let listView: Bool
    let proxy: ScrollViewProxy
    func cols(_ w: Double, _ t: Double) -> Int { listView ? 1 : max(1, Int((w - 8) / (t + 8))) }
    func body(content: Content) -> some View {
        content
            .onAppear { st.order = es }
            .onChange(of: es.map { $0.id }) { _, _ in st.order = es }
            .onChange(of: st.selected) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { st.columns = cols(g.size.width, st.tile) }
                    .onChange(of: g.size.width) { _, w in st.columns = cols(w, st.tile) }
                    .onChange(of: st.tile) { _, t in st.columns = cols(g.size.width, t) }
                    .onChange(of: listView) { _, _ in st.columns = cols(g.size.width, st.tile) }
            })
    }
}
