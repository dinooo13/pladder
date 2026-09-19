import Foundation
import Testing
@testable import PladderCore

/// A stand-in for the audio system. Records every call so the ordering rules
/// can be asserted, and lets a test move the default device or make a set
/// throw the way a disappearing USB interface would.
private final class FakeMuteControl: OutputMuteControl, @unchecked Sendable {
    struct SetCall: Equatable {
        var muted: Bool
        var device: UInt32
    }

    private let lock = NSLock()
    private var _defaultDevice: UInt32?
    /// Devices that have a mute control, and whether it is currently on.
    private var _muteStates: [UInt32: Bool]
    private var _setCalls: [SetCall] = []
    private var _throwOnSet = false

    init(defaultDevice: UInt32? = 1, muteStates: [UInt32: Bool] = [1: false]) {
        _defaultDevice = defaultDevice
        _muteStates = muteStates
    }

    var setCalls: [SetCall] { lock.withLock { _setCalls } }
    func state(of device: UInt32) -> Bool? { lock.withLock { _muteStates[device] } }
    func setDefaultDevice(_ device: UInt32?) { lock.withLock { _defaultDevice = device } }
    func setThrowOnSet(_ value: Bool) { lock.withLock { _throwOnSet = value } }

    struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

    func defaultOutputDevice() -> UInt32? { lock.withLock { _defaultDevice } }

    func isMuted(_ device: UInt32) -> Bool? { lock.withLock { _muteStates[device] } }

    func setMuted(_ muted: Bool, on device: UInt32) throws {
        try lock.withLock {
            _setCalls.append(SetCall(muted: muted, device: device))
            if _throwOnSet { throw Boom() }
            _muteStates[device] = muted
        }
    }
}

/// Short enough that the tests stay well under a second, long enough that a
/// "before the delay" call really lands before it.
private let testDelay = Duration.milliseconds(10)

private func makeController(
    _ control: FakeMuteControl,
    log: @escaping @Sendable (String) -> Void = { _ in }
) -> OutputMuteController {
    OutputMuteController(control: control, delay: testDelay, log: log)
}

/// Yields until the controller has taken the arm, so a `recordingStarted()`
/// that is deliberately not awaited is known to have reached the actor before
/// the test ends the session.
private func waitForGeneration(_ muter: OutputMuteController, _ target: Int) async {
    while await muter.armedGeneration < target { await Task.yield() }
}

/// Waits long enough for a pending arm to have fired.
private func pastTheDelay() async {
    try? await Task.sleep(for: testDelay * 4)
}

@Suite struct OutputMuteControllerTests {
    @Test func tapAndReleaseBeforeTheDelayNeverMutes() async {
        let control = FakeMuteControl()
        let muter = makeController(control)

        let started = Task { await muter.recordingStarted() }
        await waitForGeneration(muter, 1)
        await muter.recordingEnded()
        await started.value
        await pastTheDelay()

        #expect(control.setCalls.isEmpty)
        #expect(control.state(of: 1) == false)
    }

    @Test func muteLandsAfterTheDelayAndIsRestoredOnEnd() async {
        let control = FakeMuteControl()
        let muter = makeController(control)

        await muter.recordingStarted()
        #expect(control.state(of: 1) == true)

        await muter.recordingEnded()
        #expect(control.state(of: 1) == false)
        #expect(control.setCalls == [.init(muted: true, device: 1), .init(muted: false, device: 1)])
    }

    @Test func aDeviceTheUserMutedIsLeftMuted() async {
        let control = FakeMuteControl(muteStates: [1: true])
        let muter = makeController(control)

        await muter.recordingStarted()
        await muter.recordingEnded()

        #expect(control.setCalls.isEmpty)
        #expect(control.state(of: 1) == true)
    }

