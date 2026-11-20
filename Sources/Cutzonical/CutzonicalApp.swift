import SwiftUI
import AVFoundation
import AppKit
import CutzonicalCore

@main
struct CutzonicalApp: App {
    @StateObject private var editor = Editor()
    private let holder = ServerHolder()

    var body: some Scene {
        WindowGroup("Cutzonical") {
            ContentView(editor: editor)
                .frame(minWidth: 1100, minHeight: 700)
                .task { await boot() }
        }
        .commands {
            // Cmd+Z / Cmd+Shift+Z / Cmd+S / Cmd+O go through the menu so macOS routes them correctly.
            CommandGroup(after: .toolbar) {
                Button("Bigger timeline") { NotificationCenter.default.post(name: .focusArea, object: "timeline") }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Bigger viewer") { NotificationCenter.default.post(name: .focusArea, object: "viewer") }.keyboardShortcut("f", modifiers: [.command, .shift, .option])
                Button("Play full screen") { NotificationCenter.default.post(name: .fullscreenPlay, object: nil) }.keyboardShortcut("f", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard shortcuts") { NotificationCenter.default.post(name: .openShortcuts, object: nil) }.keyboardShortcut("/", modifiers: .command)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { send("undo") }.keyboardShortcut("z", modifiers: .command)
                Button("Redo") { send("redo") }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { send("save") }.keyboardShortcut("s", modifiers: .command)
                Button("Save as…") { saveAsPanel(editor) }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button("New project…") { NotificationCenter.default.post(name: .newProject, object: nil) }.keyboardShortcut("n", modifiers: .command)
                Button("Open…") { openPanel(editor) }.keyboardShortcut("o", modifiers: .command)
                Button("All projects…") { NotificationCenter.default.post(name: .openBrowser, object: nil) }.keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Rename project…") { ProjectActions.rename(editor) }
                Button("Move project to…") { ProjectActions.move(editor) }
                Button("Duplicate project…") { ProjectActions.duplicate(editor) }
                Button("Versions…") { NotificationCenter.default.post(name: .openVersions, object: nil) }
                Button("Reveal in Finder") { ProjectActions.reveal(editor) }.keyboardShortcut("r", modifiers: [.command, .shift, .option])
                Divider()
                Button("Relink media…") { ProjectActions.relink(editor) }
                Button("Collect media…") { ProjectActions.collect(editor) }
                Divider()
                Button("Close project") { ProjectActions.close(editor) }.keyboardShortcut("w", modifiers: [.command, .shift])
                Button("Move project to Trash…") { ProjectActions.trash(editor) }
                Divider()
                Button("Project settings…") { NotificationCenter.default.post(name: .openProjectSettings, object: nil) }.keyboardShortcut("j", modifiers: .command)
                Divider()
                Button("Export…") { NotificationCenter.default.post(name: .openExport, object: nil) }.keyboardShortcut("e", modifiers: .command)
            }
            CommandMenu("Graphics") {
                Button("Add text") { Task { _ = await editor.handle(["cmd": "add_text"]) } }.keyboardShortcut("t", modifiers: .control)
                Button("Graph editor (keyframe curves)") { NotificationCenter.default.post(name: .toggleGraph, object: nil) }.keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Menu("Add title") {
                    let _ = editor.titleTick
                    if Titles.names.isEmpty { Text("No saved titles yet: select text / shape layers, then Effects ▸ ⋯ ▸ Save as title") }
                    ForEach(Titles.names, id: \.self) { n in
                        Button { Task { _ = await editor.handle(["cmd": "add_title", "name": n]) } } label: {
                            if let i = Titles.thumbnail(n) { Label { Text(n) } icon: { Image(nsImage: i.resized(96)) } } else { Text(n) }
                        }
                    }
                    if !Titles.names.isEmpty {
                        Divider()
                        Menu("Delete title") { ForEach(Titles.names, id: \.self) { n in Button(n) { Task { _ = await editor.handle(["cmd": "delete_title", "name": n]) } } } }
                    }
                }
                Menu("Add shape") {
                    ForEach(ShapeSpec.kinds, id: \.id) { k in Button(k.name) { Task { _ = await editor.handle(["cmd": "add_shape", "kind": k.id]) } } }
                }
            }
        }
    }

    func send(_ cmd: String) { let ed = editor; Task { @MainActor in let r = await ed.handle(["cmd": cmd]); if cmd == "save", r["ok"] as? Bool == true { ed.lastMessage = "Saved" } } }

    @MainActor func boot() async {
        guard holder.server == nil else { return }
        let ed = editor
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { ed.autosave(); Log.write("quit"); ed.releaseLock() } }
        let port = UInt16(ProcessInfo.processInfo.environment["CUTZONICAL_PORT"] ?? "") ?? 7878
        // the test copy (check suite) runs in the background: keep macOS from slowing it down (App Nap), so timings are real
        if ProcessInfo.processInfo.environment["CUTZONICAL_AWAKE"] != nil {
            holder.activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Cutzonical check suite")
        }
        // the main Cutzonical reopens the project it last had open (test copies on other ports start empty)
        if port == 7878, let last = UserDefaults.standard.string(forKey: "lastProject"), FileManager.default.fileExists(atPath: last) {
            Task { @MainActor in if ed.projectURL == nil { _ = await ed.handle(["cmd": "open", "path": last]) } }
        }
        do {
            let ed = editor
            let s = try ControlServer(port: port) { cmd in await ed.handle(cmd) }
            s.start { msg in DispatchQueue.main.async { ed.lastMessage = "Control server \(msg) :\(port)" } }
            holder.server = s
            ed.pointerImage = { path in
                // testing aid: all timeline pointers side by side on grey
                let all = [PointerStyleMod.bladeImage, Cursors.trimStart, Cursors.trimEnd, Cursors.roll, Cursors.slip, Cursors.slide, Cursors.pen]
                let im = NSImage(size: NSSize(width: 44 * all.count, height: 44), flipped: false) { r in
                    NSColor(white: 0.35, alpha: 1).setFill(); r.fill()
                    for (i, c) in all.enumerated() { c.draw(in: NSRect(x: CGFloat(i) * 44 + (44 - c.size.width) / 2, y: (44 - c.size.height) / 2, width: c.size.width, height: c.size.height)) }
                    return true
                }
                guard let tiff = im.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return false }
                return (try? png.write(to: URL(fileURLWithPath: path))) != nil
            }
            ed.uiOpen = { what in
                let n: [String: Notification.Name] = ["export": .openExport, "new": .newProject, "browser": .openBrowser, "versions": .openVersions,
                                                      "shortcuts": .openShortcuts, "settings": .openProjectSettings, "graph": .toggleGraph]
                guard let name = n[what] else { return false }
                NotificationCenter.default.post(name: name, object: nil); return true
            }
            ed.uiWindowID = {
                guard let main = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.sheetParent == nil }) else { return 0 }
                return (main.attachedSheet ?? main).windowNumber
            }
            ed.uiPNG = { path in
                guard let main = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.sheetParent == nil }) else { return false }
                let w = main.attachedSheet ?? main
                guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
                v.cacheDisplay(in: v.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { return false }
                return (try? png.write(to: URL(fileURLWithPath: path))) != nil
            }
            ed.uiKey = { key, mods in
                guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return false }
                var flags: NSEvent.ModifierFlags = []
                if mods.contains("shift") { flags.insert(.shift) }; if mods.contains("command") { flags.insert(.command) }; if mods.contains("option") { flags.insert(.option) }
                let named: [String: (UInt16, String)] = ["space": (49, " "), "left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "up": (126, "\u{F700}"),
                    "down": (125, "\u{F701}"), "home": (115, "\u{F729}"), "end": (119, "\u{F72B}"), "delete": (51, "\u{7F}"), "escape": (53, "\u{1B}")]
                let (code, ch) = named[key] ?? (0, key)
                guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: w.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) else { return false }
                NSApp.sendEvent(e)
                return true
            }
            ed.uiScroll = { pt, dy, mods in
                guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let cv = w.contentView else { return false }
                let winPt = NSPoint(x: pt.x, y: cv.bounds.height - pt.y)
                let scr = w.convertPoint(toScreen: winPt)
                let screenH = NSScreen.screens.first?.frame.height ?? 0
                let precise = mods.contains("precise")
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 2, wheel1: mods.contains("shift") ? 0 : Int32(dy), wheel2: mods.contains("shift") ? Int32(dy) : 0, wheel3: 0) else { return false }
                cg.location = CGPoint(x: scr.x, y: screenH - scr.y)
                var fl: CGEventFlags = [.maskNonCoalesced]
                if mods.contains("shift") { fl.insert(.maskShift) }; if mods.contains("command") { fl.insert(.maskCommand) }
                cg.flags = fl
                guard let e = NSEvent(cgEvent: cg) else { return false }
                // move the pointer there first (hover -> skimmer), then scroll
                if let mv = NSEvent.mouseEvent(with: .mouseMoved, location: winPt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { NSApp.sendEvent(mv) }
                NSApp.postEvent(e, atStart: false)
                if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(wake, atStart: false) }   // through the event queue, like a real wheel, so the timeline's wheel handler sees it
                return true
            }
            ed.uiMouse = { pts, mods in
                guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let cv = w.contentView else { return false }
                var flags: NSEvent.ModifierFlags = []
                if mods.contains("shift") { flags.insert(.shift) }; if mods.contains("command") { flags.insert(.command) }; if mods.contains("option") { flags.insert(.option) }
                func send(_ type: NSEvent.EventType, _ p: CGPoint) {
                    let loc = NSPoint(x: p.x, y: cv.bounds.height - p.y)   // window coords are bottom-left
                    if let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                        w.sendEvent(e)
                    }
                }
                if mods.contains("moveonly") { send(.mouseMoved, pts[0]); return true }
                if mods.contains("real") {
                    // real-style input: CGEvents delivered through the window server to this app (pointer moves, hovers, then clicks)
                    let sf = w.convertToScreen(cv.convert(cv.bounds, to: nil))
                    let screenH = NSScreen.screens.first?.frame.height ?? 0
                    func g(_ p: CGPoint) -> CGPoint { CGPoint(x: sf.minX + p.x, y: screenH - (sf.minY + (cv.bounds.height - p.y))) }
                    let pid = ProcessInfo.processInfo.processIdentifier
                    func post(_ t: CGEventType, _ p: CGPoint) { CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: g(p), mouseButton: .left)?.postToPid(pid) }
                    post(.mouseMoved, pts[0])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        post(.leftMouseDown, pts[0])
                        for p in pts.dropFirst() { post(.leftMouseDragged, p) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { post(.leftMouseUp, pts.last!) }
                    }
                    return true
                }
                send(.mouseMoved, pts[0]); send(.leftMouseDown, pts[0])
                for p in pts.dropFirst() { send(.leftMouseDragged, p) }
                send(.leftMouseUp, pts.last!)
                return true
            }
            ed.snapshotUI = { mode, path in
                // testing: a small full-screen player window behind everything, and a capture of it
                if mode == "fs_open" { FullscreenPlayer.open(ed, testFrame: NSRect(x: 40, y: 40, width: 640, height: 360)); return true }
                if mode.hasPrefix("vz:") { let v = Double(mode.dropFirst(3)); ViewerZoom.shared.zoom = nil; ViewerZoom.shared.pan = .zero; if let v { ViewerZoom.shared.set(v) }; return true }
                if mode.hasPrefix("live_text:") {      // testing: live-change a text layer's words, then make it one undo step
                    let parts = mode.dropFirst(10).split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { return false }
                    ed.liveLayers([parts[0]]) { l in if var t = l.text { t.runs[0].text = parts[1]; l.text = t } }
                    if path == "commit" { ed.commitLive() }
                    return true
                }
                if mode == "fs_close" { FullscreenPlayer.close(); return true }
                if mode == "fs_shot" {
                    guard let w = FullscreenPlayer.window, let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming]),
                          let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return false }
                    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
                }
                if mode == "open_shortcuts" { NotificationCenter.default.post(name: .openShortcuts, object: nil); return true }
                if mode == "sheet" {      // the window open on top (Export, shortcuts...)
                    guard let sh = NSApp.windows.compactMap({ $0.attachedSheet }).first, let v = sh.contentView,
                          let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    return (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))) != nil
                }
                if mode == "screen" {   // what the window server composites for this app's own window, video included
                    guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                          let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming]) else { return false }
                    guard let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return false }
                    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
                }
                // the app's own real window (all controls included); an app may capture itself without screen permission
                guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let v = w.contentView,
                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
                v.cacheDisplay(in: v.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { return false }
                return (try? png.write(to: URL(fileURLWithPath: path))) != nil
            }
        } catch { editor.lastMessage = "Control server could not start: \(error)" }
        if let p = CommandLine.arguments.dropFirst().first(where: { $0.hasSuffix(".json") }) {
            do { try await editor.open(p) } catch { editor.lastMessage = "Open failed: \(error)" }
        }
    }
}

