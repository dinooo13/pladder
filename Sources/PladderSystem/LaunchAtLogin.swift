import Foundation
import ServiceManagement

/// Login item registration for the app bundle itself.
///
/// `SMAppService.mainApp` only works from a signed, bundled app; running the raw
/// SwiftPM binary throws. The settings UI surfaces the thrown error instead of
/// silently showing a toggle that does nothing.
public struct LaunchAtLogin {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the app as a login item.
    ///
    /// If the user disabled the item in System Settings > General > Login Items,
    /// the status stays `.requiresApproval` and registering again is a no-op from
    /// their point of view.
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
