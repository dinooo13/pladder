import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Resolves virtual key codes against the keyboard layout the user has
/// selected, so a synthesised shortcut lands on the key that really carries the
/// character. `kVK_ANSI_V` is "v" on QWERTY only: on Dvorak that key types "."
/// and Cmd+V would paste nothing.
///
/// Namespace only, never instantiated. The Text Input Sources calls have to run
/// on the main thread, so the entry point is main-actor bound; the translation
/// itself is pure and takes the layout bytes, which is what the tests exercise.
public enum KeyboardLayout {
    /// The key code that types "v" with Command held under the current input
    /// source, or nil when there is no layout to ask — a Chinese or Japanese
    /// input method has no `UCKeyboardLayout` at all, and the caller keeps
    /// whatever it resolved last.
    @MainActor
    public static func commandVKeyCode() -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = layoutData(of: source)
        else { return nil }
        return keyCode(
            producing: "v",
            withCommand: true,
            in: data,
            keyboardType: UInt32(LMGetKbdType())
        )
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
        return layoutData.withUnsafeBytes { raw -> CGKeyCode? in
            guard let base = raw.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            var characters = [UniChar](repeating: 0, count: 8)
            for code in UInt16(0)..<128 {
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
                    &characters
                )
                guard status == noErr, length == 1 else { continue }
                guard let scalar = Unicode.Scalar(characters[0]) else { continue }
                if Character(scalar) == character { return CGKeyCode(code) }
            }
            return nil
        }
    }

    /// The `uchr` table of an input source, or nil when it carries none.
    ///
    /// Main actor like everything else here: Text Input Sources sets itself up
    /// lazily and is not thread-safe, and two threads entering it at once abort
    /// the process inside `islGetInputSourceListWithAdditions`.
    @MainActor
    static func layoutData(of source: TISInputSource) -> Data? {
        // The key imports as a mutable global and cannot be read under strict
        // concurrency; its value is this string and is API-stable, the same
        // workaround `Permissions.swift` uses for `kAXTrustedCheckOptionPrompt`.
        let key = "TISPropertyUnicodeKeyLayoutData" as CFString
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    /// The layout of a named input source, whether or not the user has enabled
    /// it. Test helper: every Mac ships US and Dvorak, so the translation can be
    /// checked against a layout that is not the current one.
    @MainActor
    static func layoutData(inputSourceID: String) -> Data? {
        let criteria = ["TISPropertyInputSourceID": inputSourceID] as CFDictionary
        guard let list = TISCreateInputSourceList(criteria, true)?.takeRetainedValue(),
              let sources = list as? [TISInputSource]
        else { return nil }
        for source in sources {
            if let data = layoutData(of: source) { return data }
        }
        return nil
    }
}
