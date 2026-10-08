import Foundation

/// Which monitor drives the coordinator.
///
/// The event tap matches any chord, swallows its regular key and carries the
/// send key and the interrupted-press rule, but it needs Accessibility, and
/// while Secure Event Input is on it sees no key-downs, so a chord with a
/// regular key is dead on it. Carbon's `RegisterEventHotKey` needs no
/// permission and secure input does not touch it, but it takes exactly one
/// regular key and no Fn.
public enum HotkeySource: Sendable, Equatable {
    case tap
    case carbon

    /// Without Accessibility only Carbon works. With it the tap, unless
    /// secure input has been on long enough to count (`SustainedCondition`)
    /// and Carbon can register the push-to-talk chord. A chord Carbon cannot
    /// take is modifier-only or has Fn, and secure input leaves those
    /// working on the tap, so they stay there and nothing swaps. The
    /// push-to-talk chord alone decides; the toggle chord follows whichever
    /// monitor is up.
    public static func choose(
        accessibilityTrusted: Bool, secureInputSustained: Bool, hotkey: Hotkey
    ) -> HotkeySource {
        guard accessibilityTrusted else { return .carbon }
        return secureInputSustained && hotkey.canBeRegisteredWithoutAccessibility ? .carbon : .tap
    }
}
