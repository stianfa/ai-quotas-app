import Foundation

/// Appends refresh results to a plain log file.
///
/// NSLog / os_log are the idiomatic choice, but a menu-bar app's output doesn't
/// reliably surface through `log show` — which makes "check the logs" useless as
/// troubleshooting advice. A file we own is greppable with no predicate guessing.
enum Diagnostics {
    static let logURL: URL = {
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("AIQuotas.log")
    }()

    private static let queue = DispatchQueue(label: "local.aiquotas.log")
    private static let maxBytes = 256 * 1024   // keep it small; it's a rolling tail

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
        return f
    }()

    static func log(_ message: String) {
        // Mirror to stderr so `open`-less foreground runs still show it.
        FileHandle.standardError.write(Data("AIQuotas: \(message)\n".utf8))

        let line = "\(stamp.string(from: Date()))  \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL)
            }
            // Trim from the front once it grows past the cap, keeping recent lines.
            if let size = try? fm.attributesOfItem(atPath: logURL.path)[.size] as? Int,
               size > maxBytes,
               let text = try? String(contentsOf: logURL, encoding: .utf8) {
                let kept = text.split(separator: "\n").suffix(500).joined(separator: "\n")
                try? (kept + "\n").write(to: logURL, atomically: true, encoding: .utf8)
            }
        }
    }
}
