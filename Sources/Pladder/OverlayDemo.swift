import AppKit
import Foundation
import PladderCore

/// `Pladder --overlay-demo` plays one dictation per overlay path through the
/// real coordinator and the real pill, then quits. The engine, capture,
/// paste, refiner and hotkey are stand-ins and the press and release come
/// from here, so it never starts the hotkey, the microphone or the engine and
/// can run beside a copy of Pladder that is in use. It prints every press,
/// release and state change with its wall-clock time, which is what
/// `scripts/overlay-demo.sh` lines the screen recording up against.
///
/// `--style compact|minimal|liveTranscript` and
/// `--speed instant|quick|expressive` pick the pill; the default is Compact
/// at Quick.
@MainActor
enum OverlayDemo {
    static var isRequested: Bool { CommandLine.arguments.contains("--overlay-demo") }

    private struct Scenario {
        let name: String
        let text: String
        var polish = false
        /// How long the engine takes; past the overlay's spinner delay it
        /// brings the pill back.
        var engineDelay: Duration = .milliseconds(200)
        var result: InsertResult = .pasted
    }

    private static let sentence = "This is a longer test sentence for the overlay."

    private static let scenarios = [
        Scenario(name: "plain", text: sentence),
        Scenario(name: "slow", text: sentence, engineDelay: .milliseconds(900)),
        Scenario(name: "copied", text: sentence, result: .copied),
        Scenario(name: "polish", text: sentence, polish: true),
        // Under the polish minimum: pasted straight from `.transcribing`.
        Scenario(name: "polish-short", text: "Hello there.", polish: true),
    ]

    static func run() async {
        let style = argument(after: "--style").flatMap(OverlayStyle.init(rawValue:)) ?? .compact
        let speed = argument(after: "--speed").flatMap(OverlayAnimationSpeed.init(rawValue:)) ?? .quick
        // Room for the recording to start before the first pill.
        try? await Task.sleep(for: .seconds(1))
        for scenario in scenarios {
            await play(scenario, style: style, speed: speed)
        }
        log("done")
        NSApp.terminate(nil)
    }

    private static func play(_ scenario: Scenario, style: OverlayStyle, speed: OverlayAnimationSpeed) async {
        var settings = Settings(engineID: EchoEngine.engineID)
        settings.polishDictations = scenario.polish
        settings.overlayStyle = style
        settings.overlayAnimationSpeed = speed
        settings.playSounds = false
        let registry = EngineRegistry([
            .init(id: EchoEngine.engineID, displayName: "Echo", detail: "") {
                EchoEngine(text: scenario.text, delay: scenario.engineDelay)
            }
        ])
        let coordinator = DictationCoordinator(
            settings: settings,
            registry: registry,
            capture: DemoCapture(),
            output: DemoOutput(result: scenario.result),
            refiner: DemoRefiner(),
            hotkeyMonitor: DemoHotkey(),
            makePipeline: { _ in ProcessorPipeline([]) }
        )
        let overlay = OverlayController(coordinator: coordinator)
        overlay.applyAppearance(.system)
        overlay.applyStyle(style, glass: true)
        overlay.applySpeed(speed)
        coordinator.start()
        overlay.start()
        while !coordinator.engineStatus.isReady {
            try? await Task.sleep(for: .milliseconds(20))
        }

        log("\(scenario.name) press")
        await coordinator.hotkeyPressed()
        try? await Task.sleep(for: .seconds(2))
        log("\(scenario.name) release")
        coordinator.hotkeyReleased()
        var last = "recording"
        while true {
            let state = name(of: coordinator.state)
            if state != last {
                log("\(scenario.name) \(state)")
                last = state
            }
            if state == "idle" { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        // Long enough for the slowest dive to finish before the next take.
        try? await Task.sleep(for: .seconds(1.5))
        overlay.stop()
        coordinator.stop()
    }

    private static func name(of state: DictationState) -> String {
        switch state {
        case .idle: "idle"
        case .unavailable: "unavailable"
        case .recording: "recording"
        case .transcribing: "transcribing"
        case .polishing: "polishing"
        case .inserting: "inserting"
        case .copied: "copied"
        case .error: "error"
        }
    }

    private static func log(_ line: String) {
        print(String(format: "%.3f ", Date().timeIntervalSince1970) + line)
        fflush(stdout)
    }

    private static func argument(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}

/// A steady wave for the meter and two seconds of silence at the release,
/// enough to clear the coordinator's minimum duration.
private actor DemoCapture: AudioCapture {
    private var levels: AsyncStream<Float>.Continuation?

    func start() async throws -> AsyncStream<Float> {
        let (stream, continuation) = AsyncStream<Float>.makeStream()
        levels = continuation
        Task {
            var tick = 0.0
            while await self.isRunning {
                continuation.yield(Float(0.2 + 0.4 * abs(sin(tick / 3))))
                tick += 1
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        return stream
    }

    private var isRunning: Bool { levels != nil }

    func drain() async -> [Float] { [] }

    func stop() async -> CapturedAudio {
        levels?.finish()
        levels = nil
        return CapturedAudio(samples: .init(repeating: 0, count: Int(2 * CapturedAudio.sampleRate)))
    }

    func warmUp() async throws {}
}

private final class DemoOutput: TextOutput, @unchecked Sendable {
    let result: InsertResult
    init(result: InsertResult) { self.result = result }
    func insert(_ text: String, submit: Bool) async throws -> InsertResult { result }
    func prepare() async {}
}

/// About as long as the on-device model takes for a short dictation.
private final class DemoRefiner: TranscriptRefiner, @unchecked Sendable {
    func prepare() async {}
    func refine(_ text: String) async -> String? {
        try? await Task.sleep(for: .milliseconds(1800))
        return text
    }
}

private final class DemoHotkey: HotkeyMonitor, @unchecked Sendable {
    func start(chords: [HotkeyRole: Hotkey], submitKey: Hotkey) -> AsyncStream<HotkeyMonitorEvent> {
        AsyncStream { _ in }
    }
    func stop() {}
    func setCancelKeyEnabled(_ enabled: Bool) {}
}
