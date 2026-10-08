import Foundation

/// One Carbon monitor session's hot keys: the IDs they are registered under
/// and what an event carrying one of them means. Pure value type, so the
/// packing, the filter and the de-duplication are tested without Carbon;
/// `CarbonHotkeyMonitor` owns one per session behind its lock.
///
/// **IDs.** Every hot key carries a 32-bit ID: the session's generation in
/// the high 29 bits, the role's index in the low three, and the cancel key in
/// the last of those eight slots, clear of the roles. One session's hot keys
/// are told apart that way, and an event for an old session's is not found.
/// Generations half a billion starts apart would share IDs, which no run of
/// the app comes near.
///
/// **De-duplication.** Carbon repeats `kEventHotKeyPressed` while the key is
/// held on some configurations, and a release can arrive with nothing
/// pressed, for a key already down when the session registered its hot
/// keys. Each role's events come out strictly alternating, starting with a
/// press.
public struct CarbonHotkeySession: Sendable, Equatable {
    public let generation: UInt64
    /// The roles registered this session, by ID.
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

    /// What a hot key event means, or nil when it means nothing: another
    /// session's hot key, a repeated press, a release with nothing pressed.
    /// Escape is the cancel key only while it is registered, so a press
    /// that lands after it was let go is dropped, and only its press counts.
    /// Carbon never sees the send key, so no release says submit.
    public mutating func event(
        id: UInt32, isPress: Bool, cancelKeyRegistered: Bool
    ) -> HotkeyMonitorEvent.Kind? {
        if id == cancelKeyID {
            return isPress && cancelKeyRegistered ? .escape : nil
        }
        // No generation check of its own: `roles` holds only this session's
        // IDs, and every one of them carries this generation's bits, so
        // finding the ID here is that check.
        guard let role = roles[id] else { return nil }
        if isPress {
            return pressed.insert(role).inserted ? .chord(role, .pressed) : nil
        }
        return pressed.remove(role) != nil ? .chord(role, .released(submit: false)) : nil
    }
}
