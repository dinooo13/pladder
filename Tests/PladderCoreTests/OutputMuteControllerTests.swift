import Foundation
import Testing
@testable import PladderCore

/// A stand-in for the audio system, element by element. Records every call so
/// the ordering rules can be asserted, and lets a test move the default device
/// or make a set throw the way a disappearing USB interface would.
private final class FakeMuteControl: OutputMuteControl, @unchecked Sendable {
    struct SetCall: Equatable {
        var device: UInt32
        var elements: [UInt32: Bool]

        /// The master element of `device`, the usual single switch.
        static func mute(_ device: UInt32, _ elements: [UInt32] = [0]) -> SetCall {
            SetCall(device: device, elements: Dictionary(uniqueKeysWithValues: elements.map { ($0, true) }))
        }

        static func unmute(_ device: UInt32, _ elements: [UInt32] = [0]) -> SetCall {
            SetCall(device: device, elements: Dictionary(uniqueKeysWithValues: elements.map { ($0, false) }))
        }
    }

    private let lock = NSLock()
    private var _defaultDevice: UInt32?
    /// Devices that have a mute control: element → whether it is on.
    private var _devices: [UInt32: [UInt32: Bool]]
    private var _setCalls: [SetCall] = []
    private var _throwOnSet = false
    /// Elements whose set fails while the others in the same call land.
    private var _failingElements: Set<UInt32> = []

    init(defaultDevice: UInt32? = 1, devices: [UInt32: [UInt32: Bool]] = [1: [0: false]]) {
        _defaultDevice = defaultDevice
        _devices = devices
    }

    var setCalls: [SetCall] { lock.withLock { _setCalls } }
    func elements(of device: UInt32) -> [UInt32: Bool]? { lock.withLock { _devices[device] } }
    /// The master element, for the single-switch devices most tests use.
    func state(of device: UInt32) -> Bool? { elements(of: device)?[0] }
    func setDefaultDevice(_ device: UInt32?) { lock.withLock { _defaultDevice = device } }
    func setThrowOnSet(_ value: Bool) { lock.withLock { _throwOnSet = value } }
    func setFailingElements(_ elements: Set<UInt32>) { lock.withLock { _failingElements = elements } }

    struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

    func defaultOutputDevice() -> UInt32? { lock.withLock { _defaultDevice } }

    func muteState(of device: UInt32) -> MuteState? {
        lock.withLock { _devices[device].map(MuteState.init) }
    }

    func apply(_ state: MuteState, to device: UInt32) throws {
        try lock.withLock {
            _setCalls.append(SetCall(device: device, elements: state.elements))
            if _throwOnSet { throw Boom() }
            var failed = false
            for (element, muted) in state.elements where _devices[device]?[element] != nil {
                if _failingElements.contains(element) {
                    failed = true
                } else {
                    _devices[device]?[element] = muted
                }
            }
            if failed { throw Boom() }
        }
    }
}

/// Short enough that the tests stay well under a second, long enough that a
/// "before the delay" call really lands before it.
private let testDelay = Duration.milliseconds(10)

private func makeController(
    _ control: FakeMuteControl,
    delay: Duration = testDelay,
    log: @escaping @Sendable (String) -> Void = { _ in }
) -> OutputMuteController {
    OutputMuteController(control: control, delay: delay, log: log)
}

