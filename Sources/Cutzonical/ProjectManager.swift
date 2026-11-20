import SwiftUI
import AVFoundation
import CutzonicalCore

// Project management: where projects live (default folder, pinned folders, recents), what you can do with the open one
// (rename, move, duplicate, versions, reveal, close, move to Trash), media safety (relink, collect) and the project browser.

extension Notification.Name {
    static let openBrowser = Notification.Name("cutzonical.openBrowser")
    static let openVersions = Notification.Name("cutzonical.openVersions")
}

@MainActor enum ProjectPrefs {
    static var defaultFolder: URL? {
        get { UserDefaults.standard.string(forKey: "projects.defaultFolder").map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: "projects.defaultFolder") }
    }
    static var pinned: [String] {
        get { (UserDefaults.standard.array(forKey: "projects.pinned") as? [String] ?? []).filter { FileManager.default.fileExists(atPath: $0) } }
        set { UserDefaults.standard.set(newValue, forKey: "projects.pinned") }
    }
    static var recents: [String] {
        get { (UserDefaults.standard.array(forKey: "projects.recent") as? [String] ?? []).filter { FileManager.default.fileExists(atPath: $0) && !($0 as NSString).lastPathComponent.hasPrefix("_") } }
        set { UserDefaults.standard.set(Array(newValue.prefix(30)), forKey: "projects.recent") }
    }
    static func opened(_ p: String) { recents = [p] + recents.filter { $0 != p } }
    /// saved formats for new projects: name, width, height, fps
    struct Template: Codable, Hashable { var name: String; var w: Int; var h: Int; var fps: Double }
    static let builtIn: [Template] = [
        .init(name: "YouTube 4K 23.98", w: 3840, h: 2160, fps: 23.976), .init(name: "YouTube 1080p 23.98", w: 1920, h: 1080, fps: 23.976),
        .init(name: "YouTube 4K 30", w: 3840, h: 2160, fps: 30), .init(name: "Shorts / Reels 9:16", w: 1080, h: 1920, fps: 30),
    ]
    static var mine: [Template] {
        get { (UserDefaults.standard.data(forKey: "projects.templates")).flatMap { try? JSONDecoder().decode([Template].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "projects.templates") }
    }
    /// where a new project goes when nothing else is chosen
    static func startFolder(_ ed: Editor) -> URL {
        ed.projectURL?.deletingLastPathComponent() ?? defaultFolder ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
    }
    /// folders new projects were created in (newest first)
    static var recentFolders: [String] {
        // folders you created projects in, then the folders of projects you opened lately
        let mine = UserDefaults.standard.array(forKey: "projects.recentFolders") as? [String] ?? []
        var out: [String] = []
        for f in mine + recents.map({ ($0 as NSString).deletingLastPathComponent }) where !out.contains(f) && FileManager.default.fileExists(atPath: f) { out.append(f) }
        return out
    }
    static func usedFolder(_ p: String) { UserDefaults.standard.set(Array(([p] + recentFolders.filter { $0 != p }).prefix(8)), forKey: "projects.recentFolders") }
}

@MainActor func chooseFolder(_ title: String, start: URL?) -> URL? {
    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
    p.prompt = "Choose"; p.message = title; p.directoryURL = start
    return p.runModal() == .OK ? p.url : nil
}
@MainActor func askText(_ title: String, _ info: String, value: String, ok: String) -> String? {
    let a = NSAlert(); a.messageText = title; a.informativeText = info; a.addButton(withTitle: ok); a.addButton(withTitle: "Cancel")
    let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); f.stringValue = value; a.accessoryView = f; a.window.initialFirstResponder = f
    return a.runModal() == .alertFirstButtonReturn ? f.stringValue.trimmingCharacters(in: .whitespaces) : nil
}
@MainActor func confirm(_ title: String, _ info: String, ok: String, destructive: Bool = false) -> Bool {
    let a = NSAlert(); a.messageText = title; a.informativeText = info; a.addButton(withTitle: ok); a.addButton(withTitle: "Cancel")
    if destructive { a.buttons[0].hasDestructiveAction = true }
    return a.runModal() == .alertFirstButtonReturn
}

