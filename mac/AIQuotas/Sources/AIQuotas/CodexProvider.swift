import Foundation

/// Codex returns quota in `x-codex-*` response headers on the streaming endpoint.
/// We open the stream and cancel it the moment headers land, so no tokens are
/// generated and nothing is billed.
enum CodexProvider {
    private static let responsesURL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    private static var codexHome: URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return Credentials.home.appendingPathComponent(".codex")
    }
    private static var authFile: URL { codexHome.appendingPathComponent("auth.json") }

    private struct Tokens {
        var access: String
        var accountID: String
    }

    private static func refresh(_ root: [String: Any]) async throws -> Tokens {
        guard var tokens = root["tokens"] as? [String: Any],
              let refreshToken = tokens["refresh_token"] as? String
        else { throw QuotaError.authFailed("no refresh token available") }

        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "scope": "openid profile email",
        ])

        let (data, resp) = try await quotaSession.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw QuotaError.authFailed("token refresh failed — run `codex login`") }

        if let a = obj["access_token"] as? String { tokens["access_token"] = a }
        if let i = obj["id_token"] as? String { tokens["id_token"] = i }
        if let r = obj["refresh_token"] as? String { tokens["refresh_token"] = r }

        var updated = root
        updated["tokens"] = tokens
        updated["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        Credentials.writeJSONAtomic(authFile, updated)   // best-effort

        return Tokens(access: tokens["access_token"] as? String ?? "",
                      accountID: tokens["account_id"] as? String ?? "")
    }

    private static func tokens() async throws -> Tokens {
        guard let root = Credentials.readJSON(authFile),
              let tok = root["tokens"] as? [String: Any],
              let access = tok["access_token"] as? String
        else { throw QuotaError.noCredentials("no Codex credentials found") }

        if let exp = Credentials.jwtExpiryMS(access),
           exp - Date().timeIntervalSince1970 * 1000 < 60_000 {
            return try await refresh(root)
        }
        return Tokens(access: access, accountID: tok["account_id"] as? String ?? "")
    }

    /// The model must be one the account can actually use, so read the CLI's config.
    private static func model() -> String {
        if let m = Credentials.topLevelTOMLString(codexHome.appendingPathComponent("config.toml"), key: "model") {
            return m
        }
        if let m = modelFromRecentSession() { return m }
        return "gpt-5.6-sol"
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

    private static func modelFromRecentSession() -> String? {
        guard let url = newestSessionFiles(limit: 1).first,
              let text = try? String(contentsOf: url, encoding: .utf8),
              let r = text.range(of: "\"model\"\\s*:\\s*\"([^\"]+)\"", options: .regularExpression)
        else { return nil }
        let seg = String(text[r])
        guard let colon = seg.firstIndex(of: ":") else { return nil }
        let after = seg[seg.index(after: colon)...]
        guard let q1 = after.firstIndex(of: "\""), let q2 = after.lastIndex(of: "\""), q1 < q2
        else { return nil }
        return String(after[after.index(after: q1)..<q2])
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

    /// Last-resort read of recent session logs, used when the network call fails.
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

                var windows: [QuotaWindow] = []
                func add(_ dict: [String: Any], id: String, fallback: String) {
                    let mins = dict["window_minutes"] as? Double
                    guard id == "primary" || (mins ?? 0) > 0 else { return }
                    windows.append(QuotaWindow(
                        id: id,
                        label: windowLabel(minutes: mins, fallback: fallback),
                        usedPercent: dict["used_percent"] as? Double,
                        resetsAt: (dict["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }))
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

    /// Cancels the request as soon as response headers arrive — we never read the body.
    private final class HeaderOnlyDelegate: NSObject, URLSessionDataDelegate {
        private let cont: CheckedContinuation<HTTPURLResponse, Error>
        private var resumed = false

        init(_ cont: CheckedContinuation<HTTPURLResponse, Error>) { self.cont = cont }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
            if let http = response as? HTTPURLResponse, !resumed {
                resumed = true
                cont.resume(returning: http)
            }
            return .cancel
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard !resumed else { return }
            resumed = true
            cont.resume(throwing: error ?? QuotaError.message("no response"))
        }
    }

    private static func headers(for request: URLRequest) async throws -> HTTPURLResponse {
        let delegate = HeaderOnlyDelegate.self
        return try await withCheckedThrowingContinuation { cont in
            let d = HeaderOnlyDelegate(cont)
            _ = delegate
            // Must carry the same timeouts as `quotaSession`. A bare `.ephemeral`
            // config defaults to a 7-day resource timeout, so a request in flight
            // when the Mac sleeps never completes and this continuation never
            // resumes — which used to wedge refresh() permanently.
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 20
            cfg.timeoutIntervalForResource = 25
            cfg.waitsForConnectivity = false
            let session = URLSession(configuration: cfg, delegate: d, delegateQueue: nil)
            session.dataTask(with: request).resume()
            session.finishTasksAndInvalidate()
        }
    }

    static func fetch() async -> ProviderResult {
        var result = ProviderResult(id: "codex", name: "Codex")

        let tok: Tokens
        do {
            tok = try await tokens()
        } catch {
            result.error = error.localizedDescription
            result.hint = "Install the Codex CLI and run `codex login`."
            return result
        }

        var req = URLRequest(url: responsesURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(tok.access)", forHTTPHeaderField: "authorization")
        req.setValue(tok.accountID, forHTTPHeaderField: "chatgpt-account-id")
        req.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "session_id")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model(),
            "instructions": "x",
            "input": [["type": "message", "role": "user",
                       "content": [["type": "input_text", "text": "hi"]]]],
            "stream": true,
            "store": false,
            "tools": [],
        ])

        func fallback(_ why: String) -> ProviderResult {
            var r = result
            if let cached = fromSessionLogs() {
                r.windows = cached.windows
                r.plan = cached.plan
                r.isStale = true
                r.error = nil
            } else if r.error == nil {
                r.error = why
            }
            return r
        }

        do {
            let http = try await headers(for: req)
            func header(_ k: String) -> String? { http.value(forHTTPHeaderField: k) }
            func dbl(_ k: String) -> Double? { header(k).flatMap(Double.init) }

            guard let primary = dbl("x-codex-primary-used-percent") else {
                result.error = "no quota headers returned (HTTP \(http.statusCode))"
                if http.statusCode == 401 { result.hint = "Token rejected — run `codex login`." }
                return fallback(result.error!)
            }

            var windows = [QuotaWindow(
                id: "primary",
                label: windowLabel(minutes: dbl("x-codex-primary-window-minutes"), fallback: "Primary"),
                usedPercent: primary,
                resetsAt: dbl("x-codex-primary-reset-at").map { Date(timeIntervalSince1970: $0) })]

            // Codex sends a zeroed secondary window when the plan has only one limit.
            if let secMinutes = dbl("x-codex-secondary-window-minutes"), secMinutes > 0 {
                windows.append(QuotaWindow(
                    id: "secondary",
                    label: windowLabel(minutes: secMinutes, fallback: "Secondary"),
                    usedPercent: dbl("x-codex-secondary-used-percent"),
                    resetsAt: dbl("x-codex-secondary-reset-at").map { Date(timeIntervalSince1970: $0) }))
            }

            result.windows = windows
            result.plan = header("x-codex-plan-type")
            if let active = header("x-codex-active-limit") { result.tags = [active] }
            result.rateLimited = http.statusCode == 429
        } catch {
            result.error = "network error: \(error.localizedDescription)"
            return fallback(result.error!)
        }
        return result
    }
}
