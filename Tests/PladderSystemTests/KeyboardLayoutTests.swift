import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import PladderSystem

// Main-actor bound: Text Input Sources is not thread-safe, so every call into
// it — including the test helper that reads a layout by id — belongs on the
// main thread.
@MainActor
@Suite struct KeyboardLayoutTests {
    private static let keyboardType = UInt32(LMGetKbdType())

    @Test func qwertyResolvesV() throws {
        let layout = try #require(KeyboardLayout.layoutData(inputSourceID: "com.apple.keylayout.US"))
        let key = KeyboardLayout.keyCode(
            producing: "v", withCommand: true, in: layout, keyboardType: Self.keyboardType
        )
        #expect(key == 0x09)  // kVK_ANSI_V
    }

    @Test func dvorakResolvesV() throws {
        let layout = try #require(KeyboardLayout.layoutData(inputSourceID: "com.apple.keylayout.Dvorak"))
        let key = KeyboardLayout.keyCode(
            producing: "v", withCommand: true, in: layout, keyboardType: Self.keyboardType
        )
        // Dvorak's "v" sits where QWERTY has the full stop.
        #expect(key == 0x2F)  // kVK_ANSI_Period
    }

    @Test func unknownCharacterIsNil() throws {
        let layout = try #require(KeyboardLayout.layoutData(inputSourceID: "com.apple.keylayout.US"))
        let key = KeyboardLayout.keyCode(
            producing: "ß", withCommand: true, in: layout, keyboardType: Self.keyboardType
        )
        #expect(key == nil)
    }

    @Test func currentLayoutResolvesSomething() {
        // Nil is legitimate under a Chinese or Japanese input method, which
        // carries no `uchr` table; the machine running the tests uses a layout.
        #expect(KeyboardLayout.commandVKeyCode() != nil)
    }

    @Test func resolutionIsCheap() {
        for _ in 0..<20 { _ = KeyboardLayout.commandVKeyCode() }
        var samples: [Double] = []
        for _ in 0..<200 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = KeyboardLayout.commandVKeyCode()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        print("KeyboardLayout.commandVKeyCode median=\(median) ms")
        // Generous: this runs at key-down, not on the release-to-paste path.
        #expect(median < 2)
    }
}
