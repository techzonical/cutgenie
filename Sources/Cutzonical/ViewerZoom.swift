import SwiftUI
import CutzonicalCore

// Viewer zoom (Final Cut's Fit / 25% / 50% / 100% / 200% menu above the viewer).
// Percent = of the project's real pixels (100% = one video pixel per screen point). Pinch or ⌘-scroll over the
// viewer zooms around the pointer; plain scroll pans while zoomed in. The graphic handles stay usable at any zoom.
@MainActor
final class ViewerZoom: ObservableObject {
    static let shared = ViewerZoom()
    @Published var zoom: Double? = nil            // nil = Fit
    @Published var pan: CGSize = .zero
    nonisolated(unsafe) static var frameInWindow = CGRect.zero   // viewer area, window coordinates (top-left origin)
    var fitScale = 1.0
    var scale: Double { zoom ?? fitScale }
    static let presets: [Double] = [0.1, 0.25, 0.5, 1, 2, 4]

    func set(_ z: Double?, around c: CGPoint? = nil) {
        guard let z else { zoom = nil; pan = .zero; return }
        let nz = min(8, max(0.05, z))
        if c != nil && nz <= fitScale * 1.001 { zoom = nil; pan = .zero; return }   // pinched back out past Fit
        let k = nz / scale
        if let c { pan = CGSize(width: (pan.width - c.x) * k + c.x, height: (pan.height - c.y) * k + c.y) }
        else { pan = CGSize(width: pan.width * k, height: pan.height * k) }
        zoom = nz
    }
    var label: String { zoom == nil ? "Fit" : "\(Int((scale * 100).rounded()))%" }
}

struct ZoomableViewer<Content: View>: View {
    let pixelSize: CGSize
    @ObservedObject var vz = ViewerZoom.shared
    @ViewBuilder let content: () -> Content
    var body: some View {
        GeometryReader { g in
            let fit = min(g.size.width / max(1, pixelSize.width), g.size.height / max(1, pixelSize.height))
            let s = vz.zoom ?? fit
            let w = pixelSize.width * s, h = pixelSize.height * s
            // keep the picture from sliding fully out of view
            let mx = max(0, (w - g.size.width) / 2 + g.size.width * 0.4), my = max(0, (h - g.size.height) / 2 + g.size.height * 0.4)
            let px = vz.zoom == nil ? 0 : min(mx, max(-mx, vz.pan.width)), py = vz.zoom == nil ? 0 : min(my, max(-my, vz.pan.height))
            content()
                .frame(width: w, height: h)
                .position(x: g.size.width / 2 + px, y: g.size.height / 2 + py)
                .onAppear { vz.fitScale = fit; ViewerZoom.frameInWindow = g.frame(in: .global) }
                .onChange(of: fit) { _, f in vz.fitScale = f }
                .onChange(of: g.frame(in: .global)) { _, f in ViewerZoom.frameInWindow = f }
        }
        .clipped()
    }
}
