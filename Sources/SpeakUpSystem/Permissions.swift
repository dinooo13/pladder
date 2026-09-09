import AVFoundation
import AppKit
import ApplicationServices
import Foundation

/// The two permissions SpeakUp needs: Accessibility (global hotkey and synthetic
/// Cmd+V) and Microphone. Namespace only, never instantiated.
public enum Permissions {
    /// True when the app is listed and ticked in Privacy & Security >
    /// Accessibility. Cheap enough to poll from the menu.
    ///
    /// Note this reflects the *bundle* that is running: a bare SwiftPM binary and
    /// the bundled `SpeakUp.app` are two different entries in that list.
    public static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Same check, but macOS shows the "open System Settings" prompt when the app
    /// is not trusted yet. The prompt appears at most once per app per launch of
    /// the settings daemon, so also offer `openAccessibilitySettings()`.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        // The key is `kAXTrustedCheckOptionPrompt`, which C imports as a mutable
        // global and therefore cannot be read under strict concurrency. Its value
        // is this string and is API-stable.
        let options = ["AXTrustedCheckOptionPrompt": true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    public static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    public static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    public static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Shows the system microphone prompt if the user has not decided yet, and
    /// returns the resulting answer.
    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
