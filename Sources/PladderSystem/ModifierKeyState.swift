import Foundation
import PladderCore

/// Reads which physical modifier keys are down out of an event's modifier
/// flags.
///
/// `NSEvent.ModifierFlags` and `CGEventFlags` share one layout: the generic
/// side-agnostic bits (`NX_SHIFTMASK` and friends) in the upper half, and in
/// the low 16 bits the device-dependent `NX_DEVICE*KEYMASK` bits that say
/// *which* Shift is down. Those low bits are the only way to tell Right Option
/// from Left Option on a key event, which is what a modifier-only push-to-talk
/// key depends on.
///
/// Fn is the exception. Its flag (`NX_SECONDARYFNMASK`) is also set while an
/// arrow, Home, or F key is down, whether or not Fn itself is held, so it is
/// tracked from the Fn key's own `flagsChanged` events instead of read back
/// from every event. That is why this is a small struct rather than a function.
public struct ModifierKeyState: Sendable, Equatable {
    private var fnDown = false

    public init() {}

    /// The modifier keys down according to `flags`, for a key-down or key-up.
    public func held(flags: UInt64) -> Set<UInt16> {
        var held: Set<UInt16> = []
        func read(generic: UInt64, left: (bit: UInt64, key: UInt16), right: (bit: UInt64, key: UInt16)) {
            guard flags & generic != 0 else { return }
            let l = flags & left.bit != 0
            let r = flags & right.bit != 0
            if l { held.insert(left.key) }
            if r { held.insert(right.key) }
            // Synthetic events set only the generic bit. Read that as the left
            // key, the conventional meaning of "Control+Space".
            if !l && !r { held.insert(left.key) }
        }
        read(generic: 0x2_0000, left: (0x2, 0x38), right: (0x4, 0x3C))       // Shift
        read(generic: 0x4_0000, left: (0x1, 0x3B), right: (0x2000, 0x3E))    // Control
        read(generic: 0x8_0000, left: (0x20, 0x3A), right: (0x40, 0x3D))     // Option
        read(generic: 0x10_0000, left: (0x8, 0x37), right: (0x10, 0x36))     // Command
        if fnDown { held.insert(0x3F) }
        return held
    }

    /// The modifier keys down after a `flagsChanged` for `changedKey`.
    public mutating func update(changedKey: UInt16, flags: UInt64) -> Set<UInt16> {
        if changedKey == 0x3F {
            fnDown = flags & 0x80_0000 != 0
        }
        return held(flags: flags)
    }
}
