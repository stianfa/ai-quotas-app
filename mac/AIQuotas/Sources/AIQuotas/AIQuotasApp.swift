import SwiftUI

@main
struct AIQuotasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Everything visible is AppKit-owned: the menu bar item is an NSStatusItem
        // and settings is a plain NSWindow (see StatusItemController and
        // SettingsWindowController for why SwiftUI's equivalents didn't hold up).
        // This scene exists only because `App` requires one; it stays empty.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: QuotaStore?
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = QuotaStore()
        self.store = store
        statusController = StatusItemController(store: store)

        // Reconcile the login item with the saved preference on every launch.
        // The Settings toggle only fires on change, so after a rebuild the
        // registration would otherwise keep pointing at the replaced binary's
        // code identity with nothing to correct it.
        if UserDefaults.standard.bool(forKey: "launchAtLogin") {
            LoginItem.reregister()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: QuotaStore
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some View {
        Form {
            Section("Menu bar") {
                TextField("Claude label", text: $store.labelClaude,
                          prompt: Text("hidden"))
                TextField("Codex label", text: $store.labelCodex,
                          prompt: Text("hidden"))

                Text("Leave a label empty to show just its bar.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                // The current value lives in the slider's own label, so it reads as
                // part of the control rather than occupying a separate row.
                Slider(value: $store.barWidth, in: 16...240, step: 2) {
                    Text("Bar width — \(Int(store.barWidth)) pt")
                        .monospacedDigit()
                }

                // 22pt is the menu bar's height; beyond that macOS clips the image.
                Slider(value: $store.barHeight, in: 3...22, step: 1) {
                    Text("Bar height — \(Int(store.barHeight)) pt")
                        .monospacedDigit()
                }

                Toggle("Show percentages", isOn: $store.showPercentText)
                Toggle("Show time until reset", isOn: $store.showReset)

                Slider(value: $store.trailingInset, in: 0...QuotaStore.maxTrailingInset, step: 10) {
                    Text("Nudge left — \(Int(store.trailingInset)) pt")
                        .monospacedDigit()
                }
                Text("Adds blank space on the right to shift the readout leftward. macOS gives no way to position a menu bar item directly, so this is the workaround.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Refresh every", selection: $store.refreshMinutes) {
                    Text("1 minute").tag(1)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                }
                .pickerStyle(.menu)

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        LoginItem.set(enabled: enabled)
                    }

                Text("Each refresh checks your limits with Anthropic and OpenAI through your existing CLI sessions. AI Quotas has no telemetry or cloud service.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}
