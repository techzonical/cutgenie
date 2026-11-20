import SwiftUI
import AppKit
import CutgenieCore

/// Project shapes and their usual sizes (the short side first is irrelevant: sizes are listed as they are used)
struct FormatShape: Identifiable, Hashable {
    let id: String, name: String, use: String
    let sizes: [(Int, Int)]
    static func == (a: FormatShape, b: FormatShape) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
    static let all: [FormatShape] = [
        FormatShape(id: "16:9", name: "16:9 landscape", use: "YouTube, TV", sizes: [(1280, 720), (1920, 1080), (2560, 1440), (3840, 2160)]),
        FormatShape(id: "9:16", name: "9:16 vertical", use: "Shorts, Reels, TikTok", sizes: [(720, 1280), (1080, 1920), (2160, 3840)]),
        FormatShape(id: "1:1", name: "1:1 square", use: "Feed posts", sizes: [(1080, 1080), (2160, 2160)]),
        FormatShape(id: "4:5", name: "4:5 portrait", use: "Instagram feed", sizes: [(1080, 1350), (2160, 2700)]),
        FormatShape(id: "4:3", name: "4:3", use: "Classic, product shots", sizes: [(1440, 1080), (2880, 2160)]),
        FormatShape(id: "21:9", name: "2.39:1 cinematic", use: "Film look", sizes: [(1920, 804), (3840, 1608)]),
    ]
    static func of(_ w: Int, _ h: Int) -> String {
        for s in all where s.sizes.contains(where: { $0 == (w, h) }) { return s.id }
        return "custom"
    }
}

let frameRates: [(Double, String)] = [(23.976, "23.98"), (24, "24"), (25, "25"), (29.97, "29.97"), (30, "30"), (48, "48"), (50, "50"),
                                      (59.94, "59.94"), (60, "60"), (90, "90"), (100, "100"), (119.88, "119.88"), (120, "120"), (240, "240")]
/// frame rates grouped the way people think of them
let frameRateGroups: [(String, [Double])] = [("Film", [23.976, 24, 48]), ("PAL / Europe, India TV", [25, 50, 100]),
                                             ("NTSC / phones, web", [29.97, 30, 59.94, 60]), ("High speed", [90, 119.88, 120, 240])]

/// "4K · 16:9 · 23.98" for a project
func formatLabel(_ s: CutgenieCore.Settings) -> String {
    let long = max(s.width, s.height), short = min(s.width, s.height)
    let k = long == 3840 || long == 4096 ? "4K" : (short == 1080 ? "1080p" : (short == 720 ? "720p" : (short == 1440 ? "1440p" : "\(s.width)×\(s.height)")))
    let shape = FormatShape.of(s.width, s.height)
    return "\(k) · \(shape == "custom" ? "\(s.width)×\(s.height)" : shape) · \(Editor.fpsName(s.fps))"
}

extension Notification.Name {
    static let openProjectSettings = Notification.Name("cutgenie.openProjectSettings")
    static let newProject = Notification.Name("cutgenie.newProject")
}

