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

    private var contentImage: NSImage?
    private var contentLeadingInset: CGFloat = 0
    private var appliedPadding: CGFloat = 0
    private var measuredLeftEdge: CGFloat?
    private var measuredScreen: NSRect?
    private var rightEdge: CGFloat = 0

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

        // AppKit can reposition the status item when adjacent items change width.
        // Coalesce move/resize pairs and measure after AppKit settles the layout.
        let notifications = NotificationCenter.default
        let windowChanges = [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                             NSWindow.didChangeScreenNotification]
        Publishers.MergeMany(windowChanges.map { notifications.publisher(for: $0) })
        .filter { [weak self] note in
            guard let window = note.object as? NSWindow else { return false }
            return window === self?.statusItem.button?.window
        }
        .merge(with: notifications.publisher(for: NSApplication.didChangeScreenParametersNotification))
        .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
        .sink { [weak self] _ in self?.updatePadding() }
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
            display(img, leadingInset: 0)
            return
        }

        // An unreachable provider is worth flagging louder than a bar can.
        if store.hasError, store.worstPercent == nil {
            let img = NSImage(systemSymbolName: "exclamationmark.triangle",
                              accessibilityDescription: "AI Quotas — error")
            img?.isTemplate = true
            display(img, leadingInset: 0)
            return
        }

        let entries = providers.map { p in
            let windows = p.isOK ? barWindows(for: p) : []
            let main = windows.first
            return MenuBarRenderer.Entry(
                tag: store.label(for: p.id),
                percent: main?.usedPercent,
                // The countdown belongs to the window the solid fill shows.
                reset: compactReset(main?.resetsAt, now: store.now),
                background: windows.dropFirst().first?.usedPercent
            )
        }
        let style = MenuBarRenderer.Style(
            barWidth: store.barWidth,
            barHeight: store.barHeight,
            showPercentText: store.showPercentText,
            showReset: store.showReset
        )
        display(MenuBarRenderer.image(for: entries, style: style),
                leadingInset: MenuBarRenderer.leadingInset)
    }

    private func display(_ image: NSImage?, leadingInset: CGFloat) {
        contentImage = image
        contentLeadingInset = leadingInset
        updatePadding(contentChanged: true)
    }

    private func updatePadding(contentChanged: Bool = false) {
        guard let button = statusItem.button, let image = contentImage else { return }
        let padding = store.centerOnScreen
            ? centeredPadding(for: button, imageWidth: image.size.width)
            : (contentLeadingInset == 0 ? 0 : max(0, store.trailingInset))
        guard contentChanged || padding != appliedPadding else { return }
        appliedPadding = padding
        guard padding > 0 else {
            button.image = image
            return
        }
        let size = NSSize(width: image.size.width + padding, height: image.size.height)
        let padded = NSImage(size: size, flipped: false) { _ in
            image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        padded.isTemplate = image.isTemplate
        button.image = padded
    }

    private func centeredPadding(for button: NSStatusBarButton, imageWidth: CGFloat) -> CGFloat {
        guard let window = button.window, let screen = window.screen else { return 0 }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard window.frame.height > 0, frame.width > 0, screen.frame.intersects(frame) else {
            measuredLeftEdge = nil
            return 0
        }

        let visibleWidth = imageWidth - contentLeadingInset
        let target = max(screen.frame.midX,
                         (screen.auxiliaryTopRightArea?.minX ?? screen.frame.minX) + visibleWidth / 2)
        // Resizing first grows the local button to the right. The menu bar host
        // moves its window left asynchronously. Sampling that transient right
        // edge feeds our own padding back into the next measurement.
        if measuredLeftEdge != frame.minX || measuredScreen != screen.frame {
            let margin = max(0, min(12, (frame.width - (button.image?.size.width ?? frame.width)) / 2))
            rightEdge = min(frame.maxX, screen.frame.maxX) - margin
            measuredLeftEdge = frame.minX
            measuredScreen = screen.frame
        }
        return max(0, (rightEdge - visibleWidth / 2 - target).rounded())
    }

    /// The windows a provider shows in the menu bar: the first as the solid fill,
    /// an optional second as the faint fill behind it. Claude shows its 5-hour
    /// window inside its 7-day one; overage stays in the panel, because it tracks
    /// spend beyond the plan and would otherwise take over the bar whenever it was
    /// highest.
    private func barWindows(for p: ProviderResult) -> [QuotaWindow] {
        if p.id == "claude" {
            let shared = ["five_hour", "seven_day"].compactMap { id in
                p.windows.first { $0.id == id && $0.usedPercent != nil }
            }
            if !shared.isEmpty { return shared }
        }
        return p.headline.map { [$0] } ?? []
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
        anchor.size.width = max(1, anchor.width - appliedPadding)
        popover.show(relativeTo: anchor, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
