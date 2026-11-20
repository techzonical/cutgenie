import SwiftUI
import AppKit

extension Notification.Name {
    static let openShortcuts = Notification.Name("cutgenie.openShortcuts")
}

/// Keyboard shortcuts drawn on a keyboard. Keys that do something are coloured by kind; hold ⇧ ⌘ ⌥ ⌃ (or click them)
/// to see what the keys do with that modifier; point at a key to see everything it does.
struct KeyboardMap: View {
    var close: () -> Void

    enum Kind: String, CaseIterable { case play = "Playback", edit = "Editing", tools = "Tools", marks = "Markers", view = "View & file"
        var color: Color {
            switch self {
            case .play: return Color(red: 0.36, green: 0.56, blue: 0.86)
            case .edit: return Color(red: 0.86, green: 0.55, blue: 0.30)
            case .tools: return Color(red: 0.62, green: 0.46, blue: 0.84)
            case .marks: return Color(red: 0.38, green: 0.70, blue: 0.48)
            case .view: return Color(red: 0.55, green: 0.58, blue: 0.62)
            }
        }
    }
    struct Shortcut { let key: String; let mods: String; let label: String; let kind: Kind }

    // mods spelled in Mac order: ⌃ ⌥ ⇧ ⌘
    static let all: [Shortcut] = [
        .init(key: "space", mods: "", label: "Play / pause", kind: .play),
        .init(key: "j", mods: "", label: "Reverse", kind: .play), .init(key: "k", mods: "", label: "Stop", kind: .play),
        .init(key: "l", mods: "", label: "Forward", kind: .play),
        .init(key: "left", mods: "", label: "Frame −1", kind: .play), .init(key: "right", mods: "", label: "Frame +1", kind: .play),
        .init(key: "left", mods: "⇧", label: "Frame −10", kind: .play), .init(key: "right", mods: "⇧", label: "Frame +10", kind: .play),
        .init(key: "up", mods: "", label: "Prev edit", kind: .play), .init(key: "down", mods: "", label: "Next edit", kind: .play),
        .init(key: "home", mods: "", label: "Start", kind: .play), .init(key: "end", mods: "", label: "End", kind: .play),

        .init(key: "b", mods: "⌘", label: "Blade", kind: .edit), .init(key: "b", mods: "⇧", label: "Blade all", kind: .edit),
        .init(key: "b", mods: "⇧⌘", label: "Blade all", kind: .edit),
        .init(key: "[", mods: "⌥", label: "Trim start", kind: .edit), .init(key: "]", mods: "⌥", label: "Trim end", kind: .edit),
        .init(key: "delete", mods: "", label: "Delete", kind: .edit), .init(key: "delete", mods: "⇧", label: "Lift (gap)", kind: .edit),
        .init(key: ",", mods: "", label: "Nudge ←", kind: .edit), .init(key: ".", mods: "", label: "Nudge →", kind: .edit),
        .init(key: ",", mods: "⇧", label: "Nudge 10 ←", kind: .edit), .init(key: ".", mods: "⇧", label: "Nudge 10 →", kind: .edit),
        .init(key: "c", mods: "⌘", label: "Copy", kind: .edit), .init(key: "x", mods: "⌘", label: "Cut", kind: .edit),
        .init(key: "v", mods: "⌘", label: "Paste", kind: .edit), .init(key: "a", mods: "⌘", label: "Select all", kind: .edit),
        .init(key: "s", mods: "⌃⇧", label: "Detach audio", kind: .edit), .init(key: "l", mods: "⌘", label: "Link / unlink", kind: .edit),
        .init(key: "g", mods: "⌘", label: "Group", kind: .edit), .init(key: "g", mods: "⇧⌘", label: "Ungroup", kind: .edit),
        .init(key: "g", mods: "⌥⌘", label: "Sync by sound", kind: .edit),
        .init(key: "w", mods: "", label: "Insert", kind: .edit), .init(key: "e", mods: "", label: "Append", kind: .edit),
        .init(key: "c", mods: "", label: "Pick clip", kind: .edit), .init(key: "v", mods: "", label: "Clip off / on", kind: .edit), .init(key: "esc", mods: "", label: "Deselect", kind: .edit),
        .init(key: "z", mods: "⌘", label: "Undo", kind: .edit), .init(key: "z", mods: "⇧⌘", label: "Redo", kind: .edit),

        .init(key: "a", mods: "", label: "Select", kind: .tools), .init(key: "b", mods: "", label: "Blade", kind: .tools),
        .init(key: "t", mods: "", label: "Trim", kind: .tools), .init(key: "p", mods: "", label: "Pen", kind: .tools),
        .init(key: "z", mods: "", label: "Zoom", kind: .tools), .init(key: "h", mods: "", label: "Hand", kind: .tools),
        .init(key: "s", mods: "", label: "Skimming", kind: .tools), .init(key: "n", mods: "", label: "Snapping", kind: .tools),
        .init(key: "p", mods: "⌥", label: "Magnetic", kind: .tools),
        .init(key: "i", mods: "", label: "Mark in", kind: .tools), .init(key: "o", mods: "", label: "Mark out", kind: .tools),

        .init(key: "m", mods: "", label: "Marker", kind: .marks), .init(key: "m", mods: "⌥", label: "Named marker", kind: .marks),
        .init(key: "'", mods: "⌃", label: "Next marker", kind: .marks), .init(key: ";", mods: "⌃", label: "Prev marker", kind: .marks),

        .init(key: "=", mods: "⌘", label: "Zoom in", kind: .view), .init(key: "-", mods: "⌘", label: "Zoom out", kind: .view),
        .init(key: "z", mods: "⇧", label: "Fit timeline", kind: .view), .init(key: "1", mods: "⌘", label: "Media panel", kind: .view), .init(key: "t", mods: "⇧⌘", label: "Big timeline", kind: .view), .init(key: "f", mods: "⇧⌘", label: "Full screen", kind: .view), .init(key: "t", mods: "⌃", label: "Add text", kind: .view), .init(key: "f", mods: "⌥⇧⌘", label: "Big viewer", kind: .view),
        .init(key: "s", mods: "⌘", label: "Save", kind: .view), .init(key: "s", mods: "⇧⌘", label: "Save as", kind: .view),
        .init(key: "o", mods: "⌘", label: "Open", kind: .view), .init(key: "n", mods: "⌘", label: "New project", kind: .view),
        .init(key: "j", mods: "⌘", label: "Settings", kind: .view), .init(key: "e", mods: "⌘", label: "Export", kind: .view),
        .init(key: "/", mods: "⌘", label: "Shortcuts", kind: .view),
    ]
    static let mouse: [(String, String)] = [
        ("⌘-click", "Add / remove one clip"), ("⇧-click", "Select a range"), ("⌥-click", "Pick one of linked clips"),
        ("⌥-drag", "Drag a copy"), ("Drag empty space", "Selection box"), ("⌘-scroll / pinch", "Zoom timeline"),
        ("Drag a clip edge", "Trim"), ("Double-click marker", "Rename it"),
    ]

