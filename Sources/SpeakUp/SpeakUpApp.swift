import AppKit
import SwiftUI
import SpeakUpCore

import SpeakUpSystem

@main
struct SpeakUpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        // Deferred to the first run-loop turn so the app has finished launching
        // before we prompt for Accessibility.
        Task { @MainActor in model.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// `LSUIElement` in Info.plist already hides the Dock icon; setting the policy
/// here too keeps `swift run` (no bundle, no Info.plist) behaving the same.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct MenuContent: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.statusLine)

        if model.canRetryEngine {
            Button("Retry Model Download") { model.coordinator.reloadEngine() }
        }

        if let last = model.lastTranscriptSummary {
            Divider()
            Button("Last: \(last)") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.coordinator.lastTranscript?.text ?? "", forType: .string)
            }
        }

        Divider()

        Button("Settings…") { openSettings() }
            .keyboardShortcut(",", modifiers: .command)

        if model.needsAnyPermission {
            Divider()
            if model.needsAccessibility {
                Button("Grant Accessibility…") { model.grantAccessibility() }
            }
            if model.needsMicrophone {
                Button("Grant Microphone…") { model.grantMicrophone() }
            }
        }

        Divider()

        Button("Quit SpeakUp") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
