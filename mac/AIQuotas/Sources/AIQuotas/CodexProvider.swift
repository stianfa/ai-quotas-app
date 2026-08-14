import Foundation

/// Reads ChatGPT quota through Codex's documented app-server account API.
/// Codex owns authentication and token refresh; this app never reads or writes
/// `auth.json` directly.
enum CodexProvider {
    private static var codexHome: URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return Credentials.home.appendingPathComponent(".codex")
    }

    private static func codexExecutable() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let explicit = ProcessInfo.processInfo.environment["CODEX_PATH"], !explicit.isEmpty {
            candidates.append(URL(fileURLWithPath: explicit))
        }
        candidates += [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            Credentials.home.appendingPathComponent(".local/bin/codex"),
            Credentials.home.appendingPathComponent(".volta/bin/codex"),
            Credentials.home.appendingPathComponent(".asdf/shims/codex"),
            Credentials.home.appendingPathComponent(".fnm/aliases/default/bin/codex"),
        ]

        // GUI apps do not inherit an interactive shell's PATH. Include NVM's
        // versioned installs explicitly so a menu-bar launch finds the same CLI.
        let nvm = Credentials.home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? fm.contentsOfDirectory(
            at: nvm, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) {
            candidates += versions.sorted { $0.lastPathComponent > $1.lastPathComponent }
                .map { $0.appendingPathComponent("bin/codex") }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }

    /// Blocking stdio exchange, always run from a detached utility task.
    private static func appServerResponse() throws -> Data {
        guard let executable = codexExecutable() else {
            throw QuotaError.message("Codex CLI not found")
        }

        let proc = Process()
        proc.executableURL = executable
        proc.arguments = ["app-server"]
        // NVM installs `codex` beside its matching `node` binary and uses an
        // `/usr/bin/env node` shebang. GUI apps have a minimal PATH, so prepend
        // the located CLI directory for the child without changing global state.
        var environment = ProcessInfo.processInfo.environment
        let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "\(executable.deletingLastPathComponent().path):\(inheritedPath)"
        proc.environment = environment
        let input = Pipe(), output = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = FileHandle.nullDevice
        try proc.run()

        let box = ProcessBox(proc)
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            if box.process.isRunning { box.process.terminate() }
        }
        defer {
            try? input.fileHandleForWriting.close()
            if proc.isRunning { proc.terminate() }
            proc.waitUntilExit()
        }

        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }

        var buffer = Data()
        func readMessage(id: Int) throws -> [String: Any] {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    guard !line.isEmpty,
                          let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                    else { continue }
                    if (object["id"] as? Int) == id { return object }
                    continue
                }
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty {
                    throw QuotaError.message("Codex app-server closed before replying")
                }
                buffer.append(chunk)
            }
        }

        try send([
            "method": "initialize", "id": 0,
            "params": ["clientInfo": [
                "name": "ai_quotas", "title": "AI Quotas", "version": "1.0.0",
            ]],
        ])
        let initialized = try readMessage(id: 0)
        if let error = initialized["error"] as? [String: Any] {
            throw QuotaError.message(error["message"] as? String ?? "Codex app-server initialization failed")
        }

        try send(["method": "initialized", "params": [:]])
        try send(["method": "account/rateLimits/read", "id": 1])
        let response = try readMessage(id: 1)
        if let error = response["error"] as? [String: Any] {
            throw QuotaError.message(error["message"] as? String ?? "Codex rate-limit request failed")
        }
        return try JSONSerialization.data(withJSONObject: response)
    }

    private static func windowLabel(minutes: Double?, fallback: String) -> String {
        guard let m = minutes, m > 0 else { return fallback }
        if m.truncatingRemainder(dividingBy: 10080) == 0 {
            let w = Int(m / 10080)
            return w == 1 ? "Weekly" : "\(w)-week"
        }
        if m.truncatingRemainder(dividingBy: 1440) == 0 {
            let d = Int(m / 1440)
            return d == 1 ? "Daily" : "\(d)-day"
        }
        if m.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(m / 60))-hour" }
        return "\(Int(m))-minute"
    }

    private static func liveResult(from data: Data) throws -> ProviderResult {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = response["result"] as? [String: Any]
        else { throw QuotaError.message("malformed Codex app-server response") }

        let byID = result["rateLimitsByLimitId"] as? [String: Any]
        let first = byID?.values.compactMap { $0 as? [String: Any] }.first
        guard let limits = (byID?["codex"] as? [String: Any])
                ?? (result["rateLimits"] as? [String: Any]) ?? first,
              let primary = limits["primary"] as? [String: Any]
        else { throw QuotaError.message("Codex returned no ChatGPT rate limits") }

        func number(_ dict: [String: Any], _ key: String) -> Double? {
            (dict[key] as? NSNumber)?.doubleValue
        }
        func window(_ dict: [String: Any], id: String, fallback: String) -> QuotaWindow {
            QuotaWindow(
                id: id,
                label: windowLabel(minutes: number(dict, "windowDurationMins"), fallback: fallback),
                usedPercent: number(dict, "usedPercent"),
                resetsAt: number(dict, "resetsAt").map { Date(timeIntervalSince1970: $0) }
            )
        }

        var windows = [window(primary, id: "primary", fallback: "Primary")]
        if let secondary = limits["secondary"] as? [String: Any],
           (number(secondary, "windowDurationMins") ?? 0) > 0 {
            windows.append(window(secondary, id: "secondary", fallback: "Secondary"))
        }

        var out = ProviderResult(id: "codex", name: "Codex")
        out.plan = limits["planType"] as? String
        out.windows = windows
        if let name = limits["limitName"] as? String, !name.isEmpty { out.tags = [name] }
        if let reached = limits["rateLimitReachedType"], !(reached is NSNull) {
            out.rateLimited = true
        }
        return out
    }

    private static func newestSessionFiles(limit: Int) -> [URL] {
        let root = codexHome.appendingPathComponent("sessions")
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root,
                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        var files: [(URL, Date)] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append((url, date))
        }
        return files.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Last-resort read of recent session logs, used when app-server is unavailable.
    private static func fromSessionLogs() -> (windows: [QuotaWindow], plan: String?)? {
        for url in newestSessionFiles(limit: 10) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n").filter { $0.contains("\"rate_limits\"") }
            for line in lines.reversed() {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      let rl = payload["rate_limits"] as? [String: Any],
                      let primary = rl["primary"] as? [String: Any]
                else { continue }

                func number(_ dict: [String: Any], _ key: String) -> Double? {
                    (dict[key] as? NSNumber)?.doubleValue
                }
                var windows: [QuotaWindow] = []
                func add(_ dict: [String: Any], id: String, fallback: String) {
                    let mins = number(dict, "window_minutes")
                    guard id == "primary" || (mins ?? 0) > 0 else { return }
                    windows.append(QuotaWindow(
                        id: id,
                        label: windowLabel(minutes: mins, fallback: fallback),
                        usedPercent: number(dict, "used_percent"),
                        resetsAt: number(dict, "resets_at").map { Date(timeIntervalSince1970: $0) }))
                }
                add(primary, id: "primary", fallback: "Primary")
                if let secondary = rl["secondary"] as? [String: Any] {
                    add(secondary, id: "secondary", fallback: "Secondary")
                }
                return (windows, rl["plan_type"] as? String)
            }
        }
        return nil
    }

    static func fetch() async -> ProviderResult {
        do {
            let data = try await Task.detached(priority: .utility) {
                try appServerResponse()
            }.value
            return try liveResult(from: data)
        } catch {
            if let cached = fromSessionLogs() {
                var result = ProviderResult(id: "codex", name: "Codex")
                result.windows = cached.windows
                result.plan = cached.plan
                result.isStale = true
                Diagnostics.log("Codex app-server unavailable — using cached limits (\(error.localizedDescription))")
                return result
            }
            var result = ProviderResult(id: "codex", name: "Codex")
            result.error = error.localizedDescription
            result.hint = "Install or update Codex, then sign in with ChatGPT using `codex login`."
            return result
        }
    }
}