/// everything you can do with the open project
@MainActor enum ProjectActions {
    static func fileName(_ name: String) -> String { name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".cutzonical.json" }

    /// save under a new path and remove the old file (to the Trash) - used by rename and move
    static func relocate(_ ed: Editor, to new: URL, verb: String) {
        guard let old = ed.projectURL, new.standardizedFileURL != old.standardizedFileURL else { return }
        if FileManager.default.fileExists(atPath: new.path) { ed.lastMessage = "\(verb) stopped: \(new.lastPathComponent) already exists there"; return }
        Task {
            let r = await ed.handle(["cmd": "save", "path": new.path])
            if let e = r["error"] as? String { ed.lastMessage = "\(verb) failed: \(e)"; return }
            guard ed.projectURL?.standardizedFileURL == new.standardizedFileURL else { ed.lastMessage = "\(verb) failed: saved somewhere else"; return }
            NSWorkspace.shared.recycle([old]) { _, _ in }
            var t = ProjectTabs.paths; if let i = t.firstIndex(of: old.path) { t[i] = new.path } else { t.append(new.path) }; ProjectTabs.paths = t
            ProjectPrefs.recents = ProjectPrefs.recents.map { $0 == old.path ? new.path : $0 }
            ProjectPrefs.opened(new.path)
            ed.lastMessage = "\(verb): \(new.path)"
        }
    }
    static func rename(_ ed: Editor) {
        guard let old = ed.projectURL, let n = askText("Rename project", "The file is renamed too. The old file goes to the Trash.", value: ProjectFile.name(old.path), ok: "Rename"), !n.isEmpty else { return }
        relocate(ed, to: old.deletingLastPathComponent().appendingPathComponent(fileName(n)), verb: "Renamed")     // saving to the new name also renames the project
    }
    static func move(_ ed: Editor) {
        guard let old = ed.projectURL, let d = chooseFolder("Move the project file to this folder (media stays where it is)", start: old.deletingLastPathComponent()) else { return }
        relocate(ed, to: d.appendingPathComponent(old.lastPathComponent), verb: "Moved")
    }
    static func saveAs(_ ed: Editor) { saveAsPanel(ed) }
    static func duplicate(_ ed: Editor) {
        let p = NSSavePanel()
        p.nameFieldStringValue = fileName((ed.projectURL.map { ProjectFile.name($0.path) } ?? "Untitled") + " copy")
        p.message = "Duplicate: a copy of this project. You keep working in this one."
        p.directoryURL = ed.projectURL?.deletingLastPathComponent()
        guard p.runModal() == .OK, var u = p.url else { return }
        if !u.lastPathComponent.hasSuffix(".cutzonical.json") { u = u.deletingPathExtension().appendingPathExtension("cutzonical.json") }
        Task {
            let r = await ed.handle(["cmd": "duplicate_project", "path": u.path])
            ed.lastMessage = (r["error"] as? String).map { "Duplicate failed: \($0)" } ?? "Duplicated to \(u.lastPathComponent)"
            if r["error"] == nil { ProjectTabs.opened(u.path) }
        }
    }
    static func reveal(_ ed: Editor) { if let u = ed.projectURL { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
    static func copyPath(_ ed: Editor) {
        guard let u = ed.projectURL else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u.path, forType: .string); ed.lastMessage = "Path copied"
    }
    /// asks about unsaved changes; false = cancelled
    static func settleUnsaved(_ ed: Editor) async -> Bool {
        guard ed.hasUnsavedChanges else { return true }
        let a = NSAlert(); a.messageText = "Save changes to “\(ed.projectURL.map { ProjectFile.name($0.path) } ?? "this project")”?"
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Don’t save"); a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: _ = await ed.handle(["cmd": "save"]); return true
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
    static func close(_ ed: Editor) {
        guard let cur = ed.projectURL else { return }
        Task {
            guard await settleUnsaved(ed) else { return }
            let others = ProjectTabs.paths.filter { $0 != cur.path }
            ProjectTabs.closeTab(cur.path)
            if let next = others.last { _ = await ed.handle(["cmd": "open", "path": next]); ProjectTabs.opened(next) }
            else { NotificationCenter.default.post(name: .openBrowser, object: nil) }
        }
    }
    static func trash(_ ed: Editor) {
        guard let cur = ed.projectURL, confirm("Move “\(ProjectFile.name(cur.path))” to the Trash?", "Only the project file goes to the Trash (you can put it back from there). Your media files are not touched.", ok: "Move to Trash", destructive: true) else { return }
        Task {
            let others = ProjectTabs.paths.filter { $0 != cur.path }
            ProjectTabs.closeTab(cur.path)
            ProjectPrefs.recents = ProjectPrefs.recents.filter { $0 != cur.path }
            if let next = others.last { _ = await ed.handle(["cmd": "open", "path": next]) }
            NSWorkspace.shared.recycle([cur]) { _, _ in }
            ed.lastMessage = "Moved to the Trash: \(cur.lastPathComponent)"
            if others.isEmpty { NotificationCenter.default.post(name: .openBrowser, object: nil) }
        }
    }
    static func relink(_ ed: Editor) {
        let missing = ed.mediaFiles().filter { !$0.exists }
        let start = missing.first.map { $0.url.deletingLastPathComponent() } ?? ed.projectURL?.deletingLastPathComponent()
        guard let d = chooseFolder(missing.isEmpty ? "No media is missing. Choose a folder to point every file at its copy there (matched by file name)."
                                   : "\(missing.count) media file\(missing.count == 1 ? " is" : "s are") missing. Choose the folder they are in now (sub-folders are searched too).", start: start) else { return }
        Task {
            let r = await ed.handle(["cmd": "relink_folder", "dir": d.path, "all": missing.isEmpty])
            let f = r["found"] as? Int ?? 0, m = r["missing"] as? Int ?? 0
            ed.lastMessage = (r["error"] as? String) ?? (m == 0 ? "Relinked \(f) file\(f == 1 ? "" : "s")" : "Relinked \(f), still missing \(m)")
        }
    }
    static func collect(_ ed: Editor) {
        let files = ed.mediaFiles().filter(\.exists)
        let size = files.reduce(Int64(0)) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.url.path)[.size] as? Int64) ?? 0) }
        guard !files.isEmpty, let d = chooseFolder("Collect media: copies the \(files.count) media files this project uses (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))) into one folder, then points the project at the copies. The originals stay where they are.",
                                                   start: ed.projectURL?.deletingLastPathComponent()) else { return }
        ed.lastMessage = "Collecting \(files.count) files…"
        let list = files.map { ($0.id, $0.url) }
        Task {
            let map: [String: String] = await Task.detached {
                var out: [String: String] = [:], used: [String: URL] = [:]
                for (id, src) in list {
                    var dst = d.appendingPathComponent(src.lastPathComponent)
                    // two different files with the same name: the second gets a number
                    var n = 2
                    while let u = used[dst.lastPathComponent.lowercased()], u != src {
                        dst = d.appendingPathComponent(src.deletingPathExtension().lastPathComponent + " \(n)." + src.pathExtension); n += 1
                    }
                    used[dst.lastPathComponent.lowercased()] = src
                    if src.standardizedFileURL == dst.standardizedFileURL { out[id] = dst.path; continue }
                    if !FileManager.default.fileExists(atPath: dst.path) { do { try FileManager.default.copyItem(at: src, to: dst) } catch { continue } }
                    out[id] = dst.path
                }
                return out
            }.value
            let r = await ed.handle(["cmd": "set_asset_paths", "paths": map])
            ed.lastMessage = (r["error"] as? String) ?? "Collected \(map.count) of \(list.count) files into \(d.lastPathComponent). Save to keep it."
        }
    }
}

