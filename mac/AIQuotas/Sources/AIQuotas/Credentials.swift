import Foundation

/// Access to local CLI configuration. Reads and the narrowly-scoped Claude OAuth
/// refresh write go through the same system tools and files used by the owning CLI.
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

    /// Updates an existing generic-password item through the Apple-signed
    /// `/usr/bin/security` process. `-U` preserves the item's ACL, so rebuilding
    /// this ad-hoc-signed app does not create a new Keychain access prompt.
    static func keychainWrite(service: String, account: String = "default", data: Data) -> Bool {
        guard let secret = String(data: data, encoding: .utf8) else { return false }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = [
            "add-generic-password", "-U",
            "-s", service,
            "-a", account,
            "-w", secret,
        ]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()

        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Files

    static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// Atomically replaces a JSON credential file while keeping it private to
    /// the current user, matching Claude Code's file-store permissions.
    static func writeJSON(_ object: [String: Any], to url: URL) -> Bool {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return false }
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
            return true
        } catch {
            return false
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

}

/// Shared URLSession with sane timeouts — a hung provider must not freeze the menu.
let quotaSession: URLSession = {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 20
    cfg.timeoutIntervalForResource = 25
    cfg.waitsForConnectivity = false
    return URLSession(configuration: cfg)
}()
