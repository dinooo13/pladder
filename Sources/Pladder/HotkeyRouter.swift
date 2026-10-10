import Foundation
import Observation
import PladderCore
import PladderSystem

// Both monitors live for the app's life, so switching costs nothing. The rule is
// `HotkeySource.choose`; see docs/ARCHITECTURE.md, "Hotkeys".
@MainActor
@Observable
final class HotkeyRouter {
    private(set) var usesTap: Bool
    private(set) var accessibilityTrusted: Bool
    // `CopySymbolicHotKeys` is main-thread work linear in the shortcut count: read at launch,
    // a permission flip and settings opening, never on a key press.
    private(set) var systemShortcuts: Set<Hotkey> = []
    private(set) var hotkey: Hotkey

    @ObservationIgnored private let tap = GlobalHotkeyMonitor()
    @ObservationIgnored private let carbon = CarbonHotkeyMonitor()
    @ObservationIgnored private var secureInput = SustainedCondition()
    @ObservationIgnored private var secureInputSustained = false
    @ObservationIgnored private weak var coordinator: DictationCoordinator?
    // So the first `update` applies the stand-in even though nothing flipped.
    @ObservationIgnored private var didApplyStandIn = false

    init(accessibilityTrusted: Bool, hotkey: Hotkey) {
        self.accessibilityTrusted = accessibilityTrusted
        self.hotkey = hotkey
        usesTap = accessibilityTrusted
    }

    var initialMonitor: any HotkeyMonitor { usesTap ? tap : carbon }

    func attach(_ coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    func update(accessibilityTrusted trusted: Bool, secureInputEnabled: Bool) {
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
        secureInputSustained = secureInput.observe(secureInputEnabled)
        let flipped = chooseMonitor()
        if let flipped {
            coordinator?.replaceHotkeyMonitor(flipped)
        }
        // After the swap: the other order would make the Carbon monitor log a failure for a
        // modifier-only chord on its way to being replaced by the tap.
        if flipped != nil || !didApplyStandIn {
            didApplyStandIn = true
            applyStandIn()
            refreshSystemShortcuts()
        }
    }

    func hotkeyChanged(to hotkey: Hotkey) -> (any HotkeyMonitor)? {
        guard hotkey != self.hotkey else { return nil }
        self.hotkey = hotkey
        return chooseMonitor()
    }

    private func chooseMonitor() -> (any HotkeyMonitor)? {
        let wantsTap = HotkeySource.choose(
            accessibilityTrusted: accessibilityTrusted, secureInputSustained: secureInputSustained,
            hotkey: hotkey) == .tap
        guard wantsTap != usesTap else { return nil }
        usesTap = wantsTap
        return wantsTap ? tap : carbon
    }

    var standInHotkey: Hotkey? {
        accessibilityTrusted ? nil : hotkey.standInWithoutAccessibility
    }

    var usesCarbonForSecureInput: Bool { accessibilityTrusted && !usesTap }
    var hotkeyNeedsRegularKey: Bool { !accessibilityTrusted }

    // Named as the matching monitor sees it: the tap tells Left from Right, Carbon cannot.
    func displayName(of chord: Hotkey) -> String {
        usesTap ? chord.displayName : chord.sideAgnosticDisplayName
    }

    func refreshSystemShortcuts() {
        let shortcuts = SystemShortcuts.enabled()
        if shortcuts != systemShortcuts { systemShortcuts = shortcuts }
    }

    private func applyStandIn() {
        coordinator?.standInHotkey = standInHotkey
    }
}
