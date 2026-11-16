import Foundation
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioSTT

/// Local Qwen3-ASR 1.7B on MLX. Chosen over SpeechAnalyzer, Parakeet and Whisper in docs/decisions.md.
actor Qwen3ASREngine: TranscriptionEngine {
    static let repository = "mlx-community/Qwen3-ASR-1.7B-8bit"

    enum Failure: LocalizedError {
        case invalidRepository

        var errorDescription: String? { "识别模型的地址无效：\(Qwen3ASREngine.repository)" }
    }

    nonisolated let name = "Qwen3-ASR 1.7B"
    private let model: Qwen3ASRModel

    private init(model: sending Qwen3ASRModel) {
        self.model = model
    }

    /// Downloads the model on first use (about 2.5 GB), loads it and runs one warm-up pass,
    /// so the first real utterance isn't slowed by kernel compilation.
    static func load(progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> Qwen3ASREngine {
        guard let repository = Repo.ID(rawValue: repository) else { throw Failure.invalidRepository }
        let cache = HubCache.default
        let directory = try await ModelUtils.resolveOrDownloadModel(
            client: HubClient(cache: cache),
            cache: cache,
            repoID: repository,
            requiredExtension: "safetensors",
            progressHandler: { progress($0.fractionCompleted) }
        )
        // Each utterance has a different length, so MLX's buffer cache keeps growing (it reached 1.6 GB in a
        // 2-minute replay). Under memory pressure that growth stalls a call for tens of seconds while the
        // system swaps; a small cache costs almost nothing in speed.
        Memory.cacheLimit = 256 * 1_048_576
        let model = try await Qwen3ASRModel.fromModelDirectory(directory)
        let engine = Qwen3ASREngine(model: model)
        _ = try await engine.transcribe([Float](repeating: 0, count: Int(LectureAudio.sampleRate)), context: "")
        return engine
    }

    func transcribe(_ samples: [Float], context: String) async throws -> String {
        // About 15 s of speech is under 100 tokens; the cap bounds a runaway repetition loop.
        let output = model.generate(audio: MLXArray(samples), maxTokens: 256, context: context, language: "English")
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
