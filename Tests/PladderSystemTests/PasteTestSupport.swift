import AppKit
import Foundation
import PladderTestSupport
import Synchronization
import Testing
@testable import PladderSystem

/// Every test that touches a real pasteboard runs here, one at a time. Each
/// pasteboard call is a synchronous XPC round trip to pboard, and dozens at once
/// wedged pboard on the CI runner: every test thread waited for a reply forever.
@Suite(.serialized, .timeLimit(.minutes(1))) enum PasteboardTests {}

extension ManualClock {
    var pasteClock: PasteClock {
        PasteClock(now: { self.now }, sleep: { try await self.sleep(until: $0) })
    }
}

final class RecordingKeyPoster: KeyPoster {
    struct Post: Equatable {
        let key: CGKeyCode
        let flags: UInt64
        let at: ContinuousClock.Instant
    }

    struct Refused: Error {}

    private let clock: ManualClock
    private let state = Mutex<(posts: [Post], refusing: Set<CGKeyCode>)>(([], []))

    init(clock: ManualClock) { self.clock = clock }

    var posts: [Post] { state.withLock { $0.posts } }
    var keys: [CGKeyCode] { posts.map(\.key) }

    func refuse(_ key: CGKeyCode) { state.withLock { _ = $0.refusing.insert(key) } }

    func post(_ key: CGKeyCode, flags: CGEventFlags) throws {
        let at = clock.now
        try state.withLock { state in
            guard !state.refusing.contains(key) else { throw Refused() }
            state.posts.append(Post(key: key, flags: flags.rawValue, at: at))
        }
    }
}

// Never `.general`: the developer dictates with a running Pladder while these run.
final class PasteHarness: Sendable {
    static let keyV: CGKeyCode = 0x09
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    let name = NSPasteboard.Name("de.dinooo13.pladder.tests.\(UUID().uuidString)")
    let clock = ManualClock()
    let poster: RecordingKeyPoster
    let output: PasteboardOutput

    init(
        clipboard: String? = nil, submitDelay: Duration = .milliseconds(50),
        snapshotLimit: Int = ClipboardSnapshot.maximumItemBytes
    ) {
        let poster = RecordingKeyPoster(clock: clock)
        self.poster = poster
        let grant = Grant()
        self.grant = grant
        output = PasteboardOutput(
            submitDelay: submitDelay, pasteboard: name, poster: poster,
            isTrusted: { grant.value }, clock: clock.pasteClock, snapshotLimit: snapshotLimit)
        if let clipboard { userCopies(clipboard) }
    }

    final class Grant: Sendable {
        private let state = Mutex(true)
        var value: Bool { state.withLock { $0 } }
        func set(_ value: Bool) { state.withLock { $0 = value } }
    }

    private let grant: Grant
    func setTrusted(_ value: Bool) { grant.set(value) }

    var pasteboard: NSPasteboard { NSPasteboard(name: name) }

    func userCopies(_ text: String) {
        let pasteboard = pasteboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // Only when it is not our promise: reading that would count as the target app's read.
    var clipboard: String? { pasteboard.string(forType: .string) }

    var holdsTranscript: Bool {
        pasteboard.pasteboardItems?.first?.types.contains(Self.transient) == true
    }

    func restoreFallsDue() async {
        let task = await output.keeper.pendingRestore
        clock.advance(by: .seconds(60))
        await task?.value
    }

    func targetReads() async {
        guard let promise = await output.keeper.pendingPromise else { return }
        await output.keeper.transcriptRead(promise, at: clock.now)
    }

    deinit { NSPasteboard(name: name).releaseGlobally() }
}
