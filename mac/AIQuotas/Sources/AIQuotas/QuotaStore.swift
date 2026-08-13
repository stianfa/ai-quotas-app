import AppKit
import Foundation
import SwiftUI

/// Owns the current snapshot and the refresh timer. Queries providers in parallel
/// so one slow or failing provider never hides the others.
@MainActor
final class QuotaStore: ObservableObject {
    @Published private(set) var snapshot: Snapshot = .empty
    @Published private(set) var isRefreshing = false
    /// Ticks every 30s purely so "resets in …" labels stay honest between fetches.
    @Published private(set) var now = Date()

    @AppStorage("refreshMinutes") var refreshMinutes: Int = 5 {
        didSet { restartTimer() }
    }

    // MARK: - Menu bar appearance
    //
    // These drive MenuBarRenderer. `objectWillChange.send()` is explicit because
    // @AppStorage on a non-View type doesn't republish on its own, and the status
    // item only redraws when this object announces a change.

    /// Label shown before each bar. Empty hides labels entirely.
    @AppStorage("labelClaude") var labelClaude: String = "Claude" {
        willSet { objectWillChange.send() }
    }
    @AppStorage("labelCodex") var labelCodex: String = "Codex" {
        willSet { objectWillChange.send() }
    }
    @AppStorage("barWidth") var barWidth: Double = 42 {
        willSet { objectWillChange.send() }
    }
    @AppStorage("barHeight") var barHeight: Double = 7 {
        willSet { objectWillChange.send() }
    }
    @AppStorage("showPercentText") var showPercentText: Bool = true {
        willSet { objectWillChange.send() }
    }
    /// Show a compact countdown to the next reset, e.g. "6d".
    @AppStorage("showReset") var showReset: Bool = true {
        willSet { objectWillChange.send() }
    }
    /// Blank space padded onto the right of the menu bar image. macOS packs status
    /// items right-to-left from the clock with no positioning API, so this is the
    /// only way to nudge the readout further left.
    @AppStorage("trailingInset") var trailingInset: Double = 10 {
        willSet { objectWillChange.send() }
    }

    /// The user-facing label for a provider, falling back to its built-in name.
    func label(for providerID: String) -> String {
        switch providerID {
        case "claude": return labelClaude
        case "codex": return labelCodex
        default: return ""
        }
    }

    private var refreshTimer: Timer?
    private var clockTimer: Timer?
    /// When the in-flight refresh began, for the watchdog in `refresh()`.
    private var refreshStartedAt: Date?
    /// Past this, an in-flight refresh is presumed dead and may be superseded.
    /// Comfortably above the providers' own 25s resource timeout.
    private static let refreshWatchdog: TimeInterval = 90

    init() {
        restartTimer()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.now = Date() }
        }

        // Timers don't reliably keep their cadence across sleep, so a wake can
        // otherwise leave the readout stale until the next tick happens to land.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                Diagnostics.log("woke from sleep — refreshing")
                self.restartTimer()
                await self.refresh()
            }
        }

        Task { await refresh() }
    }

    private func restartTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(max(1, refreshMinutes) * 60)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    func refresh() async {
        // A refresh that never returns must not lock out every later attempt.
        // Providers own timeouts, but a hang below that layer (a continuation that
        // is never resumed, a stall across sleep) would otherwise leave this flag
        // stuck true and silently freeze the menu bar until relaunch.
        if isRefreshing {
            guard let started = refreshStartedAt,
                  Date().timeIntervalSince(started) > Self.refreshWatchdog
            else { return }
            Diagnostics.log("previous refresh hung — starting a new one")
        }
        isRefreshing = true
        refreshStartedAt = Date()
        defer {
            isRefreshing = false
            refreshStartedAt = nil
        }

        async let claude = ClaudeProvider.fetch()
        async let codex = CodexProvider.fetch()
        let providers = await [claude, codex]

        snapshot = Snapshot(providers: providers, fetchedAt: Date())
        now = Date()

        let summary = providers.map { p -> String in
            if let e = p.error { return "\(p.name)=error(\(e))" }
            let pct = p.headline?.usedPercent.map { String(format: "%.0f%%", $0) } ?? "—"
            return "\(p.name)=\(pct)"
        }.joined(separator: " ")
        Diagnostics.log("refreshed — \(summary)")
    }

    /// Highest usage across every provider — what the menu bar shows at a glance.
    var worstPercent: Double? {
        snapshot.providers
            .filter(\.isOK)
            .compactMap { $0.headline?.usedPercent }
            .max()
    }

    var hasError: Bool { snapshot.providers.contains { !$0.isOK } }
}