/// the project name above the viewer: a menu with every project action
struct ProjectMenu: View {
    @ObservedObject var editor: Editor
    var body: some View {
        let missing = MissingCount.get(editor)
        Menu {
            if let u = editor.projectURL { Text(u.deletingLastPathComponent().path) }
            Divider()
            Button("Rename…") { ProjectActions.rename(editor) }
            Button("Move to…") { ProjectActions.move(editor) }
            Button("Save as…") { ProjectActions.saveAs(editor) }
            Button("Duplicate…") { ProjectActions.duplicate(editor) }
            Divider()
            Button("Reveal in Finder") { ProjectActions.reveal(editor) }
            Button("Copy path") { ProjectActions.copyPath(editor) }
            Button("Versions…") { NotificationCenter.default.post(name: .openVersions, object: nil) }
            Divider()
            Button(missing > 0 ? "Relink missing media (\(missing))…" : "Relink media…") { ProjectActions.relink(editor) }
            Button("Collect media…") { ProjectActions.collect(editor) }
            Divider()
            Button("All projects… (⇧⌘O)") { NotificationCenter.default.post(name: .openBrowser, object: nil) }
            Button("Close project") { ProjectActions.close(editor) }
            Button("Move to Trash…") { ProjectActions.trash(editor) }
        } label: {
            HStack(spacing: 4) {
                Text(editor.project.name).font(Brand.label).lineLimit(1).truncationMode(.middle)
                if editor.hasUnsavedChanges { Circle().fill(Color.secondary).frame(width: 5, height: 5).help("Unsaved changes") }
                if missing > 0 { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.orange).help("\(missing) media missing") }
            }
        }
        .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
        .help(editor.projectURL?.path ?? "")
    }
}

