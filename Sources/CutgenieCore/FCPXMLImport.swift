import Foundation
import AppKit

// Read-only import of a Final Cut FCPXML project into a Cutgenie project.
// Maps the main storyline (sync clips, asset clips, plain clips) with exact cut points and linked/separate audio.
// Everything else (titles, graphics layers, music, colour filters, transitions...) is counted and listed in the
// report, never silently dropped.
public enum FCPXMLImport {
    struct Res { var name: String; var start: Double; var path: String?; var hasAudio: Bool }

    static func t(_ s: String?) -> Double? {
        guard var s, s.hasSuffix("s") else { return nil }
        s.removeLast()
        if let i = s.firstIndex(of: "/") {
            guard let n = Double(s[..<i]), let d = Double(s[s.index(after: i)...]), d != 0 else { return nil }
            return n / d
        }
        return Double(s)
    }
    static func db(_ s: String?) -> Double? {
        guard var s, s.hasSuffix("dB") else { return nil }
        s.removeLast(2); return Double(s.trimmingCharacters(in: .whitespaces))
    }
    // "3 (Rec. 2020 HLG)" / "0 (Rec. 709)" ... -> Cutgenie colour space id
    static func spaceID(_ s: String) -> String? {
        let l = s.lowercased()
        if l.contains("2020") && l.contains("hlg") { return "rec2020hlg" }
        if l.contains("2020") && l.contains("pq") { return "rec2020pq" }
        if l.contains("p3") { return "displayp3" }
        if l.contains("srgb") { return "srgb" }
        if l.contains("709") { return "rec709" }
        if l.contains("s-log3") || l.contains("slog3") { return "slog3" }
        return nil
    }
    static func attr(_ e: XMLElement, _ k: String) -> String? { e.attribute(forName: k)?.stringValue }
    static func kids(_ e: XMLElement, _ n: String) -> [XMLElement] { e.elements(forName: n) }

    public static func run(path: String, lutPath: String? = nil) throws -> (project: Project, report: [String]) {
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            url.appendPathComponent("Info.fcpxml")     // .fcpxmld package
        }
        let doc = try XMLDocument(contentsOf: url, options: [])
        guard let root = doc.rootElement(), root.name == "fcpxml" else { throw RenderError.message("not an FCPXML file") }
        guard let resources = kids(root, "resources").first else { throw RenderError.message("no <resources>") }

