import Foundation

struct ChatMessage: Codable, Sendable, Equatable {
    enum Role: String, Codable, Sendable {
        case system, user, assistant
    }

    var role: Role
    var content: String
}

struct ChatRequest: Sendable, Equatable {
    var model: String
    var messages: [ChatMessage]
    var temperature: Double = 0.3
    var maxTokens = 1024
    /// Asks for a JSON object reply; the prompt must mention JSON.
    var jsonOutput = false
}

/// A chat-completion endpoint. Implementations: OpenAI-compatible HTTP (DeepSeek), fakes in tests.
protocol LLMClient: Sendable {
    func complete(_ request: ChatRequest) async throws -> String
    /// The reply in pieces as they are generated.
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error>
}

extension LLMClient {
    /// Clients without streaming deliver the whole reply as one piece.
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(try await complete(request))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Where a model lives and which of its models each job uses.
struct LLMProvider: Sendable, Equatable {
    var name: String
    var baseURL: URL
    /// Keychain account holding the API key.
    var keychainAccount: String
    /// Translation and question spotting: fast and cheap.
    var fastModel: String
    /// Answering questions.
    var strongModel: String
    /// Extra top-level request fields, e.g. turning off DeepSeek's default thinking mode for low latency.
    var extraBody: [String: JSONValue] = [:]

    /// Model names from https://api-docs.deepseek.com/quick_start/pricing (checked 2026-11-02):
    /// `deepseek-flash` is DeepSeek-V4.1-Flash, `deepseek-v4-pro` is DeepSeek-V4-Pro.
    static let deepSeek: LLMProvider = {
        guard let baseURL = URL(string: "https://api.deepseek.com") else { preconditionFailure("constant URL is valid") }
        return LLMProvider(
            name: "DeepSeek",
            baseURL: baseURL,
            keychainAccount: "deepseek",
            fastModel: "deepseek-flash",
            strongModel: "deepseek-v4-pro",
            extraBody: ["thinking": .object(["type": .string("disabled")])]
        )
    }()
}

/// The small slice of JSON needed for extra request fields.
indirect enum JSONValue: Sendable, Equatable, Encodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