    @Test func theDefaultDeviceChangingMidRecordingStillUnmutesTheOriginal() async {
        let control = FakeMuteControl(muteStates: [1: false, 2: false])
        let muter = makeController(control)

        await muter.recordingStarted()
        #expect(control.state(of: 1) == true)
        // The user pulls the headphones out halfway through.
        control.setDefaultDevice(2)
        await muter.recordingEnded()

        #expect(control.state(of: 1) == false)
        #expect(control.state(of: 2) == false)
        #expect(control.setCalls == [.init(muted: true, device: 1), .init(muted: false, device: 1)])
    }

    @Test func aDeviceWithoutAMuteControlIsSkipped() async {
        // No entry in `muteStates` means `isMuted` answers nil.
        let control = FakeMuteControl(defaultDevice: 7, muteStates: [:])
        let recorder = LineRecorder()
        let muter = makeController(control) { recorder.append($0) }

        await muter.recordingStarted()
        await muter.recordingEnded()

        #expect(control.setCalls.isEmpty)
        #expect(recorder.lines.contains { $0.contains("no mute control") })
    }

    @Test func noDefaultDeviceIsSkipped() async {
        let control = FakeMuteControl(defaultDevice: nil)
        let recorder = LineRecorder()
        let muter = makeController(control) { recorder.append($0) }

        await muter.recordingStarted()
        await muter.recordingEnded()

        #expect(control.setCalls.isEmpty)
        #expect(recorder.lines.contains { $0.contains("no default output device") })
    }

    /// started → ended → started, all inside the delay: the last session wins
    /// and the device ends up muted, not unmuted by the first session's end.
    @Test func aRestartInsideTheDelayStillEndsUpMuted() async {
        let control = FakeMuteControl()
        let muter = makeController(control)

        let first = Task { await muter.recordingStarted() }
        await waitForGeneration(muter, 1)
        await muter.recordingEnded()
        let second = Task { await muter.recordingStarted() }
        await waitForGeneration(muter, 3)
        await first.value
        await second.value
        await pastTheDelay()

        #expect(control.state(of: 1) == true)
        #expect(control.setCalls == [.init(muted: true, device: 1)])

        // And the session that is actually running can still be ended.
        await muter.recordingEnded()
        #expect(control.state(of: 1) == false)
    }

    /// A full session followed by another one: the second mute has to land
    /// even though the first already went round the loop.
    @Test func aSecondSessionMutesAgain() async {
        let control = FakeMuteControl()
        let muter = makeController(control)

        await muter.recordingStarted()
        await muter.recordingEnded()
        await muter.recordingStarted()

        #expect(control.state(of: 1) == true)
        #expect(control.setCalls == [
            .init(muted: true, device: 1),
            .init(muted: false, device: 1),
            .init(muted: true, device: 1),
        ])
    }

    @Test func aThrowingSetIsSwallowedAndLogged() async {
        let control = FakeMuteControl()
        control.setThrowOnSet(true)
        let recorder = LineRecorder()
        let muter = makeController(control) { recorder.append($0) }

        await muter.recordingStarted()
        await muter.recordingEnded()

        #expect(recorder.lines.contains { $0.contains("could not mute") })
        // The mute never took, so there is nothing to restore and no second
        // call that could throw.
        #expect(control.setCalls == [.init(muted: true, device: 1)])
    }

    @Test func aThrowingUnmuteIsSwallowedAndLogged() async {
        let control = FakeMuteControl()
        let recorder = LineRecorder()
        let muter = makeController(control) { recorder.append($0) }

        await muter.recordingStarted()
        control.setThrowOnSet(true)
        await muter.recordingEnded()

        #expect(recorder.lines.contains { $0.contains("could not unmute") })
    }

    @Test func endingWithNothingMutedDoesNothing() async {
        let control = FakeMuteControl()
        let muter = makeController(control)

        await muter.recordingEnded()

        #expect(control.setCalls.isEmpty)
    }
}

/// Collects the controller's log lines from the `@Sendable` closure.
private final class LineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func append(_ line: String) { lock.withLock { _lines.append(line) } }
}