    @State private var mods = ""          // modifier shown on the keys
    @State private var held = ""          // physically held modifiers
    @State private var hover: String?
    @State private var only: Kind?
    @State private var monitor: Any?
    @State private var showMine = false

    var shown: String { held.isEmpty ? mods : held }
    func shortcuts(_ key: String) -> [Shortcut] { Self.all.filter { $0.key == key } }
    func current(_ key: String) -> Shortcut? {
        guard let s = Self.all.first(where: { $0.key == key && $0.mods == shown }) else { return nil }
        return only == nil || only == s.kind ? s : nil
    }

    // keyboard rows: (key id, printed label, width in units)
    typealias K = (id: String, cap: String, w: Double)
    static let rows: [[K]] = [
        [("esc", "esc", 1.4)] + "1234567890".map { (String($0), String($0), 1.0) } + [("-", "–", 1), ("=", "=", 1), ("delete", "⌫", 1.6)],
        [("tab", "⇥", 1.5)] + "qwertyuiop".map { (String($0), String($0).uppercased(), 1.0) } + [("[", "[", 1), ("]", "]", 1), ("\\", "\\", 1.1)],
        [("caps", "⇪", 1.8)] + "asdfghjkl".map { (String($0), String($0).uppercased(), 1.0) } + [(";", ";", 1), ("'", "'", 1), ("return", "↩", 1.8)],
        [("shift", "⇧", 2.3)] + "zxcvbnm".map { (String($0), String($0).uppercased(), 1.0) } + [(",", ",", 1), (".", ".", 1), ("/", "/", 1), ("rshift", "⇧", 2.3)],
        [("ctrl", "⌃", 1.25), ("opt", "⌥", 1.25), ("cmd", "⌘", 1.5), ("space", "", 5.6), ("rcmd", "⌘", 1.5), ("ropt", "⌥", 1.25)],
    ]
    static let modKeys: [String: String] = ["shift": "⇧", "rshift": "⇧", "cmd": "⌘", "rcmd": "⌘", "opt": "⌥", "ropt": "⌥", "ctrl": "⌃"]

