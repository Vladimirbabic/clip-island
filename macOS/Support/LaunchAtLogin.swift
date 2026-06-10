import AppKit
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` (macOS 13+). `setEnabled` throws
/// so the UI can surface registration failures (e.g. unsigned dev builds)
/// instead of silently reverting the toggle, and `status` exposes the
/// requires-approval state so the UI can deep-link to Login Items settings.
enum LaunchAtLogin {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    static var requiresApproval: Bool {
        status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Opens System Settings → General → Login Items, where the user can
    /// approve the app when registration is pending approval.
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