/// Yields until the controller has taken the arm, so a `recordingStarted`
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

        let started = Task { await muter.recordingStarted(session: 1) }
        await waitForGeneration(muter, 1)
        await muter.recordingEnded(session: 1)
        await started.value
        await pastTheDelay()

        #expect(control.setCalls.isEmpty)
        #expect(control.state(of: 1) == false)
    }

    @Test func muteLandsAfterTheDelayAndIsRestoredOnEnd() async {
        let control = FakeMuteControl()
        let muter = makeController(control)

        await muter.recordingStarted(session: 1)
        #expect(control.state(of: 1) == true)

        await muter.recordingEnded(session: 1)
        #expect(control.state(of: 1) == false)
        #expect(control.setCalls == [.mute(1), .unmute(1)])
    }

    @Test func aDeviceTheUserMutedIsLeftMuted() async {
        let control = FakeMuteControl(devices: [1: [0: true]])
        let muter = makeController(control)

        await muter.recordingStarted(session: 1)
        await muter.recordingEnded(session: 1)

        #expect(control.setCalls.isEmpty)
        #expect(control.state(of: 1) == true)
    }

    /// The user muted the left channel; the right one is muted for the
    /// recording and only it is unmuted afterwards.
    @Test func aChannelTheUserMutedIsMutedAgainAfterwards() async {
        let control = FakeMuteControl(devices: [1: [1: true, 2: false]])
        let muter = makeController(control)

        await muter.recordingStarted(session: 1)
        #expect(control.elements(of: 1) == [1: true, 2: true])

        await muter.recordingEnded(session: 1)
        #expect(control.elements(of: 1) == [1: true, 2: false])
        #expect(control.setCalls == [.mute(1, [2]), .unmute(1, [2])])
    }

    /// One channel's set fails: the one that did land is still put back.
    @Test func aHalfAppliedMuteRestoresWhatLanded() async {
        let control = FakeMuteControl(devices: [1: [1: false, 2: false]])
        control.setFailingElements([2])
        let recorder = LineRecorder()
        let muter = makeController(control) { recorder.append($0) }

        await muter.recordingStarted(session: 1)
        #expect(control.elements(of: 1) == [1: true, 2: false])
        #expect(recorder.lines.contains { $0.contains("could not mute") })

        await muter.recordingEnded(session: 1)
        #expect(control.elements(of: 1) == [1: false, 2: false])
        #expect(control.setCalls.last == .unmute(1, [1]))
    }

    @Test func theDefaultDeviceChangingMidRecordingStillUnmutesTheOriginal() async {
        let control = FakeMuteControl(devices: [1: [0: false], 2: [0: false]])
        let muter = makeController(control)

        await muter.recordingStarted(session: 1)
        #expect(control.state(of: 1) == true)
        // The user pulls the headphones out halfway through.
        control.setDefaultDevice(2)
        await muter.recordingEnded(session: 1)

        #expect(control.state(of: 1) == false)
        #expect(control.state(of: 2) == false)
        #expect(control.setCalls == [.mute(1), .unmute(1)])
    }

    @Test func aDeviceWithoutAMuteControlIsSkipped() async {
        // No entry in `devices` means `muteState` answers nil.
        let control = FakeMuteControl(defaultDevice: 7, devices: [:])
        let recorder = LineRecorder()
        let muter = makeController(control) { recorder.append($0) }

        await muter.recordingStarted(session: 1)
        await muter.recordingEnded(session: 1)

        #expect(control.setCalls.isEmpty)
        #expect(recorder.lines.contains { $0.contains("no mute control") })
    }

    @Test func noDefaultDeviceIsSkipped() async {
        let control = FakeMuteControl(defaultDevice: nil)
        let recorder = LineRecorder()
        let muter = makeController(control) { recorder.append($0) }

        await muter.recordingStarted(session: 1)
        await muter.recordingEnded(session: 1)

        #expect(control.setCalls.isEmpty)
        #expect(recorder.lines.contains { $0.contains("no default output device") })
    }

    /// started → ended → started, all inside the delay: the last session wins
    /// and the device ends up muted, not unmuted by the first session's end.
    @Test func aRestartInsideTheDelayStillEndsUpMuted() async {
        let control = FakeMuteControl()
        let muter = makeController(control)

        let first = Task { await muter.recordingStarted(session: 1) }
        await waitForGeneration(muter, 1)
        await muter.recordingEnded(session: 1)
        let second = Task { await muter.recordingStarted(session: 2) }
        await waitForGeneration(muter, 3)
        await first.value
        await second.value
        await pastTheDelay()

        #expect(control.state(of: 1) == true)
        #expect(control.setCalls == [.mute(1)])

        // And the session that is actually running can still be ended.
        await muter.recordingEnded(session: 2)
        #expect(control.state(of: 1) == false)
    }

    /// A full session followed by another one: the second mute has to land
    /// even though the first already went round the loop.
    @Test func aSecondSessionMutesAgain() async {
        let control = FakeMuteControl()
        let muter = makeController(control)

        await muter.recordingStarted(session: 1)
        await muter.recordingEnded(session: 1)
        await muter.recordingStarted(session: 2)

        #expect(control.state(of: 1) == true)
        #expect(control.setCalls == [.mute(1), .unmute(1), .mute(1)])
    }

    @Test func aThrowingSetIsSwallowedAndLogged() async {
        let control = FakeMuteControl()
        control.setThrowOnSet(true)
        let recorder = LineRecorder()
        let muter = makeController(control) { recorder.append($0) }

        await muter.recordingStarted(session: 1)
        await muter.recordingEnded(session: 1)

        #expect(recorder.lines.contains { $0.contains("could not mute") })
        // The mute never took, so there is nothing to restore and no second
        // call that could throw.
        #expect(control.setCalls == [.mute(1)])
    }

    @Test func aThrowingUnmuteIsSwallowedAndLogged() async {
        let control = FakeMuteControl()
        let recorder = LineRecorder()
        let muter = makeController(control) { recorder.append($0) }

        await muter.recordingStarted(session: 1)
        control.setThrowOnSet(true)
        await muter.recordingEnded(session: 1)

        #expect(recorder.lines.contains { $0.contains("could not unmute") })
    }

    @Test func endingWithNothingMutedDoesNothing() async {
        let control = FakeMuteControl()
        let muter = makeController(control)

        await muter.recordingEnded(session: 1)

        #expect(control.setCalls.isEmpty)
    }

    // MARK: Sessions

    /// The coordinator's end task ran before its start task: the start must
    /// not mute with no end left to undo it, and must not even wait.
    @Test func endBeforeStartOfTheSameSessionNeverMutes() async {
        let control = FakeMuteControl()
        // Long enough that a start which slept would fail the time check.
        let muter = makeController(control, delay: .seconds(5))

        await muter.recordingEnded(session: 1)
        let started = ContinuousClock.now
        await muter.recordingStarted(session: 1)

        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(control.setCalls.isEmpty)
        #expect(control.state(of: 1) == false)
    }

    @Test func aLaterSessionStillMutesAfterAnEndBeforeStart() async {
        let control = FakeMuteControl()
        let muter = makeController(control)

        await muter.recordingEnded(session: 1)
        await muter.recordingStarted(session: 1)
        await muter.recordingStarted(session: 2)

        #expect(control.setCalls == [.mute(1)])
        await muter.recordingEnded(session: 2)
        #expect(control.state(of: 1) == false)
    }

    /// Session 1's end arrives late, while session 2's arm is pending.
    @Test func endOfAnOlderSessionDoesNotDisarmANewerOne() async {
        let control = FakeMuteControl()
        let muter = makeController(control)

        let second = Task { await muter.recordingStarted(session: 2) }
        await waitForGeneration(muter, 1)
        await muter.recordingEnded(session: 1)
        await second.value

        #expect(control.state(of: 1) == true)
        await muter.recordingEnded(session: 2)
        #expect(control.state(of: 1) == false)
        #expect(control.setCalls == [.mute(1), .unmute(1)])
    }

    /// Session 1 muted, session 2 started before session 1's end came: that
    /// end leaves the device muted for session 2, whose end restores it.
    @Test func endOfAnOlderSessionLeavesTheMuteToTheNewerOne() async {
        let control = FakeMuteControl()
        let muter = makeController(control)

        await muter.recordingStarted(session: 1)
        let second = Task { await muter.recordingStarted(session: 2) }
        await waitForGeneration(muter, 2)
        await muter.recordingEnded(session: 1)
        await second.value
        #expect(control.state(of: 1) == true)

        await muter.recordingEnded(session: 2)
        #expect(control.state(of: 1) == false)
        #expect(control.setCalls == [.mute(1), .unmute(1)])
    }

    /// A start for a session older than one already seen is late too.
    @Test func aStartOlderThanTheNewestSessionDoesNothing() async {
        let control = FakeMuteControl()
        let muter = makeController(control)

        await muter.recordingEnded(session: 3)
        await muter.recordingStarted(session: 2)

        #expect(control.setCalls.isEmpty)
    }

    /// Transitional: the session-less pair today's coordinator still calls.
    @Test func theSessionlessPairStillMutesAndRestores() async {
        let control = FakeMuteControl()
        let muter = makeController(control)

        await muter.recordingStarted()
        #expect(control.state(of: 1) == true)
        await muter.recordingEnded()
        await muter.recordingStarted()
        await muter.recordingEnded()

        #expect(control.setCalls == [.mute(1), .unmute(1), .mute(1), .unmute(1)])
    }
}

/// Collects the controller's log lines from the `@Sendable` closure.
private final class LineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func append(_ line: String) { lock.withLock { _lines.append(line) } }
}