/// "Saved 2 min ago" / "Unsaved changes" next to the project name
struct SaveStatus: View {
    @ObservedObject var editor: Editor
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            if let u = editor.projectURL {
                let unsaved = editor.hasUnsavedChanges
                let d = (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? nil
                Text(unsaved ? "Unsaved changes" : d.map { "Saved " + ago($0, ctx.date) } ?? "")
                    .font(.system(size: 10)).foregroundStyle(unsaved ? Color.orange.opacity(0.85) : Color.secondary.opacity(0.7))
                    .help(unsaved ? "⌘S saves. Unsaved work is also kept every minute in case of a crash." : u.path)
            }
        }
    }
    func ago(_ d: Date, _ now: Date) -> String {
        let s = now.timeIntervalSince(d)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        let f = DateFormatter(); f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "d MMM HH:mm"; return f.string(from: d)
    }
}

/// window title = project file (⌘-click shows its folder path), dot in the close button when unsaved
struct WindowDocument: NSViewRepresentable {
    let url: URL?
    let edited: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            if w.representedURL != url { w.representedURL = url; if let url { w.title = ProjectFile.name(url.path) } }
            if w.isDocumentEdited != edited { w.isDocumentEdited = edited }
        }
    }
}

// MARK: versions

struct VersionsView: View {
    @ObservedObject var editor: Editor
    var close: () -> Void
    var body: some View {
        let files = editor.versionFiles()
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Versions").font(.system(size: 17, weight: .semibold))
                    Text("Every save keeps the file it replaces (last 10). Restoring puts that version on the timeline; ⌘Z undoes it.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { close() }.keyboardShortcut(.cancelAction)
            }.padding(18)
            Divider()
            if files.isEmpty {
                Text("No earlier versions yet. They appear after the next save.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(files, id: \.self) { f in
                    let p = try? Project.load(from: f)
                    HStack {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stamp(f)).font(.system(size: 12, weight: .medium))
                            if let p { Text("\(p.clips.count + (p.upperClips?.count ?? 0)) clips · \(p.overlays?.count ?? 0) graphics · \(len(p))").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("Restore") { Task {
                            let r = await editor.handle(["cmd": "restore_version", "file": f.path])
                            editor.lastMessage = (r["error"] as? String).map { "Could not restore: \($0)" } ?? "Restored the version from \(stamp(f)). Save to keep it, ⌘Z to undo."
                            close() } }
                        Button { NSWorkspace.shared.activateFileViewerSelecting([f]) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Show the file")
                    }.padding(.vertical, 3)
                }
            }
        }.frame(width: 560, height: 440)
    }
    func stamp(_ f: URL) -> String {
        let s = f.lastPathComponent.replacingOccurrences(of: ".cutzonical.json", with: "")
        let i = DateFormatter(); i.dateFormat = "yyyy-MM-dd HH-mm-ss"
        guard let d = i.date(from: s) else { return s }
        let o = DateFormatter(); o.dateFormat = "d MMM yyyy, HH:mm:ss"; return o.string(from: d)
    }
}
func len(_ p: Project) -> String {
    let d = (p.clips.map { $0.offset + $0.duration } + (p.upperClips ?? []).map { $0.offset + $0.duration }).max() ?? 0
    return String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)
}

