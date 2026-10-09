import AVFoundation
import PladderCore
import os

// The engine runs only while recording: a running input engine keeps the orange
// microphone indicator on. The tap block runs on a realtime thread: no actor state,
// no awaits, no unpredictable allocation.
public actor AVAudioEngineCapture: AudioCapture {
    public nonisolated static let targetSampleRate: Double = 16_000

    // ~43 ms at 48 kHz: a lively meter without waking the realtime thread too often.
    private static let tapBufferSize: AVAudioFrameCount = 2048

    public enum CaptureError: Error, CustomStringConvertible, Sendable {
        case noInputDevice
        case engineStartFailed(String)

        public var description: String {
            switch self {
            case .noInputDevice:
                return "No microphone input is available. Check the input device and microphone permission."
            case .engineStartFailed(let message):
                return "Could not start the audio engine: \(message)"
            }
        }

        public var localizedDescription: String { description }
    }

    private let engine = AVAudioEngine()
    // A device change mid-recording installs a new tap in front of the same
    // accumulator, so the switch loses nothing.
    private var accumulator: SampleAccumulator?
    private var levelContinuation: AsyncStream<Float>.Continuation?
    private var isRecording = false
    private var configurationObserver: NotificationObserver?

    public init() {}

    // MARK: AudioCapture

    // Throws without microphone permission on a first launch; `start()` retries.
    public func warmUp() async throws {
        observeConfigurationChanges()
        _ = try usableInputFormat()
        engine.prepare()
    }

    public func start() async throws -> AsyncStream<Float> {
        if isRecording {
            _ = await stop()
        }
        observeConfigurationChanges()
        try startEngineIfNeeded()

        let (stream, continuation) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(1))
        levelContinuation = continuation
        let accumulator = SampleAccumulator()
        do {
            try installTap(into: accumulator, continuation: continuation)
        } catch {
            continuation.finish()
            levelContinuation = nil
            throw error
        }
        self.accumulator = accumulator
        isRecording = true
        Self.startMarker()
        return stream
    }

    private static func startMarker() {
        log.log("capture started")
    }

    public func drain() async -> [Float] {
        guard isRecording, let accumulator else { return [] }
        return accumulator.drain()
    }

    public func stop() async -> CapturedAudio {
        Self.log.log("capture stop called, isRecording=\(self.isRecording)")
        guard isRecording else { return CapturedAudio(samples: []) }
        isRecording = false

        engine.inputNode.removeTap(onBus: 0)
        // `removeTap(onBus:)` returns only once the tap block has stopped, so this drain
        // gets every buffer the hardware delivered.
        let samples = accumulator?.drain() ?? []
        accumulator = nil

        levelContinuation?.finish()
        levelContinuation = nil

        // Off the release path: the pause blocks on the current hardware I/O cycle, and the
        // microphone indicator going off a few milliseconds later is invisible.
        Task { [weak self] in await self?.pauseIfIdle() }
        let logged = CapturedAudio(samples: samples)
        Self.log.log("capture stop: \(logged.samples.count) samples (\(logged.duration, format: .fixed(precision: 2)) s), pause deferred")
        return logged
    }

    private static let log = Logger(subsystem: "de.dinooo13.pladder", category: "capture")

    // `startEngineIfNeeded` skips a running engine, so a back-to-back recording stays live.
    private func pauseIfIdle() {
        guard !isRecording else {
            Self.log.log("pause skipped: a recording is active")
            return
        }
        engine.pause()
        Self.log.log("engine paused")
    }

    // MARK: Engine

    private func startEngineIfNeeded() throws {
        guard !engine.isRunning else { return }
        _ = try usableInputFormat()
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw CaptureError.engineStartFailed(error.localizedDescription)
        }
    }

    private func usableInputFormat() throws -> AVAudioFormat {
        // With no permission or no device the input node reports 0 Hz and 0 channels.
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }
        return format
    }

    private func installTap(
        into accumulator: SampleAccumulator,
        continuation: AsyncStream<Float>.Continuation
    ) throws {
        let input = engine.inputNode
        let inputFormat = try usableInputFormat()

        let targetFormat = try AudioResampler.monoFloat32Format(sampleRate: Self.targetSampleRate)
        // One converter per recording keeps the resampler's filter state continuous across
        // buffers: no clicks at the boundaries.
        let converter = try AudioResampler.makeConverter(from: inputFormat, to: targetFormat)
        let processor = TapProcessor(converter: converter, targetFormat: targetFormat, accumulator: accumulator)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: inputFormat) { buffer, _ in
            // Realtime audio thread: no actor hops, no locks held by anyone else.
            let level = processor.process(buffer)
            continuation.yield(level)
        }
    }

    // MARK: Device changes

    private func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleConfigurationChange() }
        }
        configurationObserver = NotificationObserver(token: token)
    }

    // AVAudioEngine tears down its graph and stops when the default device changes.
    private func handleConfigurationChange() {
        guard isRecording, let accumulator, let continuation = levelContinuation else { return }
        engine.inputNode.removeTap(onBus: 0)
        // Either failure leaves the recording without a tap until `stop()`, which still
        // returns what was captured before the change.
        do {
            try startEngineIfNeeded()
            try installTap(into: accumulator, continuation: continuation)
        } catch {
            Self.log.error("device change: capture did not resume: \(String(describing: error), privacy: .public)")
        }
    }
}

// The actor's nonisolated `deinit` may not touch its state, so the token's lifetime
// unregisters the observer.
private final class NotificationObserver: @unchecked Sendable {
    private let token: any NSObjectProtocol

    init(token: any NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

// `@unchecked Sendable`: only the tap block calls `process`, and CoreAudio
// serialises tap blocks.
private final class TapProcessor: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let accumulator: SampleAccumulator

    init(converter: AVAudioConverter, targetFormat: AVAudioFormat, accumulator: SampleAccumulator) {
        self.converter = converter
        self.targetFormat = targetFormat
        self.accumulator = accumulator
    }

    func process(_ buffer: AVAudioPCMBuffer) -> Float {
        let converted: [Float]
        do {
            converted = try AudioResampler.convertChunk(buffer, using: converter, to: targetFormat)
        } catch {
            return 0
        }
        guard !converted.isEmpty else { return 0 }
        let level = AudioResampler.rmsLevel(converted)
        accumulator.append(converted)
        return level
    }
}
