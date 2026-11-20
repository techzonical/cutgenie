import SwiftUI

// Viewer guides menu (Final Cut "Show title / action safe zones", centre and thirds lines)
struct GuidesMenu: View {
    @AppStorage("guides.centre") var gCentre = false
    @AppStorage("guides.thirds") var gThirds = false
    @AppStorage("guides.safe") var gSafe = false
    @AppStorage("viewer.surround") var surround = "grey"
    @AppStorage("viewer.outline") var outline = true
    var body: some View {
        Menu {
            Toggle("Centre lines", isOn: $gCentre)
            Toggle("Rule of thirds", isOn: $gThirds)
            Toggle("Title / action safe", isOn: $gSafe)
            Divider()
            Toggle("Frame edge line", isOn: $outline)
            Picker("Around the picture", selection: $surround) {
                Text("Black").tag("black"); Text("Dark grey").tag("grey"); Text("Light grey").tag("light"); Text("Checkerboard").tag("checker")
            }
        } label: { Image(systemName: "squareshape.split.2x2.dotted") }
        .menuStyle(.borderlessButton).fixedSize()
        .foregroundStyle(gCentre || gThirds || gSafe ? Brand.accent : Color.secondary)
        .help("Guides on the picture (the centre lines also show while you move something)")
    }
}

/// what the viewer shows around the picture, so the edge of the frame (and black bars) can be seen
struct ViewerSurround: View {
    @AppStorage("viewer.surround") var surround = "grey"
    var body: some View {
        switch surround {
        case "black": Color.black
        case "light": Color(white: 0.42)
        case "checker":
            Canvas { ctx, sz in
                let s: CGFloat = 12
                ctx.fill(Path(CGRect(origin: .zero, size: sz)), with: .color(Color(white: 0.22)))
                for y in stride(from: 0, to: sz.height, by: s) { for x in stride(from: 0, to: sz.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(Color(white: 0.3))) } }
            }
        default: Color(white: 0.2)
        }
    }
}
/// a thin line on the exact edge of the frame
struct FrameOutline: View {
    @AppStorage("viewer.outline") var outline = true
    var body: some View {
        if outline { Rectangle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1).allowsHitTesting(false) }
    }
}
