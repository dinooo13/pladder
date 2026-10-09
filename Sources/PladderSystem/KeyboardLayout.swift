import Carbon.HIToolbox
import CoreGraphics
import Foundation

// `kVK_ANSI_V` types "v" on QWERTY only; on Dvorak Cmd+V on it would paste nothing.
// Text Input Sources is not thread-safe: two threads in it at once abort the process
// in `islGetInputSourceListWithAdditions`, so reading the current layout is main actor.
public enum KeyboardLayout {
    @MainActor
    public static func commandVKeyCode() -> CGKeyCode? {
        guard let data = currentLayoutData() else { return nil }
        return keyCode(producing: "v", withCommand: true, in: data, keyboardType: currentKeyboardType)
    }

    @MainActor
    static func displayCharacter(for code: UInt16) -> String? {
        guard let data = currentLayoutData() else { return nil }
        return displayCharacter(for: code, in: data, keyboardType: currentKeyboardType)
    }

    static func keyCode(
        producing character: Character,
        withCommand: Bool,
        in layoutData: Data,
        keyboardType: UInt32
    ) -> CGKeyCode? {
        // UCKeyTranslate wants the classic event record's modifier byte: the Carbon mask >> 8.
        let modifiers = withCommand ? UInt32(cmdKey >> 8) : 0
        let wanted = String(character)
        let code = (UInt16(0)..<128).first {
            translate($0, modifiers: modifiers, in: layoutData, keyboardType: keyboardType) == wanted
        }
        return code.map { CGKeyCode($0) }
    }

    static func displayCharacter(for code: UInt16, in layoutData: Data, keyboardType: UInt32) -> String? {
        guard let text = translate(code, modifiers: 0, in: layoutData, keyboardType: keyboardType),
              let scalar = text.unicodeScalars.first,
              !CharacterSet.whitespacesAndNewlines.contains(scalar),
              !CharacterSet.controlCharacters.contains(scalar)
        else { return nil }
        return text.uppercased()
    }

    private static func translate(
        _ code: UInt16, modifiers: UInt32, in layoutData: Data, keyboardType: UInt32
    ) -> String? {
        layoutData.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            return withUnsafeTemporaryAllocation(of: UniChar.self, capacity: 4) { characters -> String? in
                guard let buffer = characters.baseAddress else { return nil }
                var deadKeyState: UInt32 = 0
                var length = 0
                let status = UCKeyTranslate(
                    layout,
                    code,
                    UInt16(kUCKeyActionDisplay),
                    modifiers,
                    keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeyState,
                    characters.count,
                    &length,
                    buffer
                )
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: buffer, count: length)
            }
        }
    }

    @MainActor
    private static var currentKeyboardType: UInt32 { UInt32(LMGetKbdType()) }

    @MainActor
    private static func currentLayoutData() -> Data? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return layoutData(of: source)
    }

    @MainActor
    static func layoutData(of source: TISInputSource) -> Data? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    // For the tests: every Mac ships US and Dvorak, enabled or not.
    @MainActor
    static func layoutData(inputSourceID: String) -> Data? {
        let criteria = [kTISPropertyInputSourceID as String: inputSourceID] as CFDictionary
        guard let list = TISCreateInputSourceList(criteria, true)?.takeRetainedValue(),
              let sources = list as? [TISInputSource]
        else { return nil }
        for source in sources {
            if let data = layoutData(of: source) { return data }
        }
        return nil
    }
}
