import Foundation
import Observation
import PladderCore
import PladderSystem

/// Decides which hotkey monitor drives the coordinator and which chord it
/// listens for.
///
/// Both monitors are kept for the app's life so switching costs nothing. The
/// tap swallows the chord's regular key and matches left and right modifiers
/// exactly, but needs Accessibility; Carbon needs no permission at all and is
/// what a standard account gets. Granting Accessibility upgrades to the tap,
/// revoking it drops back to Carbon, and a sustained Secure Event Input,
/// which stops taps seeing key-downs, hands a chord with a regular key to
/// Carbon until it clears. A modifier-only chord is unaffected by secure
/// input and Carbon cannot register it, so it stays on the tap. The
/// push-to-talk chord alone decides; the toggle chord follows whichever
/// monitor is up.
///
/// Without Accessibility a stored chord Carbon cannot register listens for
/// nothing, so the default stands in for it. The stored chord is never
/// rewritten and returns with the grant.
@MainActor
@Observable
final class HotkeyRouter {
    /// Which of the two the coordinator is currently driven by.
    private(set) var usesTap: Bool
    private(set) var accessibilityTrusted: Bool
    /// The keyboard shortcuts macOS itself handles. Read on explicit
    /// triggers only — launch, a permission flip, the settings window
    /// opening — because `CopySymbolicHotKeys` is main-thread work linear in
    /// the number of shortcuts and the answer changes about as often as
    /// someone visits System Settings. Never on a key press.
    private(set) var systemShortcuts: Set<Hotkey> = []
    /// The stored push-to-talk chord, as the app last reported it.
    private(set) var hotkey: Hotkey

    @ObservationIgnored private let tap = GlobalHotkeyMonitor()
    @ObservationIgnored private let carbon = CarbonHotkeyMonitor()
    /// Only a *sustained* reading counts, so the password field the user
    /// tabs through does not swap the monitor twice in four seconds.
    @ObservationIgnored private var secureInput = SustainedCondition()
    @ObservationIgnored private weak var coordinator: DictationCoordinator?
    /// So the first `update` applies the stand-in even though nothing
    /// flipped; `usesTap` already matches the grant at that point.
    @ObservationIgnored private var didApplyStandIn = false

    init(accessibilityTrusted: Bool, hotkey: Hotkey) {
        self.accessibilityTrusted = accessibilityTrusted
        self.hotkey = hotkey
        usesTap = accessibilityTrusted
    }

    /// The monitor the coordinator starts with.
    var initialMonitor: any HotkeyMonitor { usesTap ? tap : carbon }

    func attach(_ coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    /// Called after every permission poll.
    func update(accessibilityTrusted trusted: Bool, secureInputEnabled: Bool) {
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
        let sustained = secureInput.observe(secureInputEnabled)
        let wantsTap = HotkeySource.choose(
            accessibilityTrusted: trusted, secureInputSustained: sustained, hotkey: hotkey) == .tap
        let flipped = wantsTap != usesTap
        if flipped {
            usesTap = wantsTap
            // A recording in progress is dropped by the coordinator, since the
            // old monitor's release can no longer arrive.
            coordinator?.replaceHotkeyMonitor(wantsTap ? tap : carbon)
        }
        // After the swap: the new monitor is started with the old stand-in and
        // then, if it changed, once more with the new one. The other order
        // would make the Carbon monitor log a failure for a modifier-only
        // chord on the way to being replaced by the tap.
        if flipped || !didApplyStandIn {
            didApplyStandIn = true
            applyStandIn()
            refreshSystemShortcuts()
        }
    }

    /// A chord with a regular key no longer needs a stand-in, and a
    /// modifier-only one does.
    func hotkeyChanged(to hotkey: Hotkey) {
        guard hotkey != self.hotkey else { return }
        self.hotkey = hotkey
        applyStandIn()
    }

    /// The default chord, standing in for a stored chord Carbon cannot
    /// register while Accessibility is missing.
    var standInHotkey: Hotkey? {
        accessibilityTrusted ? nil : hotkey.standInWithoutAccessibility
    }

    /// True while a working Accessibility grant is being ignored because
    /// Secure Event Input has the tap deaf and Carbon is standing in.
    var usesCarbonForSecureInput: Bool { accessibilityTrusted && !usesTap }

    /// Without Accessibility the chord has to contain a regular key, so the
    /// recorder refuses modifier-only chords and settings says why.
    var hotkeyNeedsRegularKey: Bool { !accessibilityTrusted }

    /// A chord named the way the monitor that matches it sees the keys: the
    /// tap tells Left from Right, Carbon's mask cannot.
    func displayName(of chord: Hotkey) -> String {
        usesTap ? chord.displayName : chord.sideAgnosticDisplayName
    }

    /// Re-reads the shortcuts macOS owns, which feed the warnings shown in
    /// the settings window.
    func refreshSystemShortcuts() {
        let shortcuts = SystemShortcuts.enabled()
        if shortcuts != systemShortcuts { systemShortcuts = shortcuts }
    }

    private func applyStandIn() {
        coordinator?.hotkeyOverride = standInHotkey
    }
}