// MARK: project browser

final class ProjectThumbs: @unchecked Sendable {
    static let shared = ProjectThumbs()
    private var cache: [String: NSImage] = [:]
    private let lock = NSLock()
    func get(_ path: String) -> NSImage? { lock.lock(); defer { lock.unlock() }; return cache[path] }
    func load(_ path: String) async -> NSImage? {
        if let i = get(path) { return i }
        guard let p = ProjectFile.load(path), let c = p.clips.first ?? p.upperClips?.first,
              let u = p.resolve(c.asset, base: URL(fileURLWithPath: path).deletingLastPathComponent()), FileManager.default.fileExists(atPath: u.path) else { return nil }
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: u)); g.appliesPreferredTrackTransform = true; g.maximumSize = CGSize(width: 320, height: 320)
        guard let cg = try? await g.image(at: CMTime(seconds: c.sourceIn + min(2, c.duration / 2), preferredTimescale: 600)).image else { return nil }
        let i = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        lock.lock(); cache[path] = i; lock.unlock()
        return i
    }
}

struct ProjectBrowser: View {
    @ObservedObject var editor: Editor
    var close: () -> Void
    @State private var place = "recent"                 // recent | <pinned folder path>
    @State private var tick = 0
    @State private var query = ""
    @State private var found: [String] = []

