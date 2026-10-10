import AVFoundation
import AppKit
import ApplicationServices
import Foundation

public enum Permissions {
    // Per bundle: the bare SwiftPM binary and `Pladder.app` are two entries in the list.
    public static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    // macOS shows its prompt at most once per launch of the settings daemon, so the
    // settings also offer `openAccessibilitySettings()`.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        // `kAXTrustedCheckOptionPrompt` imports as a mutable global, unreadable under
        // strict concurrency; its value is this string and is API-stable.
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

    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
