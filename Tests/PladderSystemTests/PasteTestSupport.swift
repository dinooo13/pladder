import AppKit
import Foundation
import PladderTestSupport
import Synchronization
@testable import PladderSystem

extension ManualClock {
    var pasteClock: PasteClock {
        PasteClock(now: { self.now }, sleep: { try await self.sleep(until: $0) })
    }
}

/// Records every key instead of typing it, stamped with the manual clock.
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

    /// Every later post of `key` throws, as a failed event creation would.
    func refuse(_ key: CGKeyCode) { state.withLock { _ = $0.refusing.insert(key) } }

    func post(_ key: CGKeyCode, flags: CGEventFlags) throws {
        let at = clock.now
        try state.withLock { state in
            guard !state.refusing.contains(key) else { throw Refused() }
            state.posts.append(Post(key: key, flags: flags.rawValue, at: at))
        }
    }
}

/// One `PasteboardOutput` wired to a private named pasteboard, a recording
/// poster, a manual clock and a switchable grant. Never `.general`: the
/// developer dictates with a running Pladder while these run.
final class PasteHarness: Sendable {
    static let keyV: CGKeyCode = 0x09
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    let name = NSPasteboard.Name("de.dinooo13.pladder.tests.\(UUID().uuidString)")
    let clock = ManualClock()
    let poster: RecordingKeyPoster
    let output: PasteboardOutput

    init(submitDelay: Duration = .milliseconds(50), snapshotLimit: Int = ClipboardSnapshot.maximumItemBytes) {
        let poster = RecordingKeyPoster(clock: clock)
        self.poster = poster
        let grant = Grant()
        self.grant = grant
        output = PasteboardOutput(
            submitDelay: submitDelay, pasteboard: name, poster: poster,
            isTrusted: { grant.value }, clock: clock.pasteClock, snapshotLimit: snapshotLimit)
    }

    /// The grant, shared with the output's `isTrusted`.
    final class Grant: Sendable {
        private let state = Mutex(true)
        var value: Bool { state.withLock { $0 } }
        func set(_ value: Bool) { state.withLock { $0 = value } }
    }

    private let grant: Grant
    func setTrusted(_ value: Bool) { grant.set(value) }

    /// A fresh handle on the same named pasteboard; the keeper has its own.
    var pasteboard: NSPasteboard { NSPasteboard(name: name) }

    /// The user copying `text`.
    func userCopies(_ text: String) {
        let pasteboard = pasteboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Plain text on the clipboard. Only for when it is not our promise:
    /// reading that would count as the target app's read.
    var clipboard: String? { pasteboard.string(forType: .string) }

    /// Whether the pasteboard still holds a transcript, by its markers,
    /// without reading the promise.
    var holdsTranscript: Bool {
        pasteboard.pasteboardItems?.first?.types.contains(Self.transient) == true
    }

    /// Lets the pending restore fall due, whenever that is, and waits for it.
    func restoreFallsDue() async {
        let task = await output.keeper.pendingRestore
        clock.advance(by: .seconds(60))
        await task?.value
    }

    /// The target app reading the transcript now.
    func targetReads() async {
        guard let promise = await output.keeper.pendingPromise else { return }
        await output.keeper.transcriptRead(promise, at: clock.now)
    }

    deinit { NSPasteboard(name: name).releaseGlobally() }
}
