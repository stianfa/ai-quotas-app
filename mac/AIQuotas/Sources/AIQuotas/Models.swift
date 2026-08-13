import Foundation

/// One rate-limit window (e.g. Claude's 5-hour session, Codex's weekly).
struct QuotaWindow: Identifiable, Equatable {
    let id: String
    let label: String
    /// nil when the provider exposes the window but has no number for it.
    let usedPercent: Double?
    let resetsAt: Date?

    enum Level { case ok, warn, crit, unknown }

    var level: Level {
        guard let p = usedPercent else { return .unknown }
        if p >= 90 { return .crit }
        if p >= 70 { return .warn }
        return .ok
    }
}

struct ProviderResult: Identifiable, Equatable {
    let id: String
    let name: String
    var plan: String?
    var windows: [QuotaWindow] = []
    var tags: [String] = []
    var error: String?
    var hint: String?
    var rateLimited = false
    var isStale = false

    var isOK: Bool { error == nil }

    /// The window that best represents "how much have I used" for a one-glance summary.
    var headline: QuotaWindow? {
        windows.max { ($0.usedPercent ?? -1) < ($1.usedPercent ?? -1) }
    }
}

struct Snapshot: Equatable {
    var providers: [ProviderResult]
    var fetchedAt: Date

    static let empty = Snapshot(providers: [], fetchedAt: .distantPast)
}

enum QuotaError: LocalizedError {
    case noCredentials(String)
    case authFailed(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials(let s): return s
        case .authFailed(let s): return s
        case .message(let s): return s
        }
    }
}

/// Formats a reset time the way you'd say it out loud: "4h 47m", "6d 23h".
func relativeReset(_ date: Date?, now: Date = Date()) -> String? {
    guard let date else { return nil }
    let secs = Int(date.timeIntervalSince(now))
    if secs <= 0 { return "resetting now" }
    let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
    if d > 0 { return "resets in \(d)d \(h)h" }
    if h > 0 { return "resets in \(h)h \(m)m" }
    if m > 0 { return "resets in \(m)m" }
    return "resets in under a minute"
}

/// A single-unit countdown for the menu bar, where space is tight: "6d", "4h", "12m".
///
/// Truncates rather than rounds, so the value reads as "at least this much time
/// left" — 6d1h is "6d", not "7d". Sub-minute clamps to "1m" so it never shows
/// "0m" while time remains.
func compactReset(_ date: Date?, now: Date = Date()) -> String? {
    guard let date else { return nil }
    let secs = Int(date.timeIntervalSince(now))
    if secs <= 0 { return "now" }
    if secs >= 86400 { return "\(secs / 86400)d" }
    if secs >= 3600 { return "\(secs / 3600)h" }
    return "\(max(1, secs / 60))m"
}
