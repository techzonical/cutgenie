import Foundation

// cutzonicalctl <command> key=value ...   e.g.  cutzonicalctl render_frame time=2 out=/tmp/f.png
// Talks to the running Cutzonical app on 127.0.0.1 (port 7878, or CUTZONICAL_PORT).
var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    print("usage: cutzonicalctl <command> [key=value ...]\ncommands: status open save play pause seek add_lower_third set_audio set_color split undo redo render_frame export get_project")
    exit(2)
}
var cmd: [String: Any] = ["cmd": args.removeFirst().replacingOccurrences(of: "-", with: "_")]
for a in args {
    guard let eq = a.firstIndex(of: "=") else { fputs("bad argument '\(a)' (use key=value)\n", stderr); exit(2) }
    let k = String(a[..<eq]), v = String(a[a.index(after: eq)...])
    cmd[k] = Double(v) ?? v
}
let port = ProcessInfo.processInfo.environment["CUTZONICAL_PORT"] ?? "7878"
var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/command")!)
req.httpMethod = "POST"
req.httpBody = try JSONSerialization.data(withJSONObject: cmd)
req.timeoutInterval = 600
let sem = DispatchSemaphore(value: 0)
var code: Int32 = 0
URLSession.shared.dataTask(with: req) { data, _, err in
    if let err { fputs("cannot reach Cutzonical (is the app running?): \(err.localizedDescription)\n", stderr); code = 1 }
    else if let data, let s = String(data: data, encoding: .utf8) {
        print(s)
        if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], o["ok"] as? Bool != true { code = 1 }
    }
    sem.signal()
}.resume()
sem.wait()
exit(code)
