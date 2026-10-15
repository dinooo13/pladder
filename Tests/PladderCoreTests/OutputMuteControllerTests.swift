import Foundation
import PladderTestSupport
import Testing
@testable import PladderCore

private final class FakeMuteControl: OutputMuteControl, @unchecked Sendable {
    struct SetCall: Equatable {
        var device: UInt32
        var elements: [UInt32: Bool]

        static func mute(_ device: UInt32, _ elements: [UInt32] = [0]) -> SetCall {
            SetCall(device: device, elements: Dictionary(uniqueKeysWithValues: elements.map { ($0, true) }))
        }

        static func unmute(_ device: UInt32, _ elements: [UInt32] = [0]) -> SetCall {
            SetCall(device: device, elements: Dictionary(uniqueKeysWithValues: elements.map { ($0, false) }))
        }
    }

    private let lock = NSLock()
    private var _defaultDevice: UInt32?
    private var _devices: [UInt32: [UInt32: Bool]]
    private var _setCalls: [SetCall] = []
    private var _throwOnSet = false
    private var _failingElements: Set<UInt32> = []

    init(defaultDevice: UInt32? = 1, devices: [UInt32: [UInt32: Bool]] = [1: [0: false]]) {
        _defaultDevice = defaultDevice
        _devices = devices
    }

    var setCalls: [SetCall] { lock.withLock { _setCalls } }
    func elements(of device: UInt32) -> [UInt32: Bool]? { lock.withLock { _devices[device] } }
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

// Short enough to keep the tests fast, long enough that a "before the delay" call
// really lands before it.
private let testDelay = Duration.milliseconds(10)

private func makeController(
    _ control: FakeMuteControl,
    delay: Duration = testDelay,
    log: @escaping @Sendable (String) -> Void = { _ in }
) -> OutputMuteController {
    OutputMuteController(control: control, delay: delay, log: log)
}

private func waitForGeneration(_ muter: OutputMuteController, _ target: Int) async {
    while await muter.armedGeneration < target { await Task.yield() }
}

private func pastTheDelay() async {
    try? await Task.sleep(for: testDelay * 4)
}

@Suite(.timeLimit(.minutes(1))) struct OutputMuteControllerTests {
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

    @Test func aChannelTheUserMutedIsMutedAgainAfterwards() async {
        let control = FakeMuteControl(devices: [1: [1: true, 2: false]])
        let muter = makeController(control)

        await muter.recordingStarted(session: 1)
        #expect(control.elements(of: 1) == [1: true, 2: true])

        await muter.recordingEnded(session: 1)
        #expect(control.elements(of: 1) == [1: true, 2: false])
        #expect(control.setCalls == [.mute(1, [2]), .unmute(1, [2])])
    }

    @Test func aHalfAppliedMuteRestoresWhatLanded() async {
        let control = FakeMuteControl(devices: [1: [1: false, 2: false]])
        control.setFailingElements([2])
        let recorder = Recorder<String>()
        let muter = makeController(control) { recorder.append($0) }

        await muter.recordingStarted(session: 1)
        #expect(control.elements(of: 1) == [1: true, 2: false])
        #expect(recorder.all.contains { $0.contains("could not mute") })

        await muter.recordingEnded(session: 1)
        #expect(control.elements(of: 1) == [1: false, 2: false])
        #expect(control.setCalls.last == .unmute(1, [1]))
    }

    @Test func theDefaultDeviceChangingMidRecordingStillUnmutesTheOriginal() async {
        let control = FakeMuteControl(devices: [1: [0: false], 2: [0: false]])
        let muter = makeController(control)

        await muter.recordingStarted(session: 1)
        #expect(control.state(of: 1) == true)
        control.setDefaultDevice(2)
        await muter.recordingEnded(session: 1)

        #expect(control.state(of: 1) == false)
        #expect(control.state(of: 2) == false)
        #expect(control.setCalls == [.mute(1), .unmute(1)])
    }

    @Test func aDeviceWithoutAMuteControlIsSkipped() async {
        let control = FakeMuteControl(defaultDevice: 7, devices: [:])
        let recorder = Recorder<String>()
        let muter = makeController(control) { recorder.append($0) }

        await muter.recordingStarted(session: 1)
        await muter.recordingEnded(session: 1)

        #expect(control.setCalls.isEmpty)
        #expect(recorder.all.contains { $0.contains("no mute control") })
    }

    @Test func noDefaultDeviceIsSkipped() async {
        let control = FakeMuteControl(defaultDevice: nil)
        let recorder = Recorder<String>()
        let muter = makeController(control) { recorder.append($0) }

        await muter.recordingStarted(session: 1)
        await muter.recordingEnded(session: 1)

        #expect(control.setCalls.isEmpty)
        #expect(recorder.all.contains { $0.contains("no default output device") })
    }

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

        await muter.recordingEnded(session: 2)
        #expect(control.state(of: 1) == false)
    }

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
        let recorder = Recorder<String>()
        let muter = makeController(control) { recorder.append($0) }

        await muter.recordingStarted(session: 1)
        await muter.recordingEnded(session: 1)

        #expect(recorder.all.contains { $0.contains("could not mute") })
        #expect(control.setCalls == [.mute(1)])
    }

    @Test func aThrowingUnmuteIsSwallowedAndLogged() async {
        let control = FakeMuteControl()
        let recorder = Recorder<String>()
        let muter = makeController(control) { recorder.append($0) }

        await muter.recordingStarted(session: 1)
        control.setThrowOnSet(true)
        await muter.recordingEnded(session: 1)

        #expect(recorder.all.contains { $0.contains("could not unmute") })
    }

    @Test func endingWithNothingMutedDoesNothing() async {
        let control = FakeMuteControl()
        let muter = makeController(control)

        await muter.recordingEnded(session: 1)

        #expect(control.setCalls.isEmpty)
    }

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

    @Test func aStartOlderThanTheNewestSessionDoesNothing() async {
        let control = FakeMuteControl()
        let muter = makeController(control)

        await muter.recordingEnded(session: 3)
        await muter.recordingStarted(session: 2)

        #expect(control.setCalls.isEmpty)
    }
}
