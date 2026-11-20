import Foundation

// .cube 3D LUT loader (Adobe/Resolve format). R varies fastest, as Core Image expects.
public struct CubeLUT {
    public let size: Int
    public let data: Data            // size^3 RGBA premultiplied float32
    public let title: String
    public let domainMin: [Float], domainMax: [Float]
}

public enum LUTError: Error, CustomStringConvertible {
    case message(String)
    public var description: String { if case .message(let m) = self { return m }; return "LUT error" }
}

public enum LUTLoader {
    nonisolated(unsafe) static var cache: [String: CubeLUT] = [:]
    static let lock = NSLock()

    public static func load(_ url: URL) throws -> CubeLUT {
        lock.lock(); defer { lock.unlock() }
        let key = url.standardizedFileURL.path
        if let c = cache[key] { return c }
        let text = try String(contentsOf: url, encoding: .utf8)
        var size = 0, title = ""
        var dmin: [Float] = [0, 0, 0], dmax: [Float] = [1, 1, 1]
        var vals: [Float] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            switch parts[0] {
            case "TITLE": title = line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            case "LUT_3D_SIZE": size = Int(parts.count > 1 ? parts[1] : "") ?? 0
            case "LUT_1D_SIZE": throw LUTError.message("1D LUTs are not supported yet (\(url.lastPathComponent))")
            case "DOMAIN_MIN": dmin = parts.dropFirst().compactMap(Float.init)
            case "DOMAIN_MAX": dmax = parts.dropFirst().compactMap(Float.init)
            case "LUT_3D_INPUT_RANGE", "LUT_IN_VIDEO_RANGE", "LUT_OUT_VIDEO_RANGE": break
            default:
                if parts.count == 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) { vals += [r, g, b] }
            }
        }
        guard size >= 2, size <= 256 else { throw LUTError.message("missing or invalid LUT_3D_SIZE in \(url.lastPathComponent)") }
        guard dmin.count == 3, dmax.count == 3 else { throw LUTError.message("bad DOMAIN_MIN/MAX") }
        guard vals.count == size * size * size * 3 else {
            throw LUTError.message("expected \(size * size * size) entries, found \(vals.count / 3)")
        }
        var rgba = [Float](); rgba.reserveCapacity(size * size * size * 4)
        for i in stride(from: 0, to: vals.count, by: 3) { rgba += [vals[i], vals[i + 1], vals[i + 2], 1] }
        let lut = CubeLUT(size: size, data: rgba.withUnsafeBufferPointer { Data(buffer: $0) }, title: title, domainMin: dmin, domainMax: dmax)
        cache[key] = lut
        return lut
    }
}
