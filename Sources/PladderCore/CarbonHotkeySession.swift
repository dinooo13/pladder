import Foundation

// A hot key's ID: the session's generation in the high 29 bits, the role's index in
// the low three, the cancel key in slot 7. An old session's events are not found.
public struct CarbonHotkeySession: Sendable, Equatable {
    public let generation: UInt64
    private let roles: [UInt32: HotkeyRole]
    private var pressed: Set<HotkeyRole> = []

    public init(generation: UInt64, roles: some Sequence<HotkeyRole>) {
        self.generation = generation
        self.roles = Dictionary(
            roles.map { (Self.hotKeyID(generation: generation, role: $0), $0) },
            uniquingKeysWith: { first, _ in first })
    }

    public static func hotKeyID(generation: UInt64, role: HotkeyRole) -> UInt32 {
        let index = UInt32(HotkeyRole.allCases.firstIndex(of: role) ?? 0)
        return (UInt32(truncatingIfNeeded: generation) &<< 3) | index
    }

    public static func cancelKeyID(generation: UInt64) -> UInt32 {
        (UInt32(truncatingIfNeeded: generation) &<< 3) | 7
    }

    public var cancelKeyID: UInt32 { Self.cancelKeyID(generation: generation) }

    // Carbon repeats presses on some configurations and can send a release for a key
    // already down at registration, so each role's events are forced to alternate.
    public mutating func event(
        id: UInt32, isPress: Bool, cancelKeyRegistered: Bool
    ) -> HotkeyMonitorEvent.Kind? {
        if id == cancelKeyID {
            return isPress && cancelKeyRegistered ? .escape : nil
        }
        // No generation check needed: `roles` holds only this session's IDs.
        guard let role = roles[id] else { return nil }
        if isPress {
            return pressed.insert(role).inserted ? .chord(role, .pressed) : nil
        }
        return pressed.remove(role) != nil ? .chord(role, .released(submit: false)) : nil
    }
}
