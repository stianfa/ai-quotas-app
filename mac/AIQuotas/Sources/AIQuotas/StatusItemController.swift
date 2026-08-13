import AppKit
import Combine
import SwiftUI

/// Owns the real `NSStatusItem` and the popover it opens.
///
/// SwiftUI's `MenuBarExtra` is the obvious tool here, but its label sizing is
/// unreliable for variable-width text: an `HStack` of several views gets measured
/// too narrow and silently clipped, while a single interpolated `Text` can collapse
/// to just the icon. Driving `NSStatusItem` directly means we set the button's
/// title ourselves and AppKit sizes the slot to fit — so two provider readouts
/// always both appear.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let store: QuotaStore
    private let settings: SettingsWindowController
    private var cancellables = Set<AnyCancellable>()

    init(store: QuotaStore) {
        self.store = store
        self.settings = SettingsWindowController(store: store)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover.behavior = .transient   // click outside to dismiss

        // Weak capture: the popover's view is retained by this controller, so a
        // strong reference here would form a cycle.
        let openSettings: () -> Void = { [weak self] in
            // The transient popover must close first — while it's up it holds
            // focus and the settings window would open behind it.
            self?.popover.performClose(nil)
            self?.settings.show()
        }
        popover.contentViewController = NSHostingController(
            rootView: QuotaPanel(store: store, onOpenSettings: openSettings)
        )

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
        }

        // Repaint whenever the snapshot changes or the clock ticks.
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)

        render()
    }

    private func render() {
        guard let button = statusItem.button else { return }

        // Everything is drawn into one image (see MenuBarRenderer), so the title
        // stays empty — otherwise AppKit would append text beside the bars.
        button.title = ""
        button.toolTip = tooltip

        let providers = store.snapshot.providers
        guard !providers.isEmpty else {
            // Pre-first-refresh: a plain template symbol, tinted by the system.
            let img = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: "AI Quotas")
            img?.isTemplate = true
            button.image = img
            return
        }

        // An unreachable provider is worth flagging louder than a bar can.
        if store.hasError, store.worstPercent == nil {
            let img = NSImage(systemSymbolName: "exclamationmark.triangle",
                              accessibilityDescription: "AI Quotas — error")
            img?.isTemplate = true
            button.image = img
            return
        }

        let entries = providers.map { p in
            MenuBarRenderer.Entry(
                tag: store.label(for: p.id),
                percent: p.isOK ? p.headline?.usedPercent : nil,
                // The countdown belongs to the same window the bar shows.
                reset: p.isOK ? compactReset(p.headline?.resetsAt, now: store.now) : nil
            )
        }
        let style = MenuBarRenderer.Style(
            barWidth: store.barWidth,
            barHeight: store.barHeight,
            showPercentText: store.showPercentText,
            showReset: store.showReset,
            trailingInset: store.trailingInset
        )
        button.image = MenuBarRenderer.image(for: entries, style: style)
    }

    private var tooltip: String {
        guard !store.snapshot.providers.isEmpty else { return "AI Quotas — loading…" }
        return store.snapshot.providers.map { p -> String in
            if let e = p.error { return "\(p.name): \(e)" }
            let windows = p.windows.map { w in
                let pct = w.usedPercent.map { "\(Int($0.rounded()))%" } ?? "—"
                return "  \(w.label): \(pct)"
            }.joined(separator: "\n")
            return "\(p.name)\n\(windows)"
        }.joined(separator: "\n")
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        // Refresh on open so the panel never shows a stale snapshot.
        Task { await store.refresh() }
        // Anchor to the visible content, not the full button: the trailing inset is
        // blank padding, and using the whole width would offset the popover to the
        // right of the bars the user actually clicked.
        var anchor = button.bounds
        anchor.size.width = max(1, anchor.width - CGFloat(store.trailingInset))
        popover.show(relativeTo: anchor, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