/// Save as: a copy of the project under a new name / place; from then on you work in the new file
@MainActor func saveAsPanel(_ editor: Editor) {
    let p = NSSavePanel()
    p.nameFieldStringValue = (editor.project.name.isEmpty ? "Untitled" : editor.project.name) + " copy.cutzonical.json"
    p.message = "Save the project as a new file"
    if let u = editor.projectURL?.deletingLastPathComponent() { p.directoryURL = u }
    guard p.runModal() == .OK, var u = p.url else { return }
    if !u.lastPathComponent.hasSuffix(".cutzonical.json") { u = u.deletingPathExtension().appendingPathExtension("cutzonical.json") }
    Task { let r = await editor.handle(["cmd": "save", "path": u.path]); if let e = r["error"] as? String { editor.lastMessage = "Save failed: \(e)" } else { editor.lastMessage = "Saved as \(u.lastPathComponent)" } }
}

@MainActor func openPanel(_ editor: Editor) {
    let p = NSOpenPanel()
    p.allowedContentTypes = [.json]
    if p.runModal() == .OK, let u = p.url {
        Task { do { try await editor.open(u.path) } catch { editor.lastMessage = "Open failed: \(error)" } }
    }
}

final class ServerHolder { var server: ControlServer?; var activity: NSObjectProtocol? }

