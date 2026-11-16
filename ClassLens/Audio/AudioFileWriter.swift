import AVFoundation

/// Writes 16 kHz mono samples to an AAC `.m4a` file (about 15 MB per hour).
final class AudioFileWriter {
    private let file: AVAudioFile

    init(url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: LectureAudio.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func write(_ samples: [Float]) throws {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: LectureAudio.format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: source.count) }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }

    func close() {
        file.close()
    }
}
