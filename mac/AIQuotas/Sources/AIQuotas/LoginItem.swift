import Foundation
import ServiceManagement

/// Registers the app as a login item so quotas are in the menu bar after a restart.
enum LoginItem {
    static func set(enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            Diagnostics.log("login item update failed — \(error.localizedDescription)")
        }
    }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Re-asserts registration for the *current* bundle.
    ///
    /// The stored record identifies the app by code hash, which changes on every
    /// rebuild. Registering while already `.enabled` is a no-op, so the stale
    /// entry has to be dropped first for the new identity to take.
    static func reregister() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
            }
            try svc.register()
        } catch {
            Diagnostics.log("login item re-registration failed — \(error.localizedDescription)")
        }
    }
}
