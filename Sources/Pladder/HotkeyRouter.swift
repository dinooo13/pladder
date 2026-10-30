import Foundation
import Observation
import PladderCore
import PladderSystem

// Both monitors live for the app's life, so switching costs nothing. The decision is
// `HotkeyRouting`; see docs/ARCHITECTURE.md, "Hotkeys".
@MainActor
@Observable
final class HotkeyRouter {
    // Written only when it changed, so a poll with nothing new invalidates no view.
    private var routing: HotkeyRouting
    // `CopySymbolicHotKeys` is main-thread work linear in the shortcut count: read at launch,
    // a permission flip and settings opening, never on a key press.
    private(set) var systemShortcuts: Set<Hotkey> = []

    @ObservationIgnored private let tap: any HotkeyMonitor
    @ObservationIgnored private let carbon: any HotkeyMonitor
    @ObservationIgnored private weak var coordinator: DictationCoordinator?

    init(
        accessibilityTrusted: Bool, hotkey: Hotkey,
        tap: any HotkeyMonitor = GlobalHotkeyMonitor(), carbon: any HotkeyMonitor = CarbonHotkeyMonitor()
    ) {
        routing = HotkeyRouting(accessibilityTrusted: accessibilityTrusted, hotkey: hotkey)
        self.tap = tap
        self.carbon = carbon
    }

    var initialMonitor: any HotkeyMonitor { monitor(for: routing.source) }

    func attach(_ coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    func update(accessibilityTrusted: Bool, secureInputEnabled: Bool) {
        var next = routing
        let change = next.observe(accessibilityTrusted: accessibilityTrusted, secureInputEnabled: secureInputEnabled)
        if next != routing { routing = next }
        guard let change else { return }
        if let coordinator {
            coordinator.update(
                coordinator.settings, standInHotkey: change.standInHotkey, monitor: change.source.map(monitor(for:)))
        }
        refreshSystemShortcuts()
    }

    func hotkeyChanged(to hotkey: Hotkey) -> (any HotkeyMonitor)? {
        guard hotkey != routing.hotkey else { return nil }
        return routing.hotkeyChanged(to: hotkey).map(monitor(for:))
    }

    private func monitor(for source: HotkeySource) -> any HotkeyMonitor {
        switch source {
        case .tap: tap
        case .carbon: carbon
        }
    }

    var standInHotkey: Hotkey? { routing.standInHotkey }
    var usesCarbonForSecureInput: Bool { routing.accessibilityTrusted && routing.source == .carbon }
    var hotkeyNeedsRegularKey: Bool { !routing.accessibilityTrusted }

    // Named as the matching monitor sees it: the tap tells Left from Right, Carbon cannot.
    func displayName(of chord: Hotkey) -> String {
        routing.source == .tap ? chord.displayName : chord.sideAgnosticDisplayName
    }

    func refreshSystemShortcuts() {
        let shortcuts = SystemShortcuts.enabled()
        if shortcuts != systemShortcuts { systemShortcuts = shortcuts }
    }
}
