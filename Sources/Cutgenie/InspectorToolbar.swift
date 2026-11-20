import SwiftUI

// The bar on top of the Effects panel: find a section by name, show only what was changed,
// open or close every section at once. Sections (InspectorSection) read these through the environment.

struct SectionCommand: Equatable { var tick = 0; var open = true }
private struct FilterKey: EnvironmentKey { static let defaultValue = "" }
private struct ChangedOnlyKey: EnvironmentKey { static let defaultValue = false }
private struct CommandKey: EnvironmentKey { static let defaultValue = SectionCommand() }
extension EnvironmentValues {
    var sectionFilter: String { get { self[FilterKey.self] } set { self[FilterKey.self] = newValue } }
    var changedOnly: Bool { get { self[ChangedOnlyKey.self] } set { self[ChangedOnlyKey.self] = newValue } }
    var sectionCommand: SectionCommand { get { self[CommandKey.self] } set { self[CommandKey.self] = newValue } }
}

/// an icon for each section, and extra words the search box also finds it by
enum SectionIcon {
    static let map: [String: String] = [
        "Transform": "arrow.up.and.down.and.arrow.left.and.right", "Zoom": "plus.magnifyingglass", "Keyframes": "diamond", "Slide aside": "arrow.left.and.right.square", "Crop": "crop",
        "Drop shadow": "shadow", "Shape": "square.on.circle", "Text": "textformat", "Mask": "theatermasks",
        "Behaviours": "wind", "Build In / Out": "sparkles", "Fade & blend": "circle.lefthalf.filled", "Fades": "circle.lefthalf.filled",
        "Effects": "wand.and.stars", "Volume": "speaker.wave.2", "EQ": "slider.vertical.3", "Compressor": "rectangle.compress.vertical",
        "Gate": "door.left.hand.closed", "Loudness": "waveform", "Speed": "gauge.with.dots.needle.67percent", "Clip": "film",
        "Basic": "sun.max", "Color wheels": "circle.circle", "Look LUTs": "camera.filters", "Project colour": "paintpalette",
        "Input": "arrow.down.circle", "Output": "arrow.up.circle", "Viewer": "eye",
    ]
    static let words: [String: String] = [
        "Transform": "position move x y scale size rotate rotation opacity keyframe anchor",
        "Zoom": "ken burns punch in keyframe", "Keyframes": "ease easing ease in out bounce overshoot linear smooth keyframe delete", "Slide aside": "position move x side panel dock motion keyframe", "Crop": "trim edge left right top bottom",
        "Drop shadow": "shadow distance softness", "Shape": "width height size rectangle circle line fill outline border colour color blur pixelate lock",
        "Text": "font size bold colour color words", "Mask": "cut circle rectangle feather invert",
        "Behaviours": "wiggle drift pulse spin", "Build In / Out": "animation intro outro appear disappear",
        "Fade & blend": "fade opacity blend mode screen multiply", "Effects": "glow stroke outline blur corners shadow",
        "Volume": "gain level loud", "Fades": "fade in out",
    ]
    static func symbol(_ t: String) -> String { map[t] ?? "slider.horizontal.3" }
}

/// wraps a panel: the bar stays on top, the content scrolls under it
struct SectionsPanel<Content: View>: View {
    @AppStorage("inspector.changedOnly") private var changedOnly = false
    @State private var filter = ""
    @State private var command = SectionCommand()
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                    TextField("Find a setting (e.g. width, shadow)", text: $filter).textFieldStyle(.plain).font(.caption)
                    if !filter.isEmpty { Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)) }.buttonStyle(.borderless) }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                Toggle(isOn: $changedOnly) { Image(systemName: "circle.fill").font(.system(size: 7)) }
                    .toggleStyle(.button).controlSize(.small).tint(Brand.accent)
                    .help(changedOnly ? "Showing only changed sections. Click to show all." : "Show only sections you have changed")
                Button { command = SectionCommand(tick: command.tick + 1, open: true) } label: { Image(systemName: "rectangle.expand.vertical") }
                    .buttonStyle(.borderless).help("Open every section")
                Button { command = SectionCommand(tick: command.tick + 1, open: false) } label: { Image(systemName: "rectangle.compress.vertical") }
                    .buttonStyle(.borderless).help("Close every section")
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            Divider()
            content()
                .environment(\.sectionFilter, filter)
                .environment(\.changedOnly, changedOnly)
                .environment(\.sectionCommand, command)
        }
    }
}
