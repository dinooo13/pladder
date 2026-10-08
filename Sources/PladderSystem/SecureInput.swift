import Carbon.HIToolbox

/// Whether some process has Secure Event Input turned on.
///
/// macOS turns it on for password fields, for Terminal's Secure Keyboard Entry
/// and, occasionally, for a login window that never cleaned up after itself.
/// While it is on, a session event tap stops receiving `keyDown` and `keyUp`;
/// `flagsChanged` keeps flowing. So a modifier-only chord such as Right
/// Command goes on working, and any chord with a regular key, the default
/// Option+Space included, silently stops — which is why `AppModel` polls this
/// alongside the Accessibility grant and, once it is sustained, falls back to
/// the Carbon monitor, which is not a tap and is unaffected (`HotkeySource`).
public enum SecureInput {
    public static var isEnabled: Bool { IsSecureEventInputEnabled() }
}
