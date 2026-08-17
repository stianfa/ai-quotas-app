import Foundation

/// Anthropic reports quota only on real API responses, so we send the smallest
/// possible request (1 token, cheapest model) and read the response headers.
enum ClaudeProvider {
    private static let service = "Claude Code-credentials"
    private static let api = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let tokenAPI = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let defaultClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let systemPrompt = "You are Claude Code, Anthropic's official CLI for Claude."
    private static let refreshLeeway: TimeInterval = 5 * 60

    private static var credsFile: URL {
        Credentials.home.appendingPathComponent(".claude/.credentials.json")
    }

    private enum StoreLocation: Sendable {
        case keychain
        case file
    }

    /// JSONSerialization values are immutable JSON scalars, arrays, and
    /// dictionaries. A Store stays inside one refresh task and is never shared.
    private struct Store: @unchecked Sendable {
        var root: [String: Any]
        var oauth: [String: Any]
        var location: StoreLocation
    }

    private struct RefreshResponse: Decodable, Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double
        let refreshTokenExpiresIn: Double?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case refreshTokenExpiresIn = "refresh_token_expires_in"
            case scope
        }
    }

    /// Claude Code uses this directory lock before rotating its OAuth token. By
    /// taking the same lock, AI Quotas cannot race the CLI's credential update.
    private struct RefreshLock: Sendable {
        let url: URL

        static func acquire() async throws -> RefreshLock {
            let fm = FileManager.default
            let url = Credentials.home.appendingPathComponent(".claude/.oauth_refresh.lock")

            for attempt in 0..<6 {
                do {
                    try fm.createDirectory(at: url, withIntermediateDirectories: false)
                    return RefreshLock(url: url)
                } catch {
                    if let attrs = try? fm.attributesOfItem(atPath: url.path),
                       let modified = attrs[.modificationDate] as? Date,
                       Date().timeIntervalSince(modified) > 60 {
                        try? fm.removeItem(at: url)
                        continue
                    }
                    guard attempt < 5 else {
                        throw QuotaError.authFailed(
                            "Claude credential refresh is busy — try again shortly"
                        )
                    }
                    try await Task.sleep(
                        nanoseconds: UInt64.random(in: 1_000_000_000...2_000_000_000)
                    )
                }
            }
            throw QuotaError.authFailed("Claude credential refresh is busy")
        }

        func release() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func load() -> Store? {
        if let data = Credentials.keychainRead(service: service),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = root["claudeAiOauth"] as? [String: Any] {
            return Store(root: root, oauth: oauth, location: .keychain)
        }
        if let root = Credentials.readJSON(credsFile),
           let oauth = root["claudeAiOauth"] as? [String: Any] {
            return Store(root: root, oauth: oauth, location: .file)
        }
        return nil
    }

    private static func persist(_ store: Store) -> Bool {
        var root = store.root
        root["claudeAiOauth"] = store.oauth
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(withJSONObject: root)
        else { return false }

        switch store.location {
        case .keychain:
            return Credentials.keychainWrite(service: service, data: data)
        case .file:
            return Credentials.writeJSON(root, to: credsFile)
        }
    }

    private static func expiry(_ oauth: [String: Any], key: String) -> Double? {
        (oauth[key] as? NSNumber)?.doubleValue
    }

    private static func tokenIsFresh(_ oauth: [String: Any], now: Date = Date()) -> Bool {
        guard let expiresAt = expiry(oauth, key: "expiresAt") else { return true }
        return expiresAt - now.timeIntervalSince1970 * 1000 > refreshLeeway * 1000
    }

    private static func accessToken() async throws -> String {
        guard let initial = load() else {
            throw QuotaError.noCredentials("no Claude Code credentials found")
        }

        if tokenIsFresh(initial.oauth),
           let token = initial.oauth["accessToken"] as? String {
            return token
        }

        let lock = try await RefreshLock.acquire()
        defer { lock.release() }

        // Re-read after taking Claude Code's lock: the CLI may have refreshed
        // while this app was waiting.
        guard var current = load() else {
            throw QuotaError.noCredentials("no Claude Code credentials found")
        }
        if let token = current.oauth["accessToken"] as? String,
           tokenIsFresh(current.oauth) {
            return token
        }

        guard let refreshToken = current.oauth["refreshToken"] as? String,
              !refreshToken.isEmpty else {
            throw QuotaError.authFailed("Claude login cannot be refreshed — run `claude` to sign in")
        }
        if let refreshExpiresAt = expiry(current.oauth, key: "refreshTokenExpiresAt"),
           refreshExpiresAt <= Date().timeIntervalSince1970 * 1000 {
            throw QuotaError.authFailed("Claude login expired — run `claude` to sign in again")
        }

        var payload: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": current.oauth["clientId"] as? String ?? defaultClientID,
        ]
        if let scopes = current.oauth["scopes"] as? [String], !scopes.isEmpty {
            payload["scope"] = scopes.joined(separator: " ")
        }

        var req = URLRequest(url: tokenAPI)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let response: RefreshResponse
        do {
            let (body, rawResponse) = try await quotaSession.data(for: req)
            guard let http = rawResponse as? HTTPURLResponse else {
                throw QuotaError.authFailed("unexpected Claude token-refresh response")
            }
            guard (200..<300).contains(http.statusCode) else {
                let detail = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
                let reason = detail?["error_description"] as? String
                    ?? detail?["error"] as? String
                let suffix = reason.map { ": \($0.prefix(160))" } ?? ""
                throw QuotaError.authFailed(
                    "Claude token refresh failed (HTTP \(http.statusCode))\(suffix)"
                )
            }
            response = try JSONDecoder().decode(RefreshResponse.self, from: body)
        } catch let error as QuotaError {
            throw error
        } catch {
            throw QuotaError.authFailed("Claude token refresh failed: \(error.localizedDescription)")
        }

        let nowMilliseconds = Date().timeIntervalSince1970 * 1000
        current.oauth["accessToken"] = response.accessToken
        current.oauth["refreshToken"] = response.refreshToken ?? refreshToken
        current.oauth["expiresAt"] = nowMilliseconds + response.expiresIn * 1000
        if let refreshSeconds = response.refreshTokenExpiresIn {
            current.oauth["refreshTokenExpiresAt"] = nowMilliseconds + refreshSeconds * 1000
        }
        if let scope = response.scope {
            current.oauth["scopes"] = scope.split(separator: " ").map(String.init)
        }

        guard persist(current) else {
            throw QuotaError.authFailed(
                "Claude token refreshed but could not be saved — run `claude` once"
            )
        }
        Diagnostics.log("refreshed Claude OAuth token")
        return response.accessToken
    }

    static func fetch() async -> ProviderResult {
        var result = ProviderResult(id: "claude", name: "Claude")

        let token: String
        do {
            token = try await accessToken()
        } catch {
            result.error = error.localizedDescription
            result.hint = "Install Claude Code and sign in; AI Quotas refreshes that session when needed."
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