    var body: some View {
        let _ = tick
        HStack(spacing: 0) {
            sidebar.frame(width: 220).background(Color(white: 0.11))
            Divider()
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(place == "recent" ? "Recent projects" : (place as NSString).lastPathComponent).font(.system(size: 16, weight: .semibold))
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                        TextField("Search", text: $query).textFieldStyle(.plain).font(.caption).frame(width: 140)
                    }.padding(.horizontal, 6).padding(.vertical, 4).background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                    Button("Close") { close() }.keyboardShortcut(.cancelAction)
                }.padding(16)
                Divider()
                ScrollView { grid.padding(16) }
            }
        }
        .frame(width: 900, height: 600)
        .task(id: place) { await scan() }
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) { LogoMark(size: 20); Text("Cutzonical").font(.system(size: 14, weight: .bold, design: .rounded)) }.padding(.bottom, 10)
            Button { close(); NotificationCenter.default.post(name: .newProject, object: nil) } label: { Label("New project…", systemImage: "plus.rectangle.on.rectangle").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Button { close(); openPanel(editor) } label: { Label("Open…", systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading) }.controlSize(.large)
            Divider().padding(.vertical, 8)
            row("Recent", "clock", "recent")
            Text("PINNED FOLDERS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 10)
            ForEach(ProjectPrefs.pinned, id: \.self) { f in
                row((f as NSString).lastPathComponent, "pin", f)
                    .contextMenu { Button("Unpin") { ProjectPrefs.pinned = ProjectPrefs.pinned.filter { $0 != f }; if place == f { place = "recent" }; tick += 1 }
                                   Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: f)) } }
            }
            Button { if let d = chooseFolder("Pin a folder: every project in it (and its sub-folders) is listed here", start: ProjectPrefs.defaultFolder) { ProjectPrefs.pinned = ProjectPrefs.pinned + [d.path]; place = d.path; tick += 1 } } label: {
                Label("Pin a folder…", systemImage: "plus").font(.caption) }.buttonStyle(.borderless).padding(.leading, 6).padding(.top, 2)
            let rec = Editor.recoveryItems()
            if !rec.isEmpty {
                Text("UNSAVED WORK").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 12)
                ForEach(rec.prefix(4), id: \.path) { r in
                    Button { open(r.path) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ProjectFile.name(r.path)).font(.caption).lineLimit(1)
                            Text(r.time.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 9)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.borderless).padding(.leading, 6).help("Open it: Cutzonical offers to restore the unsaved work")
                }
            }
            Spacer()
            Divider()
            HStack {
                Text("New projects go to").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
            }
            Button { if let d = chooseFolder("Default folder for new projects", start: ProjectPrefs.defaultFolder) { ProjectPrefs.defaultFolder = d; tick += 1 } } label: {
                Text(ProjectPrefs.defaultFolder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "the open project’s folder").font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.leading)
            }.buttonStyle(.borderless).help("Click to change")
        }.padding(14)
    }
    func row(_ title: String, _ icon: String, _ id: String) -> some View {
        Button { place = id } label: {
            Label(title, systemImage: icon).font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(place == id ? Brand.accent.opacity(0.3) : .clear))
        }.buttonStyle(.plain)
    }

    func scan() async {
        if place == "recent" { found = ProjectPrefs.recents; return }
        let root = URL(fileURLWithPath: place)
        found = await Task.detached {
            var out: [String] = []
            let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let u = en?.nextObject() as? URL {
                if en!.level > 7 { en!.skipDescendants(); continue }
                if (u.lastPathComponent.hasSuffix(".cutzonical.json") || u.lastPathComponent.hasSuffix(".cutline.json")) && !u.lastPathComponent.hasPrefix("_") { out.append(u.path) }
            }
            return out
        }.value
    }
    /// pinned folder: grouped by the first sub-folder (for example one folder per video)
    var groups: [(String, [String])] {
        let list = found.filter { query.isEmpty || ProjectFile.name($0).localizedCaseInsensitiveContains(query) || $0.localizedCaseInsensitiveContains(query) }
        if place == "recent" { return [("", list)] }
        let d = Dictionary(grouping: list) { p -> String in
            let rel = p.dropFirst(place.count + 1).split(separator: "/")
            return rel.count > 1 ? String(rel[0]) : "In this folder"
        }
        return d.map { ($0.key, $0.value.sorted { mtime($0) > mtime($1) }) }.sorted { $0.0.localizedStandardCompare($1.0) == .orderedDescending }
    }
    func mtime(_ p: String) -> Date { (try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? .distantPast }

    @ViewBuilder var grid: some View {
        let gs = groups
        if gs.allSatisfy({ $0.1.isEmpty }) {
            Text(place == "recent" ? "No recent projects yet." : "No projects in this folder.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 60)
        }
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(gs, id: \.0) { g in
                if !g.1.isEmpty {
                    if !g.0.isEmpty { Text(g.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 230), spacing: 14)], alignment: .leading, spacing: 14) {
                        ForEach(g.1, id: \.self) { p in ProjectCard(path: p, current: p == editor.projectURL?.path) { open(p) } }
                    }
                }
            }
        }
    }
    func open(_ p: String) {
        close()
        Task {
            if editor.projectURL?.path != p {
                guard await ProjectActions.settleUnsaved(editor) else { return }
                let r = await editor.handle(["cmd": "open", "path": p])
                if r["error"] == nil { ProjectTabs.opened(p) } else { editor.lastMessage = "Open failed: \(r["error"] ?? "")" }
            }
        }
    }
}

