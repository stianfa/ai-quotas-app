import Foundation

/// Anthropic reports quota only on real API responses, so we send the smallest
/// possible request (1 token, cheapest model) and read the response headers.
enum ClaudeProvider {
    private static let service = "Claude Code-credentials"
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let api = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    private static let systemPrompt = "You are Claude Code, Anthropic's official CLI for Claude."

    private static var credsFile: URL {
        Credentials.home.appendingPathComponent(".claude/.credentials.json")
    }

    private struct Store {
        var root: [String: Any]
        var oauth: [String: Any]
        var fromKeychain: Bool
    }

    private static func load() -> Store? {
        if let data = Credentials.keychainRead(service: service),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = root["claudeAiOauth"] as? [String: Any] {
            return Store(root: root, oauth: oauth, fromKeychain: true)
        }
        if let root = Credentials.readJSON(credsFile),
           let oauth = root["claudeAiOauth"] as? [String: Any] {
            return Store(root: root, oauth: oauth, fromKeychain: false)
        }
        return nil
    }

    private static func save(_ store: Store) {
        var root = store.root
        root["claudeAiOauth"] = store.oauth
        if store.fromKeychain {
            if let data = try? JSONSerialization.data(withJSONObject: root) {
                Credentials.keychainWrite(service: service, account: "default", data: data)
            }
        } else {
            Credentials.writeJSONAtomic(credsFile, root)
        }
    }

    private static func refresh(_ store: Store) async throws -> String {
        guard let refreshToken = store.oauth["refreshToken"] as? String else {
            throw QuotaError.authFailed("no refresh token available")
        }
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])

        let (data, resp) = try await quotaSession.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw QuotaError.authFailed("token refresh failed — run `claude` to sign in again")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String
        else { throw QuotaError.authFailed("malformed refresh response") }

        var updated = store
        updated.oauth["accessToken"] = access
        if let rt = obj["refresh_token"] as? String { updated.oauth["refreshToken"] = rt }
        if let expiresIn = obj["expires_in"] as? Double {
            updated.oauth["expiresAt"] = Date().timeIntervalSince1970 * 1000 + expiresIn * 1000
        }
        save(updated)   // best-effort; a read-only store shouldn't break reading
        return access
    }

    private static func accessToken() async throws -> String {
        guard let store = load() else {
            throw QuotaError.noCredentials("no Claude Code credentials found")
        }
        // Refresh a minute early so a token can't expire mid-flight.
        if let expiresAt = store.oauth["expiresAt"] as? Double,
           expiresAt - Date().timeIntervalSince1970 * 1000 < 60_000 {
            return try await refresh(store)
        }
        guard let token = store.oauth["accessToken"] as? String else {
            throw QuotaError.noCredentials("no access token in credentials")
        }
        return token
    }

    static func fetch() async -> ProviderResult {
        var result = ProviderResult(id: "claude", name: "Claude")

        let token: String
        do {
            token = try await accessToken()
        } catch {
            result.error = error.localizedDescription
            result.hint = "Install Claude Code and sign in — this reads the same login."
            return result
        }

        var req = URLRequest(url: api)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "system": systemPrompt,
            "messages": [["role": "user", "content": "hi"]],
        ])

        do {
            let (body, resp) = try await quotaSession.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                result.error = "unexpected response"
                return result
            }
            // A 429 still carries the quota headers — exactly when they matter most.
            if !(200..<300).contains(http.statusCode) && http.statusCode != 429 {
                let detail = String(data: body, encoding: .utf8)?.prefix(160) ?? ""
                result.error = "HTTP \(http.statusCode)\(detail.isEmpty ? "" : ": \(detail)")"
                if http.statusCode == 401 { result.hint = "Token rejected — run `claude` to sign in again." }
                return result
            }

            func header(_ key: String) -> String? {
                http.value(forHTTPHeaderField: key)
            }
            func pct(_ key: String) -> Double? {
                header(key).flatMap(Double.init).map { $0 * 100 }   // headers report 0..1
            }
            func reset(_ key: String) -> Date? {
                header(key).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            }

            var windows: [QuotaWindow] = [
                QuotaWindow(id: "five_hour", label: "5-hour session",
                            usedPercent: pct("anthropic-ratelimit-unified-5h-utilization"),
                            resetsAt: reset("anthropic-ratelimit-unified-5h-reset")),
                QuotaWindow(id: "seven_day", label: "7-day",
                            usedPercent: pct("anthropic-ratelimit-unified-7d-utilization"),
                            resetsAt: reset("anthropic-ratelimit-unified-7d-reset")),
            ]

            // Overage applies only to some plans — show it only when it's in play.
            let overageStatus = header("anthropic-ratelimit-unified-overage-status")
            if let op = pct("anthropic-ratelimit-unified-overage-utilization"),
               let st = overageStatus, st != "not_enabled" {
                windows.append(QuotaWindow(id: "overage", label: "Overage", usedPercent: op,
                                           resetsAt: reset("anthropic-ratelimit-unified-overage-reset")))
            }

            let status = header("anthropic-ratelimit-unified-status")
            result.windows = windows
            result.plan = (load()?.oauth["subscriptionType"] as? String)
            result.rateLimited = (status == "rejected" || http.statusCode == 429)
        } catch {
            result.error = "network error: \(error.localizedDescription)"
        }
        return result
    }
}