/// Project settings (⌘J) — also used for "New project" (name field shown, nothing applied until Create)
struct ProjectSettingsView: View {
    @ObservedObject var editor: Editor
    var isNew = false
    var close: () -> Void
    @State private var shape = "16:9"
    @State private var width = 1920
    @State private var height = 1080
    @State private var fps = 23.976
    @State private var fit = "fit"
    @State private var name = ""
    @State private var loaded = false
    @State private var folder: URL? = nil
    @State private var tplTick = 0
    var target: URL? { folder.map { $0.appendingPathComponent(ProjectActions.fileName(name.trimmingCharacters(in: .whitespaces))) } }
    var exists: Bool { target.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // header
            HStack(alignment: .center) {
                Button { close() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).background(Circle().fill(Color.white.opacity(0.1)))
                }.buttonStyle(.plain).help("Close (Esc)").padding(.trailing, 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNew ? "New project" : "Project settings").font(.system(size: 17, weight: .semibold))
                    Text(isNew ? "Pick a format, or leave it and match your first clip" : "Now: \(formatLabel(editor.project.settings))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)
            Divider()
            FittedScroll {
                VStack(alignment: .leading, spacing: 18) {
                    if isNew {
                        section("Start from") {
                            let _ = tplTick
                            HStack(spacing: 6) {
                                ForEach(ProjectPrefs.builtIn + ProjectPrefs.mine, id: \.self) { t in
                                    chip(t.name, on: width == t.w && height == t.h && abs(fps - t.fps) < 0.01) { width = t.w; height = t.h; fps = t.fps; shape = FormatShape.of(t.w, t.h) }
                                        .contextMenu { if ProjectPrefs.mine.contains(t) { Button("Delete template") { ProjectPrefs.mine = ProjectPrefs.mine.filter { $0 != t }; tplTick += 1 } } }
                                }
                                Button { if let n = askText("Save format as template", "\(width)×\(height) · \(Editor.fpsName(fps))", value: "", ok: "Save"), !n.isEmpty {
                                    ProjectPrefs.mine = ProjectPrefs.mine + [.init(name: n, w: width, h: height, fps: fps)]; tplTick += 1 } } label: { Image(systemName: "plus") }
                                    .buttonStyle(.borderless).help("Save the format below as your own template")
                            }
                        }
                        section("Name") { TextField("My video", text: $name).textFieldStyle(.roundedBorder).font(.system(size: 13)) }
                        section("Save in") {
                            let here = folder ?? ProjectPrefs.startFolder(editor)
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill").font(.system(size: 20)).foregroundStyle(Brand.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(here.lastPathComponent).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                    Text(folder == nil ? (editor.projectURL != nil ? "Same folder as the open project" : "Movies folder") : "Folder you chose")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }.help(here.path)
                                Spacer()
                                Button("Choose another folder…") { if let d = chooseFolder("Save the new project in", start: here) { folder = d } }
                                if folder != nil, editor.projectURL != nil {
                                    Button { folder = nil } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.borderless)
                                        .help("Back to the open project’s folder")
                                }
                            }
                            .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                            let recent = ProjectPrefs.recentFolders.filter { $0 != here.path }.prefix(4)
                            if !recent.isEmpty {
                                HStack(spacing: 6) {
                                    Text("Recent").font(.system(size: 10)).foregroundStyle(.secondary)
                                    ForEach(Array(recent), id: \.self) { f in
                                        let u = URL(fileURLWithPath: f)
                                        chip(u.deletingLastPathComponent().lastPathComponent.prefix(18) + " · " + u.lastPathComponent, on: false) { folder = u }
                                            .help(f)
                                    }
                                }
                            }
                            if !name.trimmingCharacters(in: .whitespaces).isEmpty, let t = target {
                                if exists { Text("A project called “\(t.lastPathComponent)” is already in this folder. Pick another name.").font(.system(size: 11)).foregroundStyle(.orange) }
                                else { Text("Creates \(t.lastPathComponent)").font(.system(size: 11)).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 18) {
                            section("Shape") {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                                    ForEach(FormatShape.all) { sh in shapeCard(sh) }
                                    customCard
                                }
                            }
                            section("Size") {
                                if let sh = FormatShape.all.first(where: { $0.id == shape }) {
                                    HStack(spacing: 6) {
                                        ForEach(sh.sizes, id: \.0) { z in chip(sizeName(z.0, z.1), on: width == z.0 && height == z.1) { width = z.0; height = z.1 } }
                                    }
                                } else {
                                    HStack(spacing: 6) {
                                        TextField("Width", value: $width, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 80)
                                        Text("×").foregroundStyle(.secondary)
                                        TextField("Height", value: $height, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 80)
                                        Text("pixels").font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                }
                                if width != height {
                                    Picker("", selection: Binding(get: { width >= height }, set: { land in if land != (width >= height) { swap(&width, &height); shape = FormatShape.of(width, height) } })) {
                                        Label("Landscape", systemImage: "rectangle").tag(true); Label("Portrait", systemImage: "rectangle.portrait").tag(false)
                                    }.pickerStyle(.segmented).labelsHidden().frame(width: 240).padding(.top, 6)
                                }
                            }
                        }
                        preview.padding(.top, 22)
                    }
                    section("Frame rate") {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(frameRateGroups, id: \.0) { g in
                                HStack(spacing: 6) {
                                    Text(g.0).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                                    ForEach(g.1, id: \.self) { f in chip(Editor.fpsName(f), on: abs(fps - f) < 0.01) { fps = f } }
                                }
                            }
                            HStack(spacing: 6) {
                                Text("Other").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                                TextField("fps", value: $fps, format: .number.precision(.fractionLength(0...3))).textFieldStyle(.roundedBorder).frame(width: 70)
                                Text("fps").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        note("Clips with another frame rate play at normal speed. Right-click a faster clip in the timeline for smooth slow motion.")
                    }
                    section("Clips of another size") {
                        Picker("", selection: $fit) {
                            Text("Fit - whole picture").tag("fit"); Text("Fill - crop to fill").tag("fill"); Text("Actual size").tag("none")
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 380)
                    }
                }.padding(22)
            }
            Divider()
            HStack {
                if !isNew, let first = editor.project.clips.first ?? editor.project.upperClips?.first, let f = editor.assetFormat[first.asset] {
                    Button { width = f.width; height = f.height; fps = f.fps; shape = FormatShape.of(width, height) } label: {
                        Label("Match first clip · \(f.label)", systemImage: "wand.and.stars")
                    }
                }
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction).controlSize(.large)
                Button(isNew ? "Create" : "Apply") { apply() }.keyboardShortcut(.defaultAction).controlSize(.large)
                    .disabled((isNew && (name.trimmingCharacters(in: .whitespaces).isEmpty || exists)) || width < 16 || height < 16 || fps < 1)
            }.padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 700, height: fitScreen(isNew ? 900 : 760))
        .onAppear {
            let s = editor.project.settings
            if !isNew { width = s.width; height = s.height; fps = frameRates.first { abs($0.0 - s.fps) < 0.01 }?.0 ?? s.fps; fit = s.fit ?? "fit" }
            shape = FormatShape.of(width, height)
            DispatchQueue.main.async { loaded = true }
        }
    }

