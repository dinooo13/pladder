import Foundation
import ServiceManagement

// `SMAppService.mainApp` works only from a signed bundle; the bare binary throws,
// and the settings show the error.
public struct LaunchAtLogin {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    // Disabled by the user in Login Items, the status stays `.requiresApproval`.
    public static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }
}
