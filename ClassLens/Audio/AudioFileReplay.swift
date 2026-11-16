import AVFoundation
import Synchronization

/// Plays a recording into the pipeline as if it were the microphone, for testing and for transcribing old recordings.
final class AudioFileReplay: Sendable {
    enum Failure: LocalizedError {
        case unsupportedFormat

        var errorDescription: String? { "无法读取这个录音文件的音频格式。" }
    }

    let url: URL
    /// Seconds into the file to begin at.
    let start: TimeInterval
    /// Seconds to play; nil plays to the end.
    let duration: TimeInterval?
    /// 1 is real time; 0 reads as fast as possible.
    let speed: Double
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(url: URL, start: TimeInterval = 0, duration: TimeInterval? = nil, speed: Double = 1) {
        self.url = url
        self.start = start
        self.duration = duration
        self.speed = speed
    }

    /// Chunks of 100 ms, paced by `speed`. The stream ends at the end of the range or after `stop()`.
    func stream() -> AsyncThrowingStream<[Float], Error> {
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        let reader = Task.detached(priority: .userInitiated) { [url, start, duration, speed] in
            do {
                try await Self.read(url: url, start: start, duration: duration, speed: speed) { continuation.yield($0) }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        task.withLock { $0 = reader }
        continuation.onTermination = { _ in reader.cancel() }
        return stream
    }

    func stop() {
        task.withLock { $0?.cancel() }
    }

    private static func read(url: URL, start: TimeInterval, duration: TimeInterval?, speed: Double, yield: ([Float]) -> Void) async throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let converter = PCMConverter(from: format) else { throw Failure.unsupportedFormat }
        let first = min(file.length, AVAudioFramePosition(start * format.sampleRate))
        let last = duration.map { min(file.length, first + AVAudioFramePosition($0 * format.sampleRate)) } ?? file.length
        file.framePosition = first
        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        let clock = ContinuousClock()
        let began = clock.now
        var played: TimeInterval = 0
        while file.framePosition < last {
            try Task.checkCancellation()
            let count = min(chunk, AVAudioFrameCount(last - file.framePosition))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { throw Failure.unsupportedFormat }
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { break }
            yield(converter.convert(buffer))
            played += Double(buffer.frameLength) / format.sampleRate
            if speed > 0 {
                try await clock.sleep(until: began + .seconds(played / speed))
            }
        }
    }
}