// On-screen video. Frames come from the player's video output (the finished, graded picture) and are shown through an
// AVSampleBufferDisplayLayer after being labelled Rec.709. AVPlayerLayer would label them with the camera's original
// HLG tags, which makes the screen interpret already-converted Rec.709 numbers as HLG (looks wrong after a LUT).
final class DisplayView: NSView {
    weak var editor: Editor?
    let display = AVSampleBufferDisplayLayer()
    var link: CADisplayLink?
    var lastSeq = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        display.videoGravity = .resizeAspect
        display.backgroundColor = NSColor.black.cgColor
        layer = display
    }
    required init?(coder: NSCoder) { fatalError() }

    // mouse in the picture -> viewer selection / handles (TransformHandles). 0 = down, 1 = dragged, 2 = up; top-left points
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func send(_ phase: Int, _ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        TransformHandles.mouse?(phase, CGPoint(x: p.x, y: bounds.height - p.y), bounds.size)
    }
    override func mouseDown(with e: NSEvent) { send(0, e) }
    override func mouseDragged(with e: NSEvent) { send(1, e) }
    override func mouseUp(with e: NSEvent) { send(2, e) }
    // 3 = the pointer moves over the picture without a button: the pointer shape shows what a drag there would do
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with e: NSEvent) { send(3, e) }
    override func mouseExited(with e: NSEvent) { NSCursor.arrow.set() }
    override func viewDidMoveToWindow() {
        link?.invalidate(); link = nil
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    static let kernel: CIColorKernel? = {
        guard let url = Bundle.main.url(forResource: "ColorKernels", withExtension: "metallib"), let d = try? Data(contentsOf: url) else { return nil }
        return try? CIColorKernel(functionName: "cutzonicalDisplay", fromMetalLibraryData: d)
    }()
    let ciContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    @objc func tick(_ l: CADisplayLink) {
        guard let ed = editor, let vo = ed.playerOutput else { return }
        if let fs = FullscreenPlayer.view, fs !== self { return }   // full screen is showing the picture
        let t = vo.itemTime(forHostTime: CACurrentMediaTime())
        guard vo.hasNewPixelBuffer(forItemTime: t), let pb = vo.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return }
        // live edits redraw frames themselves: hand them a way to put a picture on screen
        if ed.showFrame == nil { ed.showFrame = { [weak self] pb in DispatchQueue.main.async { self?.show(pb) } } }
        show(pb)
    }
    /// window display path (display curve / warmth, colour tags) for a finished frame - from the player or a live redraw
    // the display curve is drawn off the main thread (it used to cost the main thread ~10% while playing),
    // into buffers from a pool instead of a new buffer every frame
    let drawQ = DispatchQueue(label: "cutzonical.display", qos: .userInteractive)
    var pool: CVPixelBufferPool?
    var poolSize = CGSize.zero
    nonisolated(unsafe) var pending = 0
    func show(_ src: CVPixelBuffer) {
        guard let ed = editor else { return }
        let g = ed.displayGamma, w = ed.displayWarmth
        let w0 = CVPixelBufferGetWidth(src), h0 = CVPixelBufferGetHeight(src)
        if CGSize(width: w0, height: h0) != poolSize {
            poolSize = CGSize(width: w0, height: h0); pool = nil
            CVPixelBufferPoolCreate(nil, nil, [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w0,
                                               kCVPixelBufferHeightKey as String: h0, kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pool)
        }
        guard pending < 2 else { return }          // never queue up a backlog: drop a frame instead
        pending += 1
        let pl = pool, ctx = ciContext
        drawQ.async { [weak self] in
            defer { DispatchQueue.main.async { self?.pending -= 1 } }
            var pb = src
            if (abs(g - 1) > 0.001 || w != 0), let k = DisplayView.kernel, let pl {
                let s = CIImage(cvPixelBuffer: pb, options: [.colorSpace: NSNull()])
                if let out = k.apply(extent: s.extent, arguments: [s, g, CIVector(x: 1 + 0.01 * w, y: 1, z: 1 - 0.01 * w)]) {
                    var dst: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pl, &dst)
                    if let dst { ctx.render(out, to: dst); pb = dst }
                }
            }
            self?.enqueue(pb)
        }
    }
    nonisolated func enqueue(_ src: CVPixelBuffer) {
        var pb = src
        // P3 primaries + sRGB curve = the native colours of a MacBook display, so macOS does not remap colours (Final Cut's viewer
        // shows these numbers with no gamut change either).
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        var fd: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fd)
        guard let fd else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary] {
            arr.first?[kCMSampleAttachmentKey_DisplayImmediately as String] = true
        }
        if display.status == .failed { display.flush() }
        display.enqueue(sb)
    }
}

struct PlayerSurface: NSViewRepresentable {
    let editor: Editor
    func makeNSView(context: Context) -> DisplayView { let v = DisplayView(frame: .zero); v.editor = editor; return v }
    func updateNSView(_ v: DisplayView, context: Context) { v.editor = editor }
}

extension NSImage {
    /// a copy scaled to `w` points wide (menu pictures)
    func resized(_ w: CGFloat) -> NSImage {
        let h = size.width > 0 ? size.height * w / size.width : w
        let n = NSImage(size: NSSize(width: w, height: h))
        n.lockFocus(); draw(in: NSRect(x: 0, y: 0, width: w, height: h)); n.unlockFocus()
        return n
    }
}
