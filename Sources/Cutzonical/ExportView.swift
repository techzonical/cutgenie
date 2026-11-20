import SwiftUI
import AppKit
import CutzonicalCore

extension Notification.Name {
    static let openExport = Notification.Name("cutzonical.openExport")
}

/// Export window: pick a ready-made preset or set the file type, codec, size, quality and sound yourself.
struct ExportView: View {
    @ObservedObject var editor: Editor
    var close: () -> Void

    @AppStorage("export.container") private var container = "mp4"
    @AppStorage("export.codec") private var codec = "hevc"
    @AppStorage("export.quality") private var quality = "high"      // low | medium | high | max | custom
    @AppStorage("export.mbps") private var customMbps = 24.0
    @AppStorage("export.size") private var sizeKey = "project"      // project | 2160 | 1440 | 1080 | 720
    @AppStorage("export.audio") private var audio = "aac"
    @AppStorage("export.kbps") private var kbps = 320
    @AppStorage("export.v2") private var migrated = false
    @State private var range = "all"                                  // all | selection
    @State private var message: String?
    @State private var done: URL?

    static let containers: [(id: String, name: String, note: String)] = [
        ("mp4", "MP4", "Plays everywhere: YouTube, phones, web"),
        ("mov", "MOV", "Apple / editing; needed for ProRes"),
        ("m4v", "M4V", "Apple devices (iTunes / TV app)"),
        ("m4a", "M4A", "Sound only, AAC"),
        ("wav", "WAV", "Sound only, uncompressed"),
    ]
    static let codecs: [(id: String, name: String, note: String)] = [
        ("h264", "H.264", "Most compatible"),
        ("hevc", "HEVC (H.265)", "Same quality, about half the size"),
        ("prores422lt", "ProRes 422 LT", "Editing, smaller"),
        ("prores422", "ProRes 422", "Editing master"),
        ("prores422hq", "ProRes 422 HQ", "High-end master"),
        ("prores4444", "ProRes 4444", "Highest quality master"),
    ]
    var audioOnly: Bool { container == "m4a" || container == "wav" }
    var isProRes: Bool { codec.hasPrefix("prores") }
    var allowedCodecs: [String] { container == "mov" ? Self.codecs.map { $0.id } : ["h264", "hevc"] }
    var proj: CutzonicalCore.Settings { editor.project.settings }

