import AppKit
import ServiceManagement

/// "Open at login", backed by `SMAppService`.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.hotKeys.error("Login item update failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
