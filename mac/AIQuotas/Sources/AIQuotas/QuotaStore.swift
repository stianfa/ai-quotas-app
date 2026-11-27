import AppKit
import Foundation
import SwiftUI

/// Owns the current snapshot and the refresh timer. Queries providers in parallel
/// so one slow or failing provider never hides the others.
@MainActor
final class QuotaStore: ObservableObject {
    static let maxTrailingInset: Double = 2_000

    @Published private(set) var snapshot: Snapshot = .empty
    @Published private(set) var isRefreshing = false
    /// Ticks every 30s purely so "resets in …" labels stay honest between fetches.
    @Published private(set) var now = Date()

    @AppStorage("refreshMinutes") var refreshMinutes: Int = 5 {
        didSet { restartTimer() }
    }

    // MARK: - Tracked providers

    @AppStorage("trackClaude") var trackClaude: Bool = true {
        willSet { objectWillChange.send() }
        didSet { handleTrackedProvidersChanged() }
    }
    @AppStorage("trackCodex") var trackCodex: Bool = true {
        willSet { objectWillChange.send() }
        didSet { handleTrackedProvidersChanged() }
    }
    @AppStorage("trackGemini") var trackGemini: Bool = true {
        willSet { objectWillChange.send() }
        didSet { handleTrackedProvidersChanged() }
    }

    var hasEnabledProviders: Bool { trackClaude || trackCodex || trackGemini }

    func isTracked(_ providerID: String) -> Bool {
        switch providerID {
        case "claude": return trackClaude
        case "codex": return trackCodex
        case "gemini": return trackGemini
        default: return false
        }
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
    @AppStorage("labelGemini") var labelGemini: String = "Gemini" {
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
    @AppStorage("centerOnScreen") var centerOnScreen = false {
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
        case "gemini": return labelGemini
        default: return ""
        }
    }

    /// The menu bar label for one card. With several Codex seats each gets its
    /// number ("Codex 1", "Codex 2") so the bars can be told apart.
    func label(for result: ProviderResult) -> String {
        let base = label(for: result.provider)
        guard let seat = result.seat, !base.isEmpty else { return base }
        return "\(base) \(seat)"
    }

    private var refreshTimer: Timer?
    private var clockTimer: Timer?
    /// When the in-flight refresh began, for the watchdog in `refresh()`.
    private var refreshStartedAt: Date?
    /// Set when the user enables a provider while another refresh is in flight.
    private var needsFollowUpRefresh = false
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

    private func handleTrackedProvidersChanged() {
        // Hide unchecked providers right away rather than waiting for the next fetch.
        snapshot = Snapshot(
            providers: snapshot.providers.filter { isTracked($0.provider) },
            fetchedAt: snapshot.fetchedAt
        )
        let loaded = Set(snapshot.providers.map(\.provider))
        let missingEnabled = (trackClaude && !loaded.contains("claude"))
            || (trackCodex && !loaded.contains("codex"))
            || (trackGemini && !loaded.contains("gemini"))
        guard missingEnabled else { return }

        if isRefreshing {
            needsFollowUpRefresh = true
        } else {
            Task { await refresh() }
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

        let wantClaude = trackClaude
        let wantCodex = trackCodex
        let wantGemini = trackGemini
        guard wantClaude || wantCodex || wantGemini else {
            snapshot = Snapshot(providers: [], fetchedAt: Date())
            now = Date()
            Diagnostics.log("refreshed — no providers enabled")
            return
        }

        isRefreshing = true
        refreshStartedAt = Date()
        var shouldFollowUp = false
        defer {
            isRefreshing = false
            refreshStartedAt = nil
            if shouldFollowUp {
                Task { @MainActor [weak self] in await self?.refresh() }
            }
        }

        async let claude: ProviderResult? = wantClaude ? ClaudeProvider.fetch() : nil
        // Codex returns one result per signed-in seat.
        async let codex: [ProviderResult] = wantCodex ? CodexProvider.fetchAll() : []
        async let gemini: ProviderResult? = wantGemini ? GeminiProvider.fetch() : nil
        let (claudeResult, codexResults, geminiResult) = await (claude, codex, gemini)
        let fetched = [claudeResult].compactMap { $0 } + codexResults + [geminiResult].compactMap { $0 }
        let providers = fetched.filter { isTracked($0.provider) }

        snapshot = Snapshot(providers: providers, fetchedAt: Date())
        now = Date()

        let summary = providers.map { p -> String in
            if let e = p.error { return "\(p.name)=error(\(e))" }
            let pct = p.headline?.usedPercent.map { String(format: "%.0f%%", $0) } ?? "—"
            return "\(p.name)=\(pct)"
        }.joined(separator: " ")
        Diagnostics.log("refreshed — \(summary.isEmpty ? "no providers enabled" : summary)")

        if needsFollowUpRefresh {
            needsFollowUpRefresh = false
            shouldFollowUp = true
        }
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
