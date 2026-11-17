import Foundation

/// Appends a timestamped line to the bounce-debug log in Caches.
/// Call at view lifecycle boundaries to trace the freeze.
enum DebugLog {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let queue = DispatchQueue(label: "bounce.debuglog", qos: .utility)

    static func log(_ message: String) {
        let ts = formatter.string(from: Date())
        let line = "\(ts) \(message)\n"
        queue.async {
            guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
            let url = dir.appendingPathComponent("bounce-debug.log")
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: url.path) {
                    if let fh = try? FileHandle(forWritingTo: url) {
                        _ = try? fh.seekToEnd()
                        try? fh.write(contentsOf: data)
                        try? fh.close()
                    }
                } else {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
    }
}
