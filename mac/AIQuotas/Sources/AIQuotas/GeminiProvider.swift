import Foundation

/// Reads Gemini / Antigravity quota through the official Antigravity CLI (`agy`).
/// Antigravity owns Google OAuth authentication and token refresh; this app never
/// reads or modifies credential files directly.
enum GeminiProvider {
    private static func agyExecutable() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let explicit = ProcessInfo.processInfo.environment["AGY_PATH"], !explicit.isEmpty {
            candidates.append(URL(fileURLWithPath: explicit))
        }
        candidates += [
            Credentials.home.appendingPathComponent(".gemini/bin/agy"),
            URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
            URL(fileURLWithPath: "/usr/local/bin/agy"),
            Credentials.home.appendingPathComponent(".local/bin/agy"),
        ]
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") where !dir.isEmpty {
                candidates.append(URL(fileURLWithPath: String(dir)).appendingPathComponent("agy"))
            }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    private final class TimeoutState: @unchecked Sendable {
        let process: Process
        private let lock = NSLock()
        private var didTimeOut = false

        init(_ process: Process) { self.process = process }

        func triggerTimeout() {
            lock.lock()
            let shouldTerminate = process.isRunning
            if shouldTerminate { didTimeOut = true }
            lock.unlock()
            if shouldTerminate { process.terminate() }
        }

        var timedOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return didTimeOut
        }
    }

    /// Blocking CLI invocation, always run from a detached utility task.
    private static func agyUsageResponse() throws -> Data {
        guard let executable = agyExecutable() else {
            throw QuotaError.message("Antigravity CLI (agy) not found")
        }

        let proc = Process()
        proc.executableURL = executable
        proc.arguments = ["-p", "/usage", "--output-format", "json"]
        proc.currentDirectoryURL = Credentials.home

        var environment = ProcessInfo.processInfo.environment
        let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "\(executable.deletingLastPathComponent().path):\(inheritedPath)"
        proc.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        try proc.run()

        let state = TimeoutState(proc)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 20)
        timer.setEventHandler { state.triggerTimeout() }
        timer.resume()
        defer {
            timer.cancel()
            if proc.isRunning { proc.terminate() }
        }

        // Drain stdout and stderr concurrently so neither pipe can fill and deadlock.
        final class DataBox: @unchecked Sendable {
            var data = Data()
        }
        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outBox.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        proc.waitUntilExit()

        if state.timedOut {
            throw QuotaError.message("Antigravity CLI timed out")
        }
        guard proc.terminationStatus == 0 else {
            let errText = String(data: errBox.data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let outText = String(data: outBox.data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = (!errText.isEmpty ? errText : outText).prefix(180)
            let suffix = detail.isEmpty ? "" : ": \(detail)"
            throw QuotaError.message("Antigravity CLI failed (code \(proc.terminationStatus))\(suffix)")
        }
        return outBox.data
    }

    private static func parsePayload(from data: Data) throws -> [String: Any] {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        if let text = String(data: data, encoding: .utf8) {
            for rawLine in text.split(separator: "\n").reversed() {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasPrefix("{"),
                      let lineData = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      object["command"] != nil || object["status"] != nil
                else { continue }
                return object
            }
        }
        throw QuotaError.message("malformed Antigravity CLI response")
    }

    private static func shortGroupName(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.hasPrefix("gemini") { return "Gemini" }
        if lower.contains("claude") && lower.contains("gpt") { return "Claude & GPT" }
        return name.replacingOccurrences(
            of: #"\s+models$"#, with: "", options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespaces)
    }

    private static func windowOrder(_ bucket: [String: Any]) -> Int {
        switch (bucket["window"] as? String ?? "").lowercased() {
        case "5h": return 0
        case "daily": return 1
        case "weekly": return 2
        default: return 3
        }
    }

    private static func windowName(_ bucket: [String: Any], capitalize: Bool) -> String {
        switch (bucket["window"] as? String ?? "").lowercased() {
        case "5h": return "5-hour"
        case "daily": return capitalize ? "Daily" : "daily"
        case "weekly": return capitalize ? "Weekly" : "weekly"
        default:
            let raw = (bucket["name"] as? String)
                ?? (bucket["window"] as? String)
                ?? (bucket["id"] as? String)
                ?? "Limit"
            let cleaned = raw
                .replacingOccurrences(
                    of: #"\s+limit(\s+remaining)?$"#, with: "", options: [.regularExpression, .caseInsensitive]
                )
                .replacingOccurrences(
                    of: #"\s+remaining$"#, with: "", options: [.regularExpression, .caseInsensitive]
                )
                .trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? "Limit" : cleaned
        }
    }

    private static func parseResetTime(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: raw)
    }

    private static func liveResult(from data: Data) throws -> ProviderResult {
        let payload = try parsePayload(from: data)

        if let status = payload["status"] as? String, status != "SUCCESS" {
            let detail = (payload["error"] as? String)
                ?? (payload["response"] as? String)
                ?? "status \(status)"
            throw QuotaError.message("Antigravity usage error: \(detail)")
        }

        guard let command = payload["command"] as? [String: Any],
              let commandData = command["data"] as? [String: Any],
              let groups = commandData["groups"] as? [[String: Any]],
              !groups.isEmpty
        else {
            throw QuotaError.message("Antigravity returned no quota data")
        }

        let multiGroup = groups.count > 1
        var windows: [QuotaWindow] = []

        for group in groups {
            let rawBuckets = (group["buckets"] as? [[String: Any]]) ?? []
            let sortedBuckets = rawBuckets.enumerated().sorted { lhs, rhs in
                let lo = windowOrder(lhs.element)
                let ro = windowOrder(rhs.element)
                return lo != ro ? lo < ro : lhs.offset < rhs.offset
            }.map(\.element)

            let prefix = shortGroupName(group["name"] as? String ?? "")
            for bucket in sortedBuckets {
                let resetRaw = bucket["reset_time"] as? String
                let usedPercent: Double?
                if let remaining = (bucket["remaining_fraction"] as? NSNumber)?.doubleValue {
                    usedPercent = max(0, min(100, (1.0 - remaining) * 100.0))
                } else if let resetRaw, !resetRaw.isEmpty {
                    // Proto3 JSON omits 0.0 float fields, so an active bucket with no
                    // remaining_fraction means 0% remaining (100% used).
                    usedPercent = 100
                } else {
                    usedPercent = nil
                }

                let wLabel = windowName(bucket, capitalize: !multiGroup)
                let label = (multiGroup && !prefix.isEmpty) ? "\(prefix) \(wLabel)" : wLabel
                let id = (bucket["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "\(prefix.lowercased())-\(bucket["window"] as? String ?? "limit")"

                windows.append(QuotaWindow(
                    id: id,
                    label: label,
                    usedPercent: usedPercent,
                    resetsAt: parseResetTime(resetRaw)
                ))
            }
        }

        guard !windows.isEmpty else {
            throw QuotaError.message("Antigravity returned no quota windows")
        }

        var out = ProviderResult(id: "gemini", name: "Gemini")
        out.plan = "antigravity"
        out.windows = windows
        out.rateLimited = windows.contains { ($0.usedPercent ?? 0) >= 100 }
        return out
    }

    static func fetch() async -> ProviderResult {
        do {
            let data = try await Task.detached(priority: .utility) {
                try agyUsageResponse()
            }.value
            return try liveResult(from: data)
        } catch {
            var result = ProviderResult(id: "gemini", name: "Gemini")
            result.error = error.localizedDescription
            result.hint = "Install Antigravity and sign in with `agy`."
            return result
        }
    }
}