    func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
            c()
        }
    }
    func note(_ t: String) -> some View {
        Text(t).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    func sizeName(_ w: Int, _ h: Int) -> String {
        let s = min(w, h), l = max(w, h)
        let tag = l >= 3800 ? "4K" : (s == 1440 ? "1440p" : (s == 1080 ? "HD" : (s == 720 ? "720p" : "")))
        return tag.isEmpty ? "\(w)×\(h)" : "\(tag)  \(w)×\(h)"
    }
    /// a pill button (sizes, frame rates)
    func chip(_ t: String, on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(.system(size: 11, weight: on ? .semibold : .regular).monospacedDigit())
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(on ? Brand.accent : Color(white: 0.2)).foregroundStyle(on ? Brand.onAccent : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }
    /// a shape as a card with its proportions drawn
    func shapeCard(_ sh: FormatShape) -> some View {
        let on = shape == sh.id
        let (w, h) = sh.sizes[0]
        let k = 30.0 / Double(max(w, h))
        return Button { pickShape(sh) } label: {
            VStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).stroke(on ? Brand.accent : Color.secondary, lineWidth: 1.5)
                    .frame(width: Double(w) * k, height: Double(h) * k).frame(height: 32)
                Text(sh.id == "21:9" ? "2.39:1" : sh.id).font(.system(size: 12, weight: .semibold))
                Text(sh.use).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(on ? Brand.accent.opacity(0.18) : Color(white: 0.16))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Brand.accent : Color.clear, lineWidth: 1.5))
            .clipShape(RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    var customCard: some View {
        let on = shape == "custom"
        return Button { shape = "custom" } label: {
            VStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 18)).foregroundStyle(on ? Brand.accent : Color.secondary).frame(height: 32)
                Text("Custom").font(.system(size: 12, weight: .semibold))
                Text("Any size").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(on ? Brand.accent.opacity(0.18) : Color(white: 0.16))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Brand.accent : Color.clear, lineWidth: 1.5))
            .clipShape(RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    func pickShape(_ sh: FormatShape) {
        // keep the same quality step (4K stays 4K) where the new shape has it
        let q = min(width, height)
        let pick = sh.sizes.min { abs(min($0.0, $0.1) - q) < abs(min($1.0, $1.1) - q) } ?? sh.sizes[0]
        shape = sh.id; width = pick.0; height = pick.1
    }

    /// the new frame, with the current one dashed behind it
    var preview: some View {
        let cur = editor.project.settings
        let box = 130.0
        func sz(_ w: Int, _ h: Int) -> CGSize { let k = box / Double(max(1, max(w, h))); return CGSize(width: Double(w) * k, height: Double(h) * k) }
        let n = sz(width, height), c = sz(cur.width, cur.height)
        return VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.13))
                if !isNew { Rectangle().stroke(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3])).frame(width: c.width, height: c.height) }
                Rectangle().fill(Brand.accent.opacity(0.22)).overlay(Rectangle().stroke(Brand.accent, lineWidth: 1.5)).frame(width: n.width, height: n.height)
                    .animation(.easeOut(duration: 0.15), value: width).animation(.easeOut(duration: 0.15), value: height)
            }.frame(width: box + 24, height: box + 24)
            Text("\(width) × \(height)").font(.system(size: 12, weight: .semibold).monospacedDigit())
            Text("\(Editor.fpsName(fps)) fps").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            if !isNew { Text("dashed = now").font(.system(size: 9)).foregroundStyle(.tertiary) }
        }
    }

    func apply() {
        let ed = editor
        if isNew {
            let base = folder ?? ProjectPrefs.startFolder(ed)
            ProjectPrefs.usedFolder(base.path)
            let safe = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
            let path = base.appendingPathComponent(ProjectActions.fileName(safe)).path
            let (w, h, f) = (width, height, fps)
            Task {
                if ed.projectURL != nil { _ = await ed.handle(["cmd": "save"]) }
                let r = await ed.handle(["cmd": "new_project", "path": path, "width": w, "height": h, "fps": f])
                if r["ok"] as? Bool == true { ProjectTabs.opened(path) }
            }
        } else {
            let (w, h, f, ft) = (width, height, fps, fit)
            Task { _ = await ed.handle(["cmd": "project_settings", "width": w, "height": h, "fps": f, "fit": ft]) }
        }
        close()
    }
}

