import Foundation
import Network

// Minimal localhost-only HTTP server. POST /command with a JSON body, or GET /status.
public final class ControlServer {
    let listener: NWListener
    let handler: ([String: Any]) async -> [String: Any]
    let queue = DispatchQueue(label: "cutgenie.control")

    public init(port: UInt16, handler: @escaping ([String: Any]) async -> [String: Any]) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: params)
        self.handler = handler
    }

    public func start(onReady: @escaping (String) -> Void) {
        listener.stateUpdateHandler = { st in
            switch st {
            case .ready: onReady("listening on 127.0.0.1")
            case .failed(let e): onReady("server failed: \(e)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        listener.start(queue: queue)
    }

    func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        var buf = Data()
        func more() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
                guard let self else { return }
                if let data { buf.append(data) }
                if let req = Self.parse(buf) {
                    Task {
                        let reply = await self.respond(req)
                        let body = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{\"ok\":false}".utf8)
                        var head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                        head.append("")
                        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
                    }
                } else if done || err != nil {
                    conn.cancel()
                } else { more() }
            }
        }
        more()
    }

    struct Req { var method: String; var path: String; var body: Data }

    static func parse(_ d: Data) -> Req? {
        guard let r = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: d[d.startIndex..<r.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var len = 0
        for l in lines.dropFirst() where l.lowercased().hasPrefix("content-length:") {
            len = Int(l.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let body = d[r.upperBound...]
        guard body.count >= len else { return nil }
        return Req(method: String(first[0]), path: String(first[1]), body: Data(body.prefix(len)))
    }

    func respond(_ r: Req) async -> [String: Any] {
        if r.method == "GET" && r.path == "/status" { return await handler(["cmd": "status"]) }
        guard r.method == "POST", r.path == "/command",
              let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]
        else { return ["ok": false, "error": "use POST /command with a JSON object, or GET /status"] }
        return await handler(obj)
    }
}
