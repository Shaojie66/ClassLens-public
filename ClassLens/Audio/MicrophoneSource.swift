import AVFoundation
import OSLog

/// Captures the default input device as 16 kHz mono chunks.
///
/// Classroom mode turns on the system's voice processing (noise suppression, automatic gain) and falls back
/// to the plain microphone if that will not start. Approach adapted from Nomi (MIT), Engine/LocalEngine.swift.
@MainActor
final class MicrophoneSource {
    enum Failure: LocalizedError {
        case permissionDenied
        case noInput
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .permissionDenied: "没有麦克风权限。请到“系统设置 › 隐私与安全性 › 麦克风”里允许 ClassLens。"
            case .noInput: "找不到可用的麦克风。"
            case .unsupportedFormat: "麦克风的音频格式无法转换。"
            }
        }
    }

    private static let logger = Logger(subsystem: "com.chenshaojie.ClassLens", category: "Microphone")
    private var engine: AVAudioEngine?
    private var continuation: AsyncThrowingStream<[Float], Error>.Continuation?

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    func start(classroomMode: Bool) async throws -> AsyncThrowingStream<[Float], Error> {
        guard await Self.requestPermission() else { throw Failure.permissionDenied }
        if classroomMode {
            do {
                return try open(voiceProcessing: true)
            } catch {
                Self.logger.error("Classroom mode failed, using plain microphone: \(error.localizedDescription, privacy: .public)")
            }
        }
        return try open(voiceProcessing: false)
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        continuation?.finish()
        continuation = nil
    }

    private func open(voiceProcessing: Bool) throws -> AsyncThrowingStream<[Float], Error> {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            // Leave other apps' sound alone; voice processing would otherwise duck it.
            input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            // Voice processing runs input and output as one unit, so the output node must exist.
            _ = engine.outputNode
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }
        // The converter maps the first channel, which is the processed voice when voice processing is on.
        guard let converter = PCMConverter(from: format) else { throw Failure.unsupportedFormat }

        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        // The tap runs on an audio thread. Without `@Sendable` the closure inherits this method's `@MainActor`
        // isolation and Swift's runtime check traps on the first buffer.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            let samples = converter.convert(buffer)
            if !samples.isEmpty { continuation.yield(samples) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        Self.logger.notice("Microphone started at \(format.sampleRate) Hz, voice processing \(voiceProcessing)")
        self.engine = engine
        self.continuation = continuation
        return stream
    }
}