/// open projects shown as tabs above the timeline (remembered between launches)
@MainActor enum ProjectTabs {
    static var paths: [String] {
        get { (UserDefaults.standard.array(forKey: "projectTabs") as? [String] ?? []).filter { FileManager.default.fileExists(atPath: $0) } }
        set { UserDefaults.standard.set(newValue, forKey: "projectTabs") }
    }
    static func opened(_ path: String) { var p = paths; if !p.contains(path) { p.append(path) }; paths = p }
    static func closeTab(_ path: String) { paths = paths.filter { $0 != path } }
    /// save the current project, then open another one
    static func switchTo(_ ed: Editor, _ path: String) {
        guard ed.projectURL?.path != path else { return }
        Task {
            if ed.projectURL != nil { _ = await ed.handle(["cmd": "save"]) }
            _ = await ed.handle(["cmd": "open", "path": path])
            opened(path)
        }
    }
}

struct ProjectTabBar: View {
    @ObservedObject var editor: Editor
    @State private var tick = 0
    var body: some View {
        let _ = tick
        let cur = editor.projectURL?.path
        let paths = { var p = ProjectTabs.paths; if let c = cur, !p.contains(c) { p.append(c) }; return p }()
        if paths.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(paths, id: \.self) { p in
                        let on = p == cur
                        HStack(spacing: 4) {
                            Text(ProjectFile.name(p)).font(.system(size: 11, weight: on ? .semibold : .regular)).lineLimit(1)
                            if on && editor.hasUnsavedChanges { Circle().fill(Color.secondary).frame(width: 5, height: 5).help("Unsaved changes") }
                            if let s = ProjectFile.settings(p) { Text(FormatShape.of(s.width, s.height) == "custom" ? "\(s.width)×\(s.height)" : FormatShape.of(s.width, s.height)).font(.system(size: 9)).foregroundStyle(.secondary) }
                            if !on {
                                Button { ProjectTabs.closeTab(p); tick += 1 } label: { Image(systemName: "xmark").font(.system(size: 8)) }.buttonStyle(.borderless).help("Close this tab (the project is kept)")
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(on ? Color(white: 0.22) : Color(white: 0.14)).clipShape(RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                        .onTapGesture { ProjectTabs.switchTo(editor, p); tick += 1 }
                        .contextMenu {
                            if on {
                                Button("Rename…") { ProjectActions.rename(editor) }
                                Button("Move to…") { ProjectActions.move(editor) }
                                Button("Duplicate…") { ProjectActions.duplicate(editor) }
                                Button("Versions…") { NotificationCenter.default.post(name: .openVersions, object: nil) }
                                Divider()
                                Button("Close project") { ProjectActions.close(editor); tick += 1 }
                            } else {
                                Button("Open") { ProjectTabs.switchTo(editor, p); tick += 1 }
                                Button("Close tab") { ProjectTabs.closeTab(p); tick += 1 }
                            }
                            Divider()
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
                            Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(p, forType: .string) }
                        }
                        .help(p)
                    }
                }.padding(.horizontal, 6).padding(.vertical, 3)
            }.background(Color(white: 0.1))
        }
    }
}

/// reading project files without opening them (media library, tabs)
enum ProjectFile {
    nonisolated(unsafe) static var cache: [String: (Date, Project)] = [:]
    static func load(_ path: String) -> Project? {
        let d = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        if let c = cache[path], c.0 == d { return c.1 }
        guard let p = try? Project.load(from: URL(fileURLWithPath: path)) else { return nil }
        cache[path] = (d, p); return p
    }
    static func settings(_ path: String) -> CutgenieCore.Settings? { load(path)?.settings }
    static func name(_ path: String) -> String { ((path as NSString).lastPathComponent as NSString).replacingOccurrences(of: ".cutgenie.json", with: "").replacingOccurrences(of: ".cutline.json", with: "") }
    /// the projects in a folder (files starting with "_" are test copies and are left out)
    static func list(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { ($0.hasSuffix(".cutgenie.json") || $0.hasSuffix(".cutline.json")) && !$0.hasPrefix("_") && !$0.hasPrefix(".") }
            .map { dir.appendingPathComponent($0).path }
    }
}