    /// output picture size for the chosen size (keeps the project's shape; never larger than asked)
    var outSize: (Int, Int) {
        let w = proj.width, h = proj.height
        guard let s = Int(sizeKey) else { return (w, h) }
        let short = min(w, h)
        guard short != s else { return (w, h) }
        let k = Double(s) / Double(short)
        func even(_ x: Double) -> Int { Int((x / 2).rounded()) * 2 }
        return (even(Double(w) * k), even(Double(h) * k))
    }
    /// bitrate for a quality step, scaled by picture size and frame rate (24 Mbps-ish for 1080p "High", like Final Cut)
    var mbps: Double {
        if quality == "custom" { return customMbps }
        if quality == "smart" { return smartCeiling }
        let (w, h) = outSize
        let px = Double(w * h) / (1920 * 1080) * max(1, proj.fps / 30)
        let table: [String: Double] = ["low": 8, "medium": 16, "high": 24, "max": 40]
        let base: Double = table[quality] ?? 24
        let k: Double = codec == "hevc" ? 0.5 : 1          // HEVC: same look at half the bits (12 Mbps for 1080p High)
        return (base * px * k).rounded()
    }
    /// Smart size: the encoder keeps a set quality (0.78, measured on a 1080p talking-head video: same sharpness as 24 Mbps H.264, text included)
    /// and spends bits only where the picture changes; this is the most it may use
    var smartCeiling: Double { let (w, h) = outSize; return (40 * Double(w * h) / (1920 * 1080) * max(1, proj.fps / 30)).rounded() }
    static let smartQuality = 0.78
    var proResMbps: Double {
        let (w, h) = outSize
        let table: [String: Double] = ["prores422lt": 102, "prores422": 147, "prores422hq": 220, "prores4444": 330]   // 1080p30 Apple figures
        let r: Double = table[codec] ?? 147
        let px: Double = Double(w * h) / (1920 * 1080)
        return r * px * proj.fps / 29.97
    }
    var span: (Double, Double) {
        if range == "selection", let s = editor.selectionSpan { return s }
        return (0, editor.project.totalDuration)
    }
    var estimateMB: Double {
        let secs = span.1 - span.0
        let pcm = container == "wav" || audio == "pcm"
        let a: Double = pcm ? 2.3 : Double(kbps) / 1000
        // Smart size: on talking-head footage it came to ~70 % of HEVC High (about 6.5 Mbps for 1080p)
        let smartAvg = (12 * Double(outSize.0 * outSize.1) / (1920 * 1080) * max(1, proj.fps / 30)) * 0.7
        let v: Double = audioOnly ? 0 : (isProRes ? proResMbps : (quality == "smart" ? smartAvg : mbps))
        return (v + a) * secs / 8
    }
    /// size of the whole export with a preset, for the preset cards
    func sizeFor(_ id: String) -> String {
        let px = Double(outSizeProject.0 * outSizeProject.1) / (1920 * 1080) * max(1, proj.fps / 30), secs = span.1 - span.0
        let v: Double = id == "youtube" ? 12 * px : id == "smart" ? 12 * px * 0.7 : 24 * px
        return "≈ " + fmtSize((v + 0.3) * secs / 8)
    }
    var outSizeProject: (Int, Int) { (proj.width, proj.height) }
    func fmtSize(_ mb: Double) -> String { mb >= 1000 ? String(format: "%.1f GB", mb / 1000) : String(format: "%.0f MB", mb) }
    func fmtTime(_ s: Double) -> String { let t = Int(s.rounded()); return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60) }

    func applyPreset(_ id: String) {
        switch id {
        case "youtube": container = "mp4"; codec = "hevc"; quality = "high"; sizeKey = "project"; audio = "aac"; kbps = 320
        case "smart": container = "mp4"; codec = "hevc"; quality = "smart"; sizeKey = "project"; audio = "aac"; kbps = 256
        case "compatible": container = "mp4"; codec = "h264"; quality = "high"; sizeKey = "project"; audio = "aac"; kbps = 320
        case "small": container = "mp4"; codec = "hevc"; quality = "medium"; sizeKey = "1080"; audio = "aac"; kbps = 192
        case "master": container = "mov"; codec = "prores422"; sizeKey = "project"; audio = "pcm"
        case "audio": container = "wav"; audio = "pcm"
        default: break
        }
    }
    var currentPreset: String? {
        if container == "mp4" && codec == "hevc" && quality == "high" && sizeKey == "project" && audio == "aac" && kbps == 320 { return "youtube" }
        if container == "mp4" && codec == "hevc" && quality == "smart" && sizeKey == "project" { return "smart" }
        if container == "mp4" && codec == "h264" && quality == "high" && sizeKey == "project" && audio == "aac" && kbps == 320 { return "compatible" }
        if container == "mp4" && codec == "hevc" && quality == "medium" && sizeKey == "1080" && audio == "aac" && kbps == 192 { return "small" }
        if container == "mov" && codec == "prores422" && sizeKey == "project" && audio == "pcm" { return "master" }
        if container == "wav" { return "audio" }
        return nil
    }

    var body: some View {
        content.onAppear {
            // the old YouTube preset (H.264 24 Mbps, ~3 GB for 17 min) becomes the new one (HEVC 12 Mbps, about half) once
            if !migrated { if currentPreset == "compatible" { applyPreset("youtube") }; migrated = true }
        }
    }
    static let presetList: [(id: String, title: String, sub: String, icon: String)] = [
        ("youtube", "YouTube", "HEVC MP4 · sharp", "play.rectangle.fill"),
        ("smart", "Smart size", "Smallest file, same look", "wand.and.stars"),
        ("compatible", "Old devices", "H.264 MP4 · plays anywhere", "tv"),
        ("master", "Master", "ProRes 422 MOV · archive", "film.stack"),
        ("audio", "Sound only", "WAV · uncompressed", "waveform"),
    ]

    @State private var fileName = ""
    @State private var folder: URL? = nil
    @AppStorage("export.lastFolder") private var lastFolder = ""
    var saveFolder: URL {
        folder ?? (lastFolder.isEmpty ? nil : URL(fileURLWithPath: lastFolder)).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? editor.projectURL?.deletingLastPathComponent() ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
    }
    var target: URL { saveFolder.appendingPathComponent((fileName.isEmpty ? editor.project.name : fileName).replacingOccurrences(of: "/", with: "-") + "." + container) }

    var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Button { close() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).background(Circle().fill(Color.white.opacity(0.1)))
                }.buttonStyle(.plain).help("Close (Esc)").padding(.trailing, 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export").font(.system(size: 17, weight: .semibold))
                    Text("Pick a preset and press Export · \(formatLabel(proj))").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)
            Divider()
            FittedScroll {
                VStack(alignment: .leading, spacing: 18) {
                    section("Preset") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                            ForEach(Self.presetList, id: \.id) { p in presetTile(p) }
                        }
                    }
                    section("Name") { TextField(editor.project.name, text: $fileName).textFieldStyle(.roundedBorder).font(.system(size: 13)) }
                    section("Save in") {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill").font(.system(size: 20)).foregroundStyle(Brand.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(saveFolder.lastPathComponent).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Text(folder == nil && !lastFolder.isEmpty ? "Where you exported last time" : folder == nil ? "Same folder as the project" : "Folder you chose")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }.help(saveFolder.path)
                            Spacer()
                            Button("Choose another folder…") { if let d = chooseFolder("Save the export in", start: saveFolder) { folder = d } }
                        }
                        .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                        let exists = FileManager.default.fileExists(atPath: target.path)
                        Text(exists ? "“\(target.lastPathComponent)” is already there and will be replaced." : "Creates \(target.lastPathComponent)")
                            .font(.system(size: 11)).foregroundStyle(exists ? Color.orange : Color.secondary)
                    }
                    if !audioOnly {
                        section("Video") {
                            HStack(spacing: 6) {
                                ForEach(Self.codecs.filter { allowedCodecs.contains($0.id) || $0.id.hasPrefix("prores") }, id: \.id) { c in
                                    chip(c.name, on: codec == c.id) { if c.id.hasPrefix("prores") && container != "mov" { setContainer("mov") }; codec = c.id }
                                }
                            }
                            note(Self.codecs.first { $0.id == codec }?.note ?? "")
                        }
                        HStack(alignment: .top, spacing: 28) {
                            if !isProRes {
                                section("Quality") {
                                    HStack(spacing: 6) {
                                        ForEach([("low", "Low"), ("medium", "Medium"), ("high", "High"), ("max", "Max"), ("smart", "Smart")], id: \.0) { q in chip(q.1, on: quality == q.0) { quality = q.0 } }
                                    }
                                    note(quality == "smart" ? "Same look as High, smallest file" : "\(Int(mbps)) Mbps")
                                }
                            }
                            section("Size") {
                                HStack(spacing: 6) {
                                    chip("Project", on: sizeKey == "project") { sizeKey = "project" }
                                    ForEach(["2160", "1080", "720"].filter { Int($0)! != min(proj.width, proj.height) }, id: \.self) { k in chip(k == "2160" ? "4K" : "\(k)p", on: sizeKey == k) { sizeKey = k } }
                                }
                                note("\(outSize.0)×\(outSize.1) · \(Editor.fpsName(proj.fps)) fps")
                            }
                        }
                    }
                    HStack(alignment: .top, spacing: 28) {
                        section("Sound") {
                            HStack(spacing: 6) {
                                if container == "wav" { chip("Uncompressed WAV", on: true) {} }
                                else {
                                    ForEach([192, 256, 320], id: \.self) { k in chip("AAC \(k)", on: audio == "aac" && kbps == k) { audio = "aac"; kbps = k } }
                                    if container == "mov" { chip("Uncompressed", on: audio == "pcm") { audio = "pcm" } }
                                }
                            }
                        }
                        section("Range") {
                            HStack(spacing: 6) {
                                chip("Whole timeline", on: range == "all") { range = "all" }
                                chip("Selected clips", on: range == "selection") { if editor.selectionSpan != nil { range = "selection" } }.opacity(editor.selectionSpan == nil ? 0.4 : 1)
                            }
                            note("\(fmtTime(span.0)) – \(fmtTime(span.1))")
                        }
                    }
                }.padding(22)
            }
            Divider()
            footer.padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 700, height: fitScreen(720))
        .onExitCommand { close() }
        .onAppear {
            if !allowedCodecs.contains(codec) { codec = "hevc" }
            if container != "mov" && audio == "pcm" { audio = "aac" }
        }
    }

    /// a preset as a card: icon, name, file size for this video
    func presetTile(_ p: (id: String, title: String, sub: String, icon: String)) -> some View {
        let on = currentPreset == p.id
        let size = ["youtube", "smart", "compatible"].contains(p.id) ? sizeFor(p.id).replacingOccurrences(of: "≈ ", with: "") : (p.id == "master" ? "ProRes" : "WAV")
        return Button { applyPreset(p.id); if p.id == "audio" { setContainer("wav") } } label: {
            VStack(spacing: 6) {
                Image(systemName: p.icon).font(.system(size: 18)).foregroundStyle(on ? Brand.onAccent : Brand.accent).frame(height: 22)
                Text(p.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(size).font(.system(size: 10).monospacedDigit()).foregroundStyle(on ? Brand.onAccent.opacity(0.8) : .secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Brand.accent : Color(white: 0.17)))
            .foregroundStyle(on ? Brand.onAccent : Color.primary)
        }.buttonStyle(.plain).help(p.sub)
    }

    var footer: some View {
        HStack(spacing: 12) {
            if let p = editor.exportProgress {
                ProgressView(value: p).frame(maxWidth: .infinity)
                Text("\(Int(p * 100)) %").font(.system(size: 11).monospacedDigit()).frame(width: 40)
                Button("Stop") { editor.cancelExport() }
                Button("Keep editing") { close() }.keyboardShortcut(.defaultAction)
                    .help("Close this window; the export carries on and its progress shows above the viewer")
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    if let m = message { Text(m).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2) }
                    else if let d = done {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text(d.lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([d]) }.buttonStyle(.link).font(.system(size: 11))
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text((quality == "smart" && !isProRes && !audioOnly ? "≈ " : "About ") + fmtSize(estimateMB)).font(.system(size: 14, weight: .semibold).monospacedDigit())
                            Text("for \(fmtTime(span.1 - span.0))").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Button("Close") { close() }.keyboardShortcut(.cancelAction)
                Button("Export") { start() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Brand.accent).foregroundStyle(Brand.onAccent)
            }
        }
    }
    func setContainer(_ c: String) {
        container = c
        if !allowedCodecs.contains(codec) { codec = "h264" }
        if c != "mov" && audio == "pcm" { audio = "aac" }
        if c == "wav" { audio = "pcm" }
    }

    func start() {
        let url = target
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        lastFolder = url.deletingLastPathComponent().path
        var o = ExportOptions()
        o.container = container; o.codec = codec; o.bitrateMbps = mbps
        if quality == "smart" && !isProRes { o.quality = Self.smartQuality }
        if sizeKey != "project" { o.width = outSize.0; o.height = outSize.1 }
        o.audio = container == "wav" ? "pcm" : audio; o.audioKbps = kbps
        if range == "selection", let s = editor.selectionSpan { o.from = s.0; o.to = s.1 }
        message = nil; done = nil
        Task {
            do { try await editor.exportFile(url, o); done = url }
            catch { message = "\(error)" == "export cancelled" ? "Stopped." : "\(error)" }
        }
    }

    func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
            c()
        }
    }
    func note(_ t: String) -> some View { Text(t).font(.system(size: 10)).foregroundStyle(.secondary) }
    func chip(_ t: String, on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(.system(size: 11, weight: on ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(on ? Brand.accent : Color(white: 0.2)).foregroundStyle(on ? Brand.onAccent : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }
}
