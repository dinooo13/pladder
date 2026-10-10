import AVFoundation

public enum AudioConversionError: Error, CustomStringConvertible, Sendable {
    case converterUnavailable(from: String, to: String)
    case allocationFailed
    case unsupportedOutputFormat
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

public struct AudioResampler: Sendable {
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

    public static func makeConverter(from input: AVAudioFormat, to output: AVAudioFormat) throws -> AVAudioConverter {
        guard input.sampleRate > 0, input.channelCount > 0 else {
            throw AudioConversionError.converterUnavailable(from: "\(input)", to: "\(output)")
        }
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw AudioConversionError.converterUnavailable(from: "\(input)", to: "\(output)")
        }
        return converter
    }

    public static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> [Float] {
        let converter = try makeConverter(from: buffer.format, to: format)
        return try run(buffer, through: converter, to: format, endOfStream: true)
    }

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
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        var output: [Float] = []
        output.reserveCapacity(Int(capacity))

        // The block hands the buffer over exactly once, then reports "no data now" or "end
        // of stream": `.haveData` again would make the converter consume it forever. A box,
        // because the block is `@Sendable`; the converter calls it synchronously, here.
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
                // A zero-frame `.haveData` would mean no progress.
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

    public static func rmsLevel(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares = 0.0
        for sample in samples {
            let value = Double(sample)
            sumOfSquares += value * value
        }
        let rms = (sumOfSquares / Double(samples.count)).squareRoot()
        guard rms > 0 else { return 0 }
        // -60 dBFS maps to 0 and 0 dBFS to 1. Speech through a laptop microphone sits around
        // -35 to -20 dBFS, so the square root lifts that band into the upper half.
        let dBFS = 20 * log10(rms)
        let linear = min(1, max(0, (dBFS + 60) / 60))
        return Float(linear.squareRoot())
    }

    public static func rmsLevel(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { rmsLevel($0) }
    }
}

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
