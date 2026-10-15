import Foundation

// The tap needs Accessibility and sees no key-downs under Secure Event Input.
// Carbon needs neither, but takes exactly one regular key and no Fn.
public enum HotkeySource: Sendable, Equatable {
    case tap
    case carbon

    // A chord Carbon cannot take still works on the tap under secure input.
    public static func choose(
        accessibilityTrusted: Bool, secureInputSustained: Bool, hotkey: Hotkey
    ) -> HotkeySource {
        guard accessibilityTrusted else { return .carbon }
        return secureInputSustained && hotkey.canBeRegisteredWithoutAccessibility ? .carbon : .tap
    }
}
