import AVFoundation

/// The one audio format the pipeline uses after capture: 16 kHz mono Float32, what the recognizers expect.
enum LectureAudio {
    static let sampleRate: Double = 16_000

    static let format: AVAudioFormat = {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            preconditionFailure("16 kHz mono Float32 is always a valid format")
        }
        return format
    }()

    /// Root-mean-square level of a chunk, 0…1.
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// Converts buffers of any input format to `LectureAudio.format`. Keeps resampler state between calls,
/// so it must be fed from one thread in order; the audio tap and the replay reader each own one.
final class PCMConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let ratio: Double

    init?(from input: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: LectureAudio.format) else { return nil }
        self.converter = converter
        self.ratio = LectureAudio.sampleRate / input.sampleRate
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: LectureAudio.format, frameCapacity: capacity) else { return [] }
        let input = PendingInput(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let buffer = input.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// Hands one buffer to AVAudioConverter's input block. The block is `@Sendable` in the SDK but is called
/// synchronously inside `convert(to:error:)`, on the caller's thread, so no lock is needed.
private final class PendingInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