    var body: some View {
        map.sheet(isPresented: $showMine) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("My keys").font(.system(size: 17, weight: .semibold)); Spacer(); Button("Done") { showMine = false }.keyboardShortcut(.defaultAction) }
                ShortcutEditor()
            }.padding(20).frame(width: 620, height: 560)
        }
    }
    var map: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Button { close() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).background(Circle().fill(Color.white.opacity(0.1)))
                }.buttonStyle(.plain).help("Close (Esc)").padding(.trailing, 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keyboard shortcuts").font(.system(size: 17, weight: .semibold))
                    Text("Hold ⇧ ⌘ ⌥ ⌃ or click them to see more. Point at a key for details.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showMine = true } label: { Label("My keys…", systemImage: "keyboard.badge.ellipsis") }
                    .help("Give any action your own key").padding(.trailing, 8)
                HStack(spacing: 4) {
                    ForEach(["", "⇧", "⌘", "⌥", "⌃", "⇧⌘", "⌥⌘", "⌃⇧"], id: \.self) { m in
                        Button { mods = m } label: {
                            Text(m.isEmpty ? "No modifier" : m).font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 5).fill(shown == m ? Brand.chipOn : Color.white.opacity(0.07)))
                                .foregroundStyle(shown == m ? Brand.onAccent : Color.primary)
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14)
            Divider()
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 6) {
                    ForEach(0..<Self.rows.count, id: \.self) { r in
                        HStack(spacing: 6) { ForEach(Self.rows[r], id: \.id) { k in keyCap(k) } }
                    }
                }
                VStack(spacing: 6) {
                    HStack(spacing: 6) { keyCap(("home", "↖", 1)); keyCap(("end", "↘", 1)) }
                    Spacer().frame(height: 46 * 2 + 6)
                    keyCap(("up", "↑", 1))
                    HStack(spacing: 6) { keyCap(("left", "←", 1)); keyCap(("down", "↓", 1)); keyCap(("right", "→", 1)) }
                }
            }.padding(22)
            detail.padding(.horizontal, 22)
            HStack(spacing: 8) {
                ForEach(Kind.allCases, id: \.self) { k in
                    Button { only = only == k ? nil : k } label: {
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(k.color).frame(width: 10, height: 10)
                            Text(k.rawValue).font(.system(size: 11))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(only == k ? Color.white.opacity(0.14) : Color.clear))
                        .opacity(only == nil || only == k ? 1 : 0.45)
                    }.buttonStyle(.plain).help("Show only \(k.rawValue.lowercased())")
                }
                Spacer()
            }.padding(.horizontal, 22).padding(.top, 12)
            Divider().padding(.top, 14)
            VStack(alignment: .leading, spacing: 8) {
                Text("MOUSE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), alignment: .leading, spacing: 8) {
                    ForEach(Self.mouse, id: \.0) { m in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.0).font(.system(size: 11, weight: .semibold))
                            Text(m.1).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding(22)
        }
        .frame(width: 1010)
        .background(Color(white: 0.1))
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in
                let f = e.modifierFlags
                var m = ""
                if f.contains(.control) { m += "⌃" }; if f.contains(.option) { m += "⌥" }
                if f.contains(.shift) { m += "⇧" }; if f.contains(.command) { m += "⌘" }
                held = m
                return e
            }
        }
        .onDisappear { if let m = monitor { NSEvent.removeMonitor(m) } }
        .onExitCommand { close() }
    }

    /// what the key under the pointer does, every modifier
    var detail: some View {
        let list = hover.map { shortcuts($0) } ?? []
        return HStack(spacing: 14) {
            if let h = hover, !list.isEmpty {
                Text(Self.rows.joined().first { $0.id == h }?.cap ?? h.uppercased()).font(.system(size: 13, weight: .bold))
                    .frame(minWidth: 26, minHeight: 24).padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.1)))
                ForEach(list, id: \.mods) { s in
                    HStack(spacing: 5) {
                        Text(s.mods.isEmpty ? "—" : s.mods).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        RoundedRectangle(cornerRadius: 2).fill(s.kind.color).frame(width: 8, height: 8)
                        Text(s.label).font(.system(size: 12))
                    }
                }
            } else {
                Text("Point at a coloured key").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(height: 36).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
    }

    func keyCap(_ k: K) -> some View {
        let unit = 46.0
        let w = unit * k.w + 6 * (k.w - 1)
        let isMod = Self.modKeys[k.id] != nil
        let modOn = isMod && shown.contains(Self.modKeys[k.id]!)
        let s = current(k.id)
        let any = !shortcuts(k.id).isEmpty
        let col = s?.kind.color
        return VStack(alignment: .leading, spacing: 2) {
            Text(k.cap).font(.system(size: k.cap.count > 1 ? 11 : 13, weight: .semibold))
                .foregroundStyle(col != nil || modOn ? Color.white : Color.white.opacity(0.4))
            Spacer(minLength: 0)
            if let s { Text(s.label).font(.system(size: 8.5, weight: .medium)).foregroundStyle(.white.opacity(0.92)).lineLimit(2).minimumScaleFactor(0.8) }
        }
        .padding(5)
        .frame(width: w, height: unit, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(modOn ? Brand.chipOn : (col.map { $0.opacity(0.55) } ?? Color(white: 0.17)))
                .shadow(color: .black.opacity(0.5), radius: 0, x: 0, y: 2)
        )
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(hover == k.id ? Color.white.opacity(0.8) : Color.white.opacity(0.06), lineWidth: hover == k.id ? 1.5 : 1))
        .onHover { h in if h, any { hover = k.id } else if hover == k.id { hover = nil } }
        .onTapGesture {
            if let m = Self.modKeys[k.id] {
                if mods.contains(m) { mods.removeAll { String($0) == m } } else { mods = ["⌃", "⌥", "⇧", "⌘"].filter { mods.contains($0) || $0 == m }.joined() }
            }
        }
    }
}
