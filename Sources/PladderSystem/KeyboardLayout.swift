import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Resolves virtual key codes against the keyboard layout the user has
/// selected, so a synthesised shortcut lands on the key that really carries the
/// character, and a key is named after what it types. `kVK_ANSI_V` is "v" on
/// QWERTY only: on Dvorak that key types "." and Cmd+V would paste nothing.
///
/// Namespace only, never instantiated. Every Text Input Sources call is main
/// actor bound: TIS sets itself up lazily and is not thread-safe, and two
/// threads entering it at once abort the process inside
/// `islGetInputSourceListWithAdditions`. So the entry points that read the
/// current layout are `@MainActor`; the translation itself is pure and takes
/// the layout bytes, which is what the tests exercise.
public enum KeyboardLayout {
    /// The key code that types "v" with Command held under the current input
    /// source, or nil when there is no layout to ask — a Chinese or Japanese
    /// input method has no `UCKeyboardLayout` at all, and the caller keeps
    /// whatever it resolved last.
    @MainActor
    public static func commandVKeyCode() -> CGKeyCode? {
        guard let data = currentLayoutData() else { return nil }
        return keyCode(producing: "v", withCommand: true, in: data, keyboardType: currentKeyboardType)
    }

    /// What `code` types, unmodified, under the current input source,
    /// upper-cased for display; nil for a key that types nothing visible and
    /// when there is no layout to ask. `KeyNames` uses it for every key
    /// without a fixed name.
    @MainActor
    static func displayCharacter(for code: UInt16) -> String? {
        guard let data = currentLayoutData() else { return nil }
        return displayCharacter(for: code, in: data, keyboardType: currentKeyboardType)
    }

    /// The first key code in 0..<128 whose output under `withCommand` is exactly
    /// `character`. Pure, so the tests can run it against layouts other than the
    /// one the machine happens to be set to.
    static func keyCode(
        producing character: Character,
        withCommand: Bool,
        in layoutData: Data,
        keyboardType: UInt32
    ) -> CGKeyCode? {
        // UCKeyTranslate wants the modifier byte of the classic event record,
        // i.e. the Carbon mask shifted down by 8.
        let modifiers = withCommand ? UInt32(cmdKey >> 8) : 0
        let wanted = String(character)
        let code = (UInt16(0)..<128).first {
            translate($0, modifiers: modifiers, in: layoutData, keyboardType: keyboardType) == wanted
        }
        return code.map { CGKeyCode($0) }
    }

    /// `displayCharacter(for:)` against given layout bytes. Pure.
    static func displayCharacter(for code: UInt16, in layoutData: Data, keyboardType: UInt32) -> String? {
        guard let text = translate(code, modifiers: 0, in: layoutData, keyboardType: keyboardType),
              let scalar = text.unicodeScalars.first,
              !CharacterSet.whitespacesAndNewlines.contains(scalar),
              !CharacterSet.controlCharacters.contains(scalar)
        else { return nil }
        return text.uppercased()
    }

    /// What one key types under `modifiers` (the classic event record's
    /// byte), dead keys left out; nil when it types nothing.
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

    /// The `uchr` table of an input source, or nil when it carries none.
    @MainActor
    static func layoutData(of source: TISInputSource) -> Data? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    /// The layout of a named input source, whether or not the user has enabled
    /// it. Test helper: every Mac ships US and Dvorak, so the translation can be
    /// checked against a layout that is not the current one.
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