struct ProjectCard: View {
    let path: String
    let current: Bool
    let open: () -> Void
    @State private var thumb: NSImage?
    @State private var hover = false
    var body: some View {
        let p = ProjectFile.load(path)
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(Color(white: 0.16))
                if let thumb { Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill) }
                else { Image(systemName: "film").font(.system(size: 22)).foregroundStyle(.tertiary) }
            }
            .frame(height: 110).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .bottomTrailing) {
                if let p { Text(len(p)).font(.system(size: 10, weight: .medium).monospacedDigit()).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.7))).padding(6) }
            }
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(current ? Brand.accent : Color.white.opacity(hover ? 0.3 : 0.08), lineWidth: current ? 2 : 1))
            Text(ProjectFile.name(path)).font(.system(size: 12, weight: .medium)).lineLimit(1)
            HStack(spacing: 4) {
                if let s = p?.settings { Text("\(s.width)×\(s.height) · \(Editor.fpsName(s.fps))") }
                Spacer()
                Text(((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil)?.formatted(.relative(presentation: .named)) ?? "")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            Text(((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { open() }
        .onTapGesture { open() }
        .contextMenu {
            Button("Open") { open() }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }
        }
        .help(path)
        .task { thumb = await ProjectThumbs.shared.load(path) }
    }
}

/// project browser and versions windows, the window title, and the browser when nothing is open after start
struct ProjectSheets: ViewModifier {
    @ObservedObject var editor: Editor
    @State private var showBrowser = false
    @State private var showVersions = false
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showBrowser) { ProjectBrowser(editor: editor) { showBrowser = false } }
            .onReceive(NotificationCenter.default.publisher(for: .openBrowser)) { _ in showBrowser = true }
            .sheet(isPresented: $showVersions) { VersionsView(editor: editor) { showVersions = false } }
            .onReceive(NotificationCenter.default.publisher(for: .openVersions)) { _ in showVersions = true }
            .background(WindowDocument(url: editor.projectURL, edited: editor.hasUnsavedChanges))
            .task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if editor.projectURL == nil { showBrowser = true }
            }
    }
}

/// orange bar over the timeline while media files are missing (their clips play black / silent)
struct MissingMediaBar: View {
    @ObservedObject var editor: Editor
    @State private var count = 0
    var body: some View {
        Group {
            if count > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(count) media file\(count == 1 ? " is" : "s are") missing. Their clips show black and silent.").font(.system(size: 11))
                    Spacer()
                    Button("Relink…") { ProjectActions.relink(editor) }.controlSize(.small)
                }
                .padding(.horizontal, 10).padding(.vertical, 5).background(Color.orange.opacity(0.15))
            }
        }
        .task(id: editor.project.assets) { count = editor.mediaFiles().filter { !$0.exists }.count }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in count = editor.mediaFiles().filter { !$0.exists }.count }
    }
}

/// missing media count, checked at most every 3 seconds (the project name menu redraws often)
@MainActor enum MissingCount {
    static var last: (Date, [Asset], Int) = (.distantPast, [], 0)
    static func get(_ ed: Editor) -> Int {
        if Date().timeIntervalSince(last.0) < 3 && last.1 == ed.project.assets { return last.2 }
        let n = ed.mediaFiles().filter { !$0.exists }.count
        last = (Date(), ed.project.assets, n); return n
    }
}

/// export running in the background (Export window closed): progress, stop, and the finished file
struct ExportPill: View {
    @ObservedObject var editor: Editor
    @State private var hideDone = false
    var body: some View {
        if let p = editor.exportProgress {
            HStack(spacing: 6) {
                ProgressView(value: p).frame(width: 70).controlSize(.small)
                Text("Exporting \(Int(p * 100)) %").font(.system(size: 10).monospacedDigit())
                Button { editor.cancelExport() } label: { Image(systemName: "stop.circle") }.buttonStyle(.borderless).help("Stop the export")
            }
            .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Color.white.opacity(0.08)))
            .help(editor.exportingName ?? "")
            .onAppear { hideDone = false }
        } else if let u = editor.lastExport, !hideDone {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 11))
                Button("Exported · Show") { NSWorkspace.shared.activateFileViewerSelecting([u]) }.buttonStyle(.borderless).font(.system(size: 10))
                Button { hideDone = true } label: { Image(systemName: "xmark").font(.system(size: 8)) }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Color.green.opacity(0.12)))
            .help(u.path)
        }
    }
}