        var res: [String: Res] = [:]
        var formats: [String: XMLElement] = [:]
        for e in resources.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            if e.name == "format", let id = attr(e, "id") { formats[id] = e }
            if e.name == "asset", let id = attr(e, "id") {
                let rep = kids(e, "media-rep").first
                let p = attr(rep ?? e, "src").flatMap { URL(string: $0)?.path }
                res[id] = Res(name: attr(e, "name") ?? id, start: t(attr(e, "start")) ?? 0, path: p, hasAudio: attr(e, "hasAudio") == "1")
            }
        }
        guard let projEl = try root.nodes(forXPath: "//project").first as? XMLElement,
              let seq = kids(projEl, "sequence").first, let spine = kids(seq, "spine").first
        else { throw RenderError.message("no project/sequence/spine found") }

        var project = Project()
        project.name = attr(projEl, "name") ?? "Imported"
        if let f = attr(seq, "format").flatMap({ formats[$0] }) {
            if let fd = t(attr(f, "frameDuration")), fd > 0 { project.settings.fps = 1 / fd }
            project.settings.width = Int(attr(f, "width") ?? "") ?? 1920
            project.settings.height = Int(attr(f, "height") ?? "") ?? 1080
        }
        let fcpDuration = t(attr(seq, "duration")) ?? 0

        var idForRef: [String: String] = [:]
        func assetID(_ ref: String) -> String? {
            if let id = idForRef[ref] { return id }
            guard let r = res[ref], let p = r.path else { return nil }
            let id = "a\(project.assets.count + 1)"
            project.assets.append(Asset(id: id, path: p)); idForRef[ref] = id
            return id
        }
        var unmapped: [String: Int] = [:]
        var notes: [String] = []
        func tally(_ k: String) { unmapped[k, default: 0] += 1 }
        func groupName(_ s: String) -> String {
            let head = s.split(separator: ":").first.map(String.init) ?? s
            return String(head.prefix { !$0.isNumber }).trimmingCharacters(in: .whitespaces)
        }
        // everything attached to (not part of) the main storyline item
        func tallyAttached(_ item: XMLElement) {
            for c in item.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                switch c.name ?? "" {
                case "title": if attr(c, "lane") == nil { tally("title without lane: \(groupName(attr(c, "name") ?? ""))") }
                case "video": if attr(c, "lane") == nil { tally("graphic layer without lane: \(groupName(attr(c, "name") ?? ""))") }
                case "asset-clip", "clip", "audio":
                    let role = attr(c, "audioRole") ?? "attached"
                    tally("attached \(role) clip: \(groupName(attr(c, "name") ?? ""))")
                case "filter-video", "filter-audio":
                    let n = attr(c, "name") ?? "?"
                    if !(lutPath != nil && n == "Custom LUT") { tally("effect: \(n)") }
                case "adjust-volume": break   // handled as gain
                case "spine", "marker", "chapter-marker", "keyword", "metadata": break
                default: if (c.name ?? "").hasPrefix("adjust-") { tally("adjustment: \(c.name!)") } else { tally("other: \(c.name ?? "?")") }
                }
            }
        }
        func gain(_ item: XMLElement) -> Double {
            for c in kids(item, "adjust-volume") { if let g = db(attr(c, "amount")) { return g } }
            return 0
        }

        var counts = [String: Int]()
        var overlays: [Overlay] = []
        func nums(_ str: String?) -> [Double] { (str ?? "").split(separator: " ").compactMap { Double($0) } }
        func keys(_ adj: XMLElement?, _ name: String, childStart: Double) -> [Keyframe] {
            guard let adj else { return [] }
            if let a = attr(adj, name) { return [Keyframe(t: 0, v: nums(a))] }
            guard let prm = kids(adj, "param").first(where: { attr($0, "name") == name }) else { return [] }
            if let kfa = kids(prm, "keyframeAnimation").first {
                return kids(kfa, "keyframe").compactMap { k in
                    let v = nums(attr(k, "value")); guard !v.isEmpty else { return nil }
                    return Keyframe(t: (t(attr(k, "time")) ?? 0) - childStart, v: v) }
            }
            let v = nums(attr(prm, "value")); return v.isEmpty ? [] : [Keyframe(t: 0, v: v)]
        }
        // connected graphic layers (stills / video) attached to a main-storyline item
        // Final Cut text styles (<text-style-def>), by id - a title may use a style defined in another title
        var styleDefs: [String: XMLElement] = [:]
        if let root = spine.rootDocument?.rootElement(), let defs = try? root.nodes(forXPath: "//text-style-def") {
            for case let d as XMLElement in defs { if let id = attr(d, "id"), let ts = kids(d, "text-style").first { styleDefs[id] = ts } }
        }
        func col(_ s: String?) -> [Double]? { let v = nums(s); return v.count >= 3 ? (v.count == 3 ? v + [1] : Array(v.prefix(4))) : nil }
        /// a Final Cut title (Basic Title / Text) -> an editable text layer
        func textSpec(_ ti: XMLElement) -> TextSpec? {
            guard let tx = kids(ti, "text").first else { return nil }
            var runs: [TextRun] = []
            var align = "center", lineSp: Double?
            for ts in kids(tx, "text-style") {
                var str = ts.stringValue ?? ""
                if str.isEmpty { str = "\n" }      // a run holding only a line break (the XML reader drops whitespace-only text)
                var r = TextRun(text: str)
                if let ref = attr(ts, "ref"), let d = styleDefs[ref] {
                    r.font = attr(d, "font") ?? r.font
                    // a weight such as "SemiBold": use that exact font when it is installed (Chakra Petch SemiBold = ChakraPetch-SemiBold)
                    if let face = attr(d, "fontFace"), face != "Regular" {
                        let ps = r.font.replacingOccurrences(of: " ", with: "") + "-" + face.replacingOccurrences(of: " ", with: "")
                        if NSFont(name: ps, size: 12) != nil { r.font = ps } else if face.contains("Bold") || face == "Black" { r.bold = true }
                        if face.contains("Italic") { r.italic = true }
                    }
                    if let z = Double(attr(d, "fontSize") ?? "") { r.size = z }
                    if attr(d, "bold") == "1" { r.bold = true }
                    if attr(d, "italic") == "1" { r.italic = true }
                    if let c = col(attr(d, "fontColor")) { r.color = c }
                    if let k = Double(attr(d, "kerning") ?? "") { r.tracking = k }
                    if let c = col(attr(d, "strokeColor")), let w = Double(attr(d, "strokeWidth") ?? ""), w != 0 { r.strokeColor = c; r.strokeWidth = abs(w) }
                    if let c = col(attr(d, "shadowColor")) {
                        r.shadowColor = c
                        let o = nums(attr(d, "shadowOffset")); if o.count >= 2 { r.shadowDistance = o[0]; r.shadowAngle = o[1] }
                        r.shadowBlur = Double(attr(d, "shadowBlurRadius") ?? "")
                    }
                    if let a = attr(d, "alignment") { align = a == "left" ? "left" : a == "right" ? "right" : "center" }
                    if let l = Double(attr(d, "lineSpacing") ?? "") { lineSp = l }
                }
                if let last = runs.last, last.text.allSatisfy({ $0.isNewline }) || str.allSatisfy({ $0.isNewline }) {
                    // a run that is only a line break: keep it as text of the run before (Final Cut stores it on its own)
                    if str.allSatisfy({ $0.isNewline }) { runs[runs.count - 1].text += str; continue }
                }
                runs.append(r)
            }
            guard !runs.isEmpty else { return nil }
            var spec = TextSpec(runs: runs); spec.align = align; spec.lineSpacing = lineSp
            return spec
        }
        func takeLayers(_ item: XMLElement, timelineOffset off: Double, parentStart: Double, parent: String?) {
            for ti in kids(item, "title") where attr(ti, "lane") != nil {
                guard let lane = Int(attr(ti, "lane") ?? ""), let vo = t(attr(ti, "offset")), let vd = t(attr(ti, "duration")), let spec = textSpec(ti) else { continue }
                let cs = t(attr(ti, "start")) ?? 0
                var o = Overlay(id: "g\(overlays.count + 1)", name: attr(ti, "name") ?? "Text", asset: "", lane: lane, offset: off + (vo - parentStart), duration: vd)
                o.connectedTo = parent; o.conform = "none"; o.text = spec
                let tr = kids(ti, "adjust-transform").first
                o.position = keys(tr, "position", childStart: cs)
                o.scale = keys(tr, "scale", childStart: cs)
                o.opacity = keys(kids(ti, "adjust-blend").first, "amount", childStart: cs)
                // Basic Title's own Position parameter (pixels) adds to the transform (Final Cut units = 1% of the frame height)
                if let p = kids(ti, "param").first(where: { attr($0, "name") == "Position" }) {
                    let v = nums(attr(p, "value"))
                    if v.count >= 2 {
                        let u = Double(project.settings.height) / 100
                        if o.position.isEmpty { o.position = [Keyframe(t: 0, v: [0, 0])] }
                        o.position = o.position.map { Keyframe(t: $0.t, v: [$0.v[0] + v[0] / u, $0.v[1] + v[1] / u]) }
                    }
                }
                overlays.append(o)
                counts["text (Final Cut title)", default: 0] += 1
            }
            for v in kids(item, "video") where attr(v, "lane") != nil {
                guard let ref = attr(v, "ref"), let aid = assetID(ref), let lane = Int(attr(v, "lane") ?? ""),
                      let vo = t(attr(v, "offset")), let vd = t(attr(v, "duration")) else { continue }
                let cs = t(attr(v, "start")) ?? 0
                var o = Overlay(id: "g\(overlays.count + 1)", name: attr(v, "name") ?? "", asset: aid, lane: lane, offset: off + (vo - parentStart), duration: vd)
                o.connectedTo = parent
                o.conform = kids(v, "adjust-conform").first.flatMap { attr($0, "type") } ?? "fit"
                let tr = kids(v, "adjust-transform").first
                o.position = keys(tr, "position", childStart: cs)
                o.scale = keys(tr, "scale", childStart: cs)
                o.opacity = keys(kids(v, "adjust-blend").first, "amount", childStart: cs)
                overlays.append(o)
            }
        }
        var lutIn: String?, lutOut: String?
        var sawCustomLUT = false, sawWheels = false, lutAssetID: String?, lutSpaces = ""
        var skipped: [String] = []
        for item in spine.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            let name = item.name ?? ""
            guard let off = t(attr(item, "offset")), let dur = t(attr(item, "duration")) else { continue }
            var clip: Clip?
            func newID() -> String { "c\(project.clips.count + 1)" }

            switch name {
            case "sync-clip":
                let S = t(attr(item, "start")) ?? 0
                guard let inner = kids(item, "spine").first,
                      let prim = kids(inner, "asset-clip").first(where: { attr($0, "lane") == nil }),
                      let ref = attr(prim, "ref"), let aid = assetID(ref), let r = res[ref]
                else { skipped.append("sync-clip at \(off)s: no usable main video"); continue }
                let primOff = t(attr(prim, "offset")) ?? 0
                let srcIn = ((t(attr(prim, "start")) ?? r.start) - r.start) + (S - primOff)
                var c = Clip(id: newID(), asset: aid, sourceIn: srcIn, duration: dur, offset: off)
                // separate audio recording connected inside the sync clip
                outer: for g in kids(inner, "gap") {
                    for a in kids(g, "asset-clip") where attr(a, "lane") != nil {
                        guard let aref = attr(a, "ref"), let aaid = assetID(aref), let ar = res[aref] else { continue }
                        let localOff = (t(attr(g, "offset")) ?? 0) + ((t(attr(a, "offset")) ?? 0) - (t(attr(g, "start")) ?? 0))
                        let aIn = ((t(attr(a, "start")) ?? ar.start) - ar.start) + (S - localOff)
                        c.audioSource = AudioSource(asset: aaid, sourceIn: aIn)
                        break outer
                    }
                }
                c.audio.gainDb = gain(item)
                // Final Cut's "Custom LUT" filter (its file is stored in a packed form we cannot read): use the LUT the caller supplied
                let fcpFilters = kids(item, "filter-video") + kids(inner, "asset-clip").flatMap { kids($0, "filter-video") }
                if let cl = fcpFilters.first(where: { attr($0, "name") == "Custom LUT" }) {
                    sawCustomLUT = true
                    let inCS = kids(cl, "param").first { attr($0, "name") == "Input" }.flatMap { attr($0, "value") } ?? "?"
                    let outCS = kids(cl, "param").first { attr($0, "name") == "Output" }.flatMap { attr($0, "value") } ?? "?"
                    lutSpaces = "input \(inCS), output \(outCS)"
                    lutIn = spaceID(inCS); lutOut = spaceID(outCS)
                    if let lp = lutPath {
                        if lutAssetID == nil { lutAssetID = "a\(project.assets.count + 1)"; project.assets.append(Asset(id: lutAssetID!, path: lp)) }
                        c.color.luts = [LUTSlot(slot: "input", asset: lutAssetID!, inputSpace: lutIn, outputSpace: lutOut)]
                    }
                }
                if fcpFilters.contains(where: { attr($0, "name") == "Color Wheels" }) { sawWheels = true }
                // the camera clip's own volume is replaced by the separate audio; anything else on it is reported
                tallyAttached(item)
                for f in kids(inner, "asset-clip") + [] where attr(f, "lane") == nil { for fc in f.children?.compactMap({ $0 as? XMLElement }) ?? [] where (fc.name ?? "").hasPrefix("filter") { tally("effect: \(attr(fc, "name") ?? "?")") } }
                clip = c
                counts["Main (camera + separate audio)", default: 0] += 1
            case "asset-clip":
                guard let ref = attr(item, "ref"), let aid = assetID(ref), let r = res[ref]
                else { skipped.append("asset-clip \(attr(item, "name") ?? "?") at \(off)s: media missing"); continue }
                var c = Clip(id: newID(), asset: aid, sourceIn: (t(attr(item, "start")) ?? r.start) - r.start, duration: dur, offset: off)
                c.audio.gainDb = gain(item)
                tallyAttached(item)
                clip = c
                counts["asset clip (\(r.name))", default: 0] += 1
            case "clip":
                guard let v = (kids(item, "video") + kids(item, "audio")).first, let ref = attr(v, "ref"),
                      let aid = assetID(ref), let r = res[ref]
                else { skipped.append("clip \(attr(item, "name") ?? "?") at \(off)s: no media"); continue }
                let srcIn = ((t(attr(item, "start")) ?? 0) - (t(attr(v, "offset")) ?? 0)) + ((t(attr(v, "start")) ?? r.start) - r.start)
                var c = Clip(id: newID(), asset: aid, sourceIn: srcIn, duration: dur, offset: off)
                c.audio.gainDb = gain(item)
                tallyAttached(item)
                clip = c
                counts["clip (\(r.name))", default: 0] += 1
            case "gap":
                counts["gap", default: 0] += 1
                continue
            default:
                skipped.append("\(name) at \(off)s: not supported"); continue
            }
            if var c = clip {
                // the camera sliding aside for a side panel (position keyframes on the clip itself)
                let mv = keys(kids(item, "adjust-transform").first, "position", childStart: t(attr(item, "start")) ?? 0)
                if mv.contains(where: { $0.v.contains { abs($0) > 0.0001 } }) { c.motion = mv; counts["camera slide (docked panel)", default: 0] += 1 }
                project.clips.append(c)
            }
            takeLayers(item, timelineOffset: off, parentStart: t(attr(item, "start")) ?? 0, parent: clip?.id)
        }

        project.overlays = overlays
        // report
        var rep: [String] = []
        let end = project.totalDuration
        rep.append("Imported \"\(project.name)\" from \(url.lastPathComponent)  (FCPXML read only, nothing was changed)")
        rep.append(String(format: "Length: Final Cut %.3f s, Cutgenie %.3f s, difference %.4f s", fcpDuration, end, end - fcpDuration))
        rep.append("Clips imported: \(project.clips.count), graphic layers imported: \(overlays.count), media files used: \(project.assets.count)")
        for (k, v) in counts.sorted(by: { $0.key < $1.key }) { rep.append("  \(v) × \(k)") }
        let missing = project.assets.filter { !FileManager.default.fileExists(atPath: $0.path) }
        rep.append(missing.isEmpty ? "All media files found." : "MISSING media: " + missing.map { $0.path }.joined(separator: ", "))
        if sawCustomLUT {
            rep.append(lutPath != nil ? "Colour: Custom LUT (\(lutSpaces)) imported as the INPUT LUT slot (applied first, before the wheels) using your file \((lutPath! as NSString).lastPathComponent) on every clip that had it."
                                      : "Colour: Custom LUT found (\(lutSpaces)) but not imported: pass lut=<file.cube> to attach your LUT.")
        }
        if sawWheels { rep.append("Colour: Color Wheels found. Temperature 5000 / Tint 0 / Hue 0 / Preserve Luma on are readable; the wheel positions are stored in Apple's packed format and could NOT be read, so wheels are left neutral. Give me the values from Final Cut's inspector to set them.") }
        rep.append("NOT imported yet (counted, not lost from your Final Cut project):")
        for (k, v) in unmapped.sorted(by: { $0.key < $1.key }) { rep.append("  \(v) × \(k)") }
        if !skipped.isEmpty { rep.append("SKIPPED items:"); rep += skipped.prefix(20).map { "  " + $0 } }
        rep += notes
        return (project, rep)
    }
}
