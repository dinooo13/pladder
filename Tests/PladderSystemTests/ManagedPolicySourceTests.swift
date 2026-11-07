import CoreFoundation
import Foundation
import PladderCore
import Testing
@testable import PladderSystem

// A domain of its own, never the app's: that one holds the running copy's Sparkle state.
@Suite struct ManagedPolicySourceTests {
    @Test func aValueTheUserWroteIsIgnored() {
        let domain = "de.dinooo13.pladder.tests.\(UUID().uuidString)"
        let app = domain as CFString
        defer {
            for key in ManagedPolicy.Key.allCases { CFPreferencesSetAppValue(key.rawValue as CFString, nil, app) }
            CFPreferencesAppSynchronize(app)
            let plist = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Preferences/\(domain).plist")
            try? FileManager.default.removeItem(at: plist)
        }
        CFPreferencesSetAppValue(ManagedPolicy.Key.clipboardMode.rawValue as CFString, kCFBooleanTrue, app)
        CFPreferencesSetAppValue(
            ManagedPolicy.Key.allowedEngines.rawValue as CFString, ["parakeet-tdt-v3-incremental"] as CFArray, app)
        CFPreferencesAppSynchronize(app)
        #expect(CFPreferencesCopyAppValue(ManagedPolicy.Key.clipboardMode.rawValue as CFString, app) != nil)

        let (policy, problems) = ManagedPolicySource(domain: domain)
            .read(knownEngines: [EngineID("parakeet-tdt-v3-incremental")])

        #expect(policy == .none)
        #expect(problems.isEmpty)
    }
}
