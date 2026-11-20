import SwiftUI

/// Cutzonical's design kit: one place for colours, type sizes, shapes. Every panel uses these, so the app stays consistent.
enum Brand {
    // amber: the one accent colour (selected things, switches, sliders, the playhead highlight, the logo)
    static let accent = Color(red: 0.949, green: 0.639, blue: 0.227)          // #F2A33A
    static let accentDeep = Color(red: 0.85, green: 0.50, blue: 0.13)
    static let onAccent = Color(red: 0.12, green: 0.08, blue: 0.03)           // text on amber (dark reads better than white)
    static let chipOn = Color(white: 0.36)                                     // selected chip / toggle: neutral, not amber
    static let accentSoft = accent.opacity(0.16)

    // surfaces, darkest to lightest
    static let window = Color(white: 0.085)
    static let panel = Color(white: 0.115)
    static let card = Color.white.opacity(0.045)
    static let raised = Color(white: 0.17)
    static let stroke = Color.white.opacity(0.07)

    // type
    static let title = Font.system(size: 17, weight: .semibold)
    static let heading = Font.system(size: 12, weight: .semibold)
    static let body = Font.system(size: 12)
    static let label = Font.system(size: 11)
    static let caption = Font.system(size: 10)

    // shapes
    static let rSmall = 5.0, rCard = 8.0, rWindow = 12.0
}

/// the Cutzonical mark (same drawing as the app icon, amber version): three timeline clips, a cut, two sparks (AI)
struct LogoMark: View {
    var size: Double = 18
    var body: some View {
        Canvas { ctx, sz in
            let s = sz.width
            func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x / 110 * s, y: y / 110 * s) }
            func U(_ v: Double) -> Double { v / 110 * s }
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: s, height: s), cornerRadius: s * 0.225),
                     with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.76, blue: 0.38), Color(red: 0.91, green: 0.56, blue: 0.16)]),
                                           startPoint: .zero, endPoint: CGPoint(x: s, y: s)))
            for (x, y, w) in [(14.0, 27.0, 48.0), (30, 47, 64), (14, 67, 60)] {
                ctx.fill(Path(roundedRect: CGRect(origin: P(x, y), size: CGSize(width: U(w), height: U(15))), cornerRadius: U(7.5)), with: .color(Brand.onAccent))
            }
            var cut = Path(); cut.move(to: P(64, 12)); cut.addLine(to: P(48, 96))
            ctx.stroke(cut, with: .color(Color(red: 1, green: 0.89, blue: 0.71)), style: StrokeStyle(lineWidth: U(8), lineCap: .round))
            func spark(_ cx: Double, _ cy: Double, _ r: Double, _ w: Double) {
                let c = P(cx, cy), rv = U(r), rh = U(r * 0.78), w = U(w)
                var p = Path(); p.move(to: CGPoint(x: c.x, y: c.y - rv))
                p.addQuadCurve(to: CGPoint(x: c.x + rh, y: c.y), control: CGPoint(x: c.x + w, y: c.y - w))
                p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + rv), control: CGPoint(x: c.x + w, y: c.y + w))
                p.addQuadCurve(to: CGPoint(x: c.x - rh, y: c.y), control: CGPoint(x: c.x - w, y: c.y + w))
                p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - rv), control: CGPoint(x: c.x - w, y: c.y - w))
                ctx.fill(p, with: .color(.white))
            }
            spark(80, 30, 12, 0.8)
            if s >= 16 { spark(93, 13, 5, 0.3) }
        }
        .frame(width: size, height: size)
    }
}

/// short note that slides up over the viewer ("Saved", problems...) and fades away on its own
struct Toast: View {
    let text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: ["Saved", "Exported", "Done"].contains(where: { text.hasPrefix($0) }) ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(Brand.accent)
            Text(text).font(Brand.label).lineLimit(2)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(Brand.stroke))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .frame(maxWidth: 460)
    }
}

/// the top of every popup window: close button, title, subtitle (Export, Settings, New project, Shortcuts)
struct SheetHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let close: () -> Void
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 22).background(Circle().fill(Color.white.opacity(0.1)))
            }.buttonStyle(.plain).help("Close (Esc)").padding(.trailing, 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Brand.title)
                Text(subtitle).font(Brand.label).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }.padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14)
    }
}
extension SheetHeader where Trailing == EmptyView {
    init(title: String, subtitle: String, close: @escaping () -> Void) { self.init(title: title, subtitle: subtitle, close: close) { EmptyView() } }
}

extension Notification.Name {
    /// object "timeline" / "viewer": that area fills the window; again = back to normal
    static let focusArea = Notification.Name("cutzonical.focusArea")
    static let fullscreenPlay = Notification.Name("cutzonical.fullscreenPlay")
}

/// timeline draw time (CUTZONICAL_TIMING=file): average and worst of every 60 draws
enum DrawTiming {
    nonisolated(unsafe) static var sum = 0.0, worst = 0.0, n = 0
    static func add(_ t: Double) {
        guard let log = ProcessInfo.processInfo.environment["CUTZONICAL_TIMING"] else { return }
        sum += t; worst = max(worst, t); n += 1
        guard n >= 60 else { return }
        if let h = FileHandle(forWritingAtPath: log) { h.seekToEndOfFile(); h.write(String(format: "timeline draw avg %.1f ms, worst %.1f ms\n", sum / Double(n) * 1000, worst * 1000).data(using: .utf8)!); h.closeFile() }
        sum = 0; worst = 0; n = 0
    }
}

/// a pop-up window as tall as its content wants, but never taller than the Cutzonical window it opens over (the rest scrolls)
@MainActor func fitScreen(_ want: CGFloat) -> CGFloat {
    let win = NSApp.windows.first { $0.isVisible && $0.sheetParent == nil && $0.contentView != nil }?.frame.height
    let avail = win ?? (NSScreen.main?.visibleFrame.height ?? 900)
    return max(420, min(want, avail - 40))
}
/// scrolling content with a scroll bar (plain scrolling, nothing else)
struct FittedScroll<C: View>: View {
    @ViewBuilder var content: () -> C
    var body: some View {
        ScrollView(.vertical) { content() }.scrollIndicators(.visible)
    }
}
