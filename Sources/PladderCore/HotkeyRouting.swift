import Foundation

// See docs/ARCHITECTURE.md, "Hotkeys".
public struct HotkeyRouting: Sendable, Equatable {
    // Applied in one coordinator update, so the new monitor never starts with the old stand-in.
    public struct Change: Sendable, Equatable {
        // nil: the monitor stays.
        public var source: HotkeySource?
        public var standInHotkey: Hotkey?

        public init(source: HotkeySource?, standInHotkey: Hotkey?) {
            self.source = source
            self.standInHotkey = standInHotkey
        }
    }

    public private(set) var accessibilityTrusted: Bool
    public private(set) var hotkey: Hotkey
    public private(set) var source: HotkeySource
    private var secureInput: SustainedCondition
    // A chord changed between polls decides with the last poll's reading.
    private var secureInputSustained = false
    // The first observation applies the stand-in even though nothing flipped.
    private var hasObserved = false

    public init(accessibilityTrusted: Bool, hotkey: Hotkey, secureInput: SustainedCondition = SustainedCondition()) {
        self.accessibilityTrusted = accessibilityTrusted
        self.hotkey = hotkey
        self.secureInput = secureInput
        source = HotkeySource.choose(
            accessibilityTrusted: accessibilityTrusted, secureInputSustained: false, hotkey: hotkey)
    }

    public var standInHotkey: Hotkey? {
        accessibilityTrusted ? nil : hotkey.standInWithoutAccessibility
    }

    public mutating func observe(
        accessibilityTrusted trusted: Bool, secureInputEnabled: Bool,
        at instant: ContinuousClock.Instant = .now
    ) -> Change? {
        let standIn = standInHotkey
        accessibilityTrusted = trusted
        secureInputSustained = secureInput.observe(secureInputEnabled, at: instant)
        let flipped = choose()
        guard flipped != nil || standInHotkey != standIn || !hasObserved else { return nil }
        hasObserved = true
        return Change(source: flipped, standInHotkey: standInHotkey)
    }

    // The caller hands the coordinator the new chord, `standInHotkey` and this source together.
    public mutating func hotkeyChanged(to hotkey: Hotkey) -> HotkeySource? {
        guard hotkey != self.hotkey else { return nil }
        self.hotkey = hotkey
        return choose()
    }

    private mutating func choose() -> HotkeySource? {
        let wanted = HotkeySource.choose(
            accessibilityTrusted: accessibilityTrusted, secureInputSustained: secureInputSustained, hotkey: hotkey)
        guard wanted != source else { return nil }
        source = wanted
        return wanted
    }
}
