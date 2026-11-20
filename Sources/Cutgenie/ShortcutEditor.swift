import SwiftUI
import AppKit

// Your own keys: any action in the shortcut list can get another key. Pressing your key acts as if the original
// key had been pressed (the original keeps working too). Stored in UserDefaults "keys.remap" as "mods+key" -> "mods+key".
@MainActor enum CustomKeys {
    static let named: [UInt16: String] = [49: "space", 123: "left", 124: "right", 126: "up", 125: "down", 115: "home", 119: "end", 51: "delete", 117: "delete", 53: "esc", 36: "return", 48: "tab"]
    static let codes: [String: (UInt16, String)] = ["space": (49, " "), "left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "up": (126, "\u{F700}"),
        "down": (125, "\u{F701}"), "home": (115, "\u{F729}"), "end": (119, "\u{F72B}"), "delete": (51, "\u{7F}"), "esc": (53, "\u{1B}"), "return": (36, "\r"), "tab": (48, "\t")]
    static var remap: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "keys.remap") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "keys.remap") }
    }
    static func mods(_ f: NSEvent.ModifierFlags) -> String {
        (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "") + (f.contains(.shift) ? "⇧" : "") + (f.contains(.command) ? "⌘" : "")
    }
    static func combo(_ e: NSEvent) -> String {
        let k = named[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "").lowercased()
        return mods(e.modifierFlags) + "+" + k
    }
    static func combo(_ s: KeyboardMap.Shortcut) -> String { s.mods + "+" + s.key }
    static func pretty(_ c: String) -> String {
        let p = c.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard p.count == 2 else { return c }
        let k = String(p[1]); let caps: [String: String] = ["space": "Space", "left": "←", "right": "→", "up": "↑", "down": "↓", "delete": "⌫", "esc": "Esc", "return": "↩", "tab": "⇥", "home": "Home", "end": "End"]
        return String(p[0]) + (caps[k] ?? k.uppercased())
    }
    /// the event to act on: your key turned into the original one
    static func translate(_ e: NSEvent) -> NSEvent {
        guard let to = remap[combo(e)] else { return e }
        let p = to.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false); guard p.count == 2 else { return e }
        let m = String(p[0]), k = String(p[1])
        var f: NSEvent.ModifierFlags = []
        if m.contains("⌃") { f.insert(.control) }; if m.contains("⌥") { f.insert(.option) }; if m.contains("⇧") { f.insert(.shift) }; if m.contains("⌘") { f.insert(.command) }
        let (code, ch) = codes[k] ?? (keyCode(k), k)
        let chars = f.contains(.shift) && ch.count == 1 ? ch.uppercased() : ch
        return NSEvent.keyEvent(with: .keyDown, location: e.locationInWindow, modifierFlags: f, timestamp: e.timestamp, windowNumber: e.windowNumber,
                                context: nil, characters: chars, charactersIgnoringModifiers: ch, isARepeat: e.isARepeat, keyCode: code) ?? e
    }
    /// US-layout key codes for letters / digits / punctuation (used only for the translated event)
    static func keyCode(_ k: String) -> UInt16 {
        let t: [String: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
            "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47]
        return t[k] ?? 0
    }
}

/// list of actions with their keys; "Change" records the next key you press
struct ShortcutEditor: View {
    @State private var recording: String?            // combo of the action being changed
    @State private var monitor: Any?
    @State private var tick = 0
    @State private var query = ""
    @State private var clash: String?
    var body: some View {
        let _ = tick
        let byTarget = Dictionary(grouping: CustomKeys.remap, by: { $0.value }).mapValues { $0.map(\.key) }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Find an action", text: $query).textFieldStyle(.roundedBorder).frame(width: 220)
                Spacer()
                if !CustomKeys.remap.isEmpty { Button("Reset all my keys") { CustomKeys.remap = [:]; tick += 1 } }
            }
            if let clash { Text(clash).font(.system(size: 11)).foregroundStyle(.orange) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(KeyboardMap.all.enumerated()).filter { query.isEmpty || $0.1.label.localizedCaseInsensitiveContains(query) }, id: \.offset) { _, s in
                        let c = CustomKeys.combo(s), mine = byTarget[c] ?? []
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(s.kind.color).frame(width: 4, height: 16)
                            Text(s.label).font(.system(size: 12)).frame(width: 170, alignment: .leading)
                            keycap(CustomKeys.pretty(c), dim: false)
                            ForEach(mine, id: \.self) { m in
                                HStack(spacing: 2) {
                                    keycap(CustomKeys.pretty(m), dim: false).overlay(RoundedRectangle(cornerRadius: 4).stroke(Brand.accent))
                                    Button { var r = CustomKeys.remap; r[m] = nil; CustomKeys.remap = r; tick += 1 } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)) }
                                        .buttonStyle(.borderless).help("Remove your key")
                                }
                            }
                            Spacer()
                            Button(recording == c ? "Press a key…" : "Add key") { record(c) }
                                .controlSize(.small).tint(recording == c ? Brand.accent : nil).buttonStyle(.bordered)
                        }.padding(.vertical, 2)
                    }
                }
            }
            Text("Your key does the same as the original; the original keeps working. Esc cancels while recording.").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .onDisappear { stop() }
    }
    func keycap(_ s: String, dim: Bool) -> some View {
        Text(s).font(.system(size: 11, weight: .medium).monospaced()).padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(dim ? 0.04 : 0.1)))
    }
    func record(_ target: String) {
        stop(); recording = target; clash = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 && e.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty { stop(); return nil }
            let mine = CustomKeys.combo(e)
            if mine == target { stop(); return nil }
            if let used = KeyboardMap.all.first(where: { CustomKeys.combo($0) == mine }) {
                clash = "\(CustomKeys.pretty(mine)) already does “\(used.label)”. It now does “\(KeyboardMap.all.first { CustomKeys.combo($0) == target }?.label ?? "")” instead."
            }
            var r = CustomKeys.remap; r[mine] = target; CustomKeys.remap = r
            tick += 1; stop()
            return nil
        }
    }
    func stop() { if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil; recording = nil }
}
