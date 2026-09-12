import AVFoundation

/// Errors thrown while converting audio buffers.
public enum AudioConversionError: Error, CustomStringConvertible, Sendable {
    /// `AVAudioConverter` refused the format pair (for example a zero sample rate,
    /// which is what an input node reports before microphone permission is granted).
    case converterUnavailable(from: String, to: String)
    /// `AVAudioFormat` or `AVAudioPCMBuffer` allocation failed.
    case allocationFailed
    /// The output format is not deinterleaved Float32, so there is no `[Float]` to read.
    case unsupportedOutputFormat
    /// `AVAudioConverter` reported an error mid-conversion.
    case conversionFailed(String)

    public var description: String {
        switch self {
        case .converterUnavailable(let from, let to):
            return "Cannot convert audio from \(from) to \(to)"
        case .allocationFailed:
            return "Could not allocate an audio buffer"
        case .unsupportedOutputFormat:
            return "Output format must be deinterleaved Float32"
        case .conversionFailed(let message):
            return "Audio conversion failed: \(message)"
        }
    }

    public var localizedDescription: String { description }
}

/// Pure audio helpers: format conversion and level metering.
///
/// These live apart from `AVAudioEngineCapture` so the conversion path — the risky
/// part, since the microphone hands us 48 kHz stereo and the transcription engines
/// want 16 kHz mono — can be unit tested against a synthesised buffer with no
/// hardware and no permission prompt.
public struct AudioResampler: Sendable {
    /// The format every engine in this app consumes: 16 kHz mono Float32, deinterleaved.
    public static func monoFloat32Format(sampleRate: Double = 16_000) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioConversionError.allocationFailed
        }
        return format
    }

    /// Makes a converter for a single recording. Reusing one converter across all
    /// buffers of a recording keeps the resampler's internal filter state continuous,
    /// so there are no clicks at buffer boundaries.
    public static func makeConverter(from input: AVAudioFormat, to output: AVAudioFormat) throws -> AVAudioConverter {
        guard input.sampleRate > 0, input.channelCount > 0 else {
            throw AudioConversionError.converterUnavailable(from: "\(input)", to: "\(output)")
        }
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw AudioConversionError.converterUnavailable(from: "\(input)", to: "\(output)")
        }
        return converter
    }

    /// One-shot conversion of a complete buffer. Creates a converter, pushes the
    /// buffer through it and flushes, so the tail of the resampling filter is included.
    ///
    /// Channel downmix (stereo -> mono) is done by `AVAudioConverter` itself.
    public static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> [Float] {
        let converter = try makeConverter(from: buffer.format, to: format)
        return try run(buffer, through: converter, to: format, endOfStream: true)
    }

    /// Streaming conversion of one buffer of an ongoing recording, reusing `converter`.
    ///
    /// Unlike `convert(_:to:)` this never signals end of stream, because more buffers
    /// are coming; it stops as soon as the converter runs dry of input.
    public static func convertChunk(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) throws -> [Float] {
        try run(buffer, through: converter, to: format, endOfStream: false)
    }

    // MARK: Core

    private static func run(
        _ buffer: AVAudioPCMBuffer,
        through converter: AVAudioConverter,
        to format: AVAudioFormat,
        endOfStream: Bool
    ) throws -> [Float] {
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw AudioConversionError.unsupportedOutputFormat
        }
        guard buffer.frameLength > 0 else { return [] }

        let ratio = format.sampleRate / buffer.format.sampleRate
        // Enough room for the resampled frames plus the filter's tail.
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        var output: [Float] = []
        output.reserveCapacity(Int(capacity))

        // The input block hands the converter the buffer exactly once. Afterwards it
        // reports either "no more input right now" (streaming: the converter returns
        // .inputRanDry and we come back with the next tap buffer) or "end of stream"
        // (one-shot: the converter flushes and returns .endOfStream). Returning
        // .haveData again here would make the converter consume the same buffer
        // forever, which is the classic AVAudioConverter infinite loop.
        // The input buffer and the "already handed over" flag live in a box because
        // `AVAudioConverterInputBlock` is `@Sendable` and cannot capture a mutable
        // local or a non-Sendable `AVAudioPCMBuffer`. The converter only ever calls
        // the block synchronously from `convert(to:error:withInputFrom:)` below, on
        // this thread, so there is no actual concurrent access.
        let state = ConversionState(buffer: buffer)
        let inputBlock: AVAudioConverterInputBlock = { _, statusPointer in
            guard let input = state.take() else {
                statusPointer.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            statusPointer.pointee = .haveData
            return input
        }

        while true {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw AudioConversionError.allocationFailed
            }
            var error: NSError?
            let status = converter.convert(to: chunk, error: &error, withInputFrom: inputBlock)

            if let channel = chunk.floatChannelData?[0], chunk.frameLength > 0 {
                output.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(chunk.frameLength)))
            }

            switch status {
            case .haveData:
                // Output buffer filled up before the input was exhausted; go around
                // again. A zero-frame .haveData would mean no progress, so bail out.
                if chunk.frameLength == 0 { return output }
            case .inputRanDry, .endOfStream:
                return output
            case .error:
                throw AudioConversionError.conversionFailed(error?.localizedDescription ?? "unknown error")
            @unknown default:
                return output
            }
        }
    }

    // MARK: Level

    /// Perceptual level for a meter: RMS mapped so -50 dBFS is 0 and 0 dBFS is 1.
    public static func rmsLevel(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares = 0.0
        for sample in samples {
            let value = Double(sample)
            sumOfSquares += value * value
        }
        let rms = (sumOfSquares / Double(samples.count)).squareRoot()
        guard rms > 0 else { return 0 }
        // -60 dBFS maps to 0 and 0 dBFS to 1. Conversational speech through a
        // laptop microphone sits around -35...-20 dBFS, so the square root lifts
        // that band into the upper half of the meter instead of leaving it flat.
        let dBFS = 20 * log10(rms)
        let linear = min(1, max(0, (dBFS + 60) / 60))
        return Float(linear.squareRoot())
    }

    /// Convenience overload for an array of samples.
    public static func rmsLevel(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { rmsLevel($0) }
    }
}

/// Hands the input buffer to the converter exactly once.
/// See `AudioResampler.run(_:through:to:endOfStream:)`.
private final class ConversionState: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
