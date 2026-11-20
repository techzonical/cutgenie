import AppKit
import CutgenieCore

// Full-screen playback (Final Cut's View > Playback > Play Full Screen, ⇧⌘F).
// The picture fills a whole screen - the second monitor when there is one, otherwise this one - with nothing else on it.
// The usual keys keep working (space, arrows, J K L); Esc or ⇧⌘F again leaves.
@MainActor
enum FullscreenPlayer {
    private(set) static var window: NSWindow?
    static var view: DisplayView? { window?.contentView?.subviews.first as? DisplayView }
    static var isOpen: Bool { window != nil }

    final class Win: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override func keyDown(with e: NSEvent) {
            if e.keyCode == 53 { FullscreenPlayer.close() } else { super.keyDown(with: e) }
        }
        override func mouseMoved(with e: NSEvent) { NSCursor.setHiddenUntilMouseMoves(true) }
    }

    static func toggle(_ editor: Editor) { isOpen ? close() : open(editor) }

    static func open(_ editor: Editor, testFrame: NSRect? = nil) {
        guard window == nil else { return }
        let here = NSApp.mainWindow?.screen ?? NSScreen.main
        let screen = NSScreen.screens.first { $0 != here } ?? here ?? NSScreen.screens[0]
        let rect = testFrame ?? screen.frame
        let w = Win(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .statusBar
        w.backgroundColor = .black
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.acceptsMouseMovedEvents = true
        let root = NSView(frame: NSRect(origin: .zero, size: rect.size))
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor.black.cgColor
        let v = DisplayView(frame: root.bounds); v.autoresizingMask = [.width, .height]; v.editor = editor
        root.addSubview(v)
        w.contentView = root
        w.setFrame(rect, display: true)
        window = w
        editor.showFrame = nil                     // live redraws go to the full-screen picture from now on
        if testFrame != nil { w.level = .normal; w.orderBack(nil); refresh(editor); return }
        w.makeKeyAndOrderFront(nil)
        NSCursor.setHiddenUntilMouseMoves(true)
        if screen == here { NSApp.presentationOptions = [.hideDock, .hideMenuBar] }
        refresh(editor)
    }

    static func close() {
        guard let w = window else { return }
        let ed = view?.editor
        window = nil
        NSApp.presentationOptions = []
        w.orderOut(nil)
        ed?.showFrame = nil                        // back to the viewer in the main window
        NSApp.mainWindow?.makeKey()
        if let ed { refresh(ed) }
    }

    /// show the current frame straight away (while paused the player sends no new frame on its own)
    private static func refresh(_ ed: Editor) {
        guard ed.player.rate == 0 else { return }
        let t = ed.player.currentTime().seconds
        // seeking to the same time may hand out no new frame: step one frame away and back
        let f = ed.frameLength
        Task {
            _ = await ed.handle(["cmd": "seek", "time": t > f ? t - f : t + f])
            _ = await ed.handle(["cmd": "seek", "time": t])
        }
    }
}
