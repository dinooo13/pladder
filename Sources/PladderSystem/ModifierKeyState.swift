import Foundation
import PladderCore

// The low 16 bits of the flags say which side is down; nothing else tells Right Option
// from Left on a key event. Fn's flag is also set while an arrow, Home or F key is
// down, so Fn is tracked from its own `flagsChanged` instead.
public struct ModifierKeyState: Sendable, Equatable {
    private var fnDown = false

    public init() {}

    public func held(flags: UInt64) -> Set<UInt16> {
        var held: Set<UInt16> = []
        func read(generic: UInt64, left: (bit: UInt64, key: UInt16), right: (bit: UInt64, key: UInt16)) {
            guard flags & generic != 0 else { return }
            let l = flags & left.bit != 0
            let r = flags & right.bit != 0
            if l { held.insert(left.key) }
            if r { held.insert(right.key) }
            // Synthetic events set only the generic bit; read it as the left key.
            if !l && !r { held.insert(left.key) }
        }
        read(generic: 0x2_0000, left: (0x2, 0x38), right: (0x4, 0x3C))       // Shift
        read(generic: 0x4_0000, left: (0x1, 0x3B), right: (0x2000, 0x3E))    // Control
        read(generic: 0x8_0000, left: (0x20, 0x3A), right: (0x40, 0x3D))     // Option
        read(generic: 0x10_0000, left: (0x8, 0x37), right: (0x10, 0x36))     // Command
        if fnDown { held.insert(0x3F) }
        return held
    }

    public mutating func update(changedKey: UInt16, flags: UInt64) -> Set<UInt16> {
        if changedKey == 0x3F {
            fnDown = flags & 0x80_0000 != 0
        }
        return held(flags: flags)
    }
}
