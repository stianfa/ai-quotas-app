import Foundation
import Security

/// Reads the logins the Claude Code and Codex CLIs already wrote, and keeps their
/// access tokens fresh. Tokens are written back to the same stores so this app and
/// the CLIs stay in sync rather than invalidating each other.
enum Credentials {

    // MARK: - Keychain

    /// Reads a keychain secret by shelling out to `/usr/bin/security`.
    ///
    /// This looks roundabout versus calling SecItemCopyMatching directly, but it is
    /// deliberate. Keychain items grant access to specific *code identities*, and the
    /// item Claude Code writes trusts exactly one app: `/usr/bin/security`, anchored
    /// to Apple. Any other reader — including this app — triggers an "allow access?"
    /// prompt, and because a locally-signed app's identity changes whenever its code
    /// changes, that prompt returns after every rebuild.
    ///
    /// Going through `security` means the trusted, Apple-signed binary does the read,
    /// so there is no prompt at all. This is also how the Claude Code CLI reads it.
    static func keychainRead(service: String) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", service, "-w"]

        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()   // discard "item not found" noise

        do {
            try proc.run()
        } catch {
            return nil
        }
        // Read before waiting so a large secret can't deadlock on a full pipe buffer.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else { return nil }
        // `-w` prints the password followed by a newline.
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)
    }

    /// Writes a keychain secret via `/usr/bin/security`, for the same reason as
    /// `keychainRead` — it keeps the trusted Apple-signed binary as the only
    /// accessor, so refreshing a token never raises a permission prompt.
    ///
    @discardableResult
    static func keychainWrite(service: String, account: String, data: Data) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        // -U updates in place, preserving the item's existing ACL.
        // -X takes the secret as hex, which avoids the quoting hazards of raw JSON.
        proc.arguments = [
            "add-generic-password", "-U",
            "-s", service, "-a", account,
            "-X", data.map { String(format: "%02X", $0) }.joined(),
        ]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()

        do {
            try proc.run()
        } catch {
            return false
        }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    // MARK: - Files

    static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// Write via a temp file + rename so a crash can't leave a half-written credential file.
    static func writeJSONAtomic(_ url: URL, _ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]) else { return }
        let tmp = url.appendingPathExtension("tmp-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try data.write(to: tmp, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    /// Reads a top-level `key = "value"` from a TOML file, stopping at the first table
    /// header so nested `[profiles.*]` keys of the same name don't win.
    static func topLevelTOMLString(_ url: URL, key: String) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            guard line.hasPrefix(key) else { continue }
            let pattern = "^\(key)\\s*=\\s*\"([^\"]+)\""
            if let m = line.range(of: pattern, options: .regularExpression) {
                let seg = String(line[m])
                if let q1 = seg.firstIndex(of: "\""),
                   let q2 = seg.lastIndex(of: "\""), q1 < q2 {
                    return String(seg[seg.index(after: q1)..<q2])
                }
            }
        }
        return nil
    }

    /// Milliseconds-since-epoch of a JWT's `exp`, used to refresh before expiry.
    static func jwtExpiryMS(_ token: String) -> Double? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = obj["exp"] as? Double
        else { return nil }
        return exp * 1000
    }
}

/// Shared URLSession with sane timeouts — a hung provider must not freeze the menu.
let quotaSession: URLSession = {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 20
    cfg.timeoutIntervalForResource = 25
    cfg.waitsForConnectivity = false
    return URLSession(configuration: cfg)
}()
