import AppKit
import SwiftUI

/// Owns a real settings window.
///
/// SwiftUI's `Settings` scene is the usual route, but it's only reachable via
/// private `NSApp` selectors (`showSettingsWindow:` / `showPreferencesWindow:`)
/// whose names differ across macOS versions — and when neither responds, the
/// button silently does nothing. Creating the window directly always works.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let store: QuotaStore

    init(store: QuotaStore) {
        self.store = store
    }

    func show() {
        // Reuse the existing window if it's already open, so repeated clicks just
        // bring it forward instead of stacking duplicates.
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(store: store))
        let win = NSWindow(contentViewController: hosting)
        win.title = "AI Quotas Settings"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.center()

        // Drop our reference on close so the next show() builds a fresh window.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.window = nil }
        }

        window = win
        win.makeKeyAndOrderFront(nil)
        // A menu-bar-only app (LSUIElement) isn't active by default, so without
        // this the window appears behind whatever you were using.
        NSApp.activate(ignoringOtherApps: true)
    }
}
