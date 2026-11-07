import CoreFoundation
import Foundation
import PladderCore

// A configuration profile's Custom Settings payload for the app's domain, which macOS keeps
// in the root-owned /Library/Managed Preferences. Only forced values count: one the user
// wrote with `defaults`, or one in /Library/Preferences, is not. See docs/ARCHITECTURE.md,
// "Managed policy".
public struct ManagedPolicySource: Sendable {
    public static let defaultDomain = "de.dinooo13.pladder"

    public let domain: String

    // `swift run` has no bundle identifier, and reads the app's domain all the same.
    public init(domain: String = Bundle.main.bundleIdentifier ?? ManagedPolicySource.defaultDomain) {
        self.domain = domain
    }

    // Synchronized first, so a profile installed or removed while the app runs is seen.
    public func read(knownEngines: [EngineID]) -> (policy: ManagedPolicy, problems: [ManagedPolicy.Problem]) {
        let app = domain as CFString
        CFPreferencesAppSynchronize(app)
        return ManagedPolicy.read({ key in
            let name = key.rawValue as CFString
            guard CFPreferencesAppValueIsForced(name, app) else { return nil }
            return CFPreferencesCopyAppValue(name, app)
        }, knownEngines: knownEngines)
    }
}
