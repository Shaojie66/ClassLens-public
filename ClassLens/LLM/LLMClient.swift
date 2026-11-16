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

/// A chat-completion endpoint. Implementations: OpenAI-compatible HTTP, Anthropic, fakes in tests.
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
    enum Kind: String, Sendable {
        case openAICompatible, anthropic
    }

    var name: String
    var id: String
    var baseURL: URL
    /// Keychain account holding the API key.
    var keychainAccount: String
    /// Translation and question spotting: fast and cheap.
    var fastModel: String
    /// Answering questions.
    var strongModel: String
    var kind: Kind = .openAICompatible
    var keyPlaceholder: String
    var fastModelNote: String
    /// Extra top-level request fields, e.g. turning off DeepSeek's default thinking mode for low latency.
    var extraBody: [String: JSONValue] = [:]
    /// `reasoning_effort` per model for OpenAI reasoning models. A model listed here is sent
    /// `max_completion_tokens` instead of `max_tokens` and no `temperature`.
    var reasoningEffort: [String: String] = [:]

    /// Model names from https://api-docs.deepseek.com/quick_start/pricing (checked 2026-11-02):
    /// `deepseek-flash` is DeepSeek-V4.1-Flash, `deepseek-v4-pro` is DeepSeek-V4-Pro.
    static let deepSeek: LLMProvider = {
        guard let baseURL = URL(string: "https://api.deepseek.com") else { preconditionFailure("constant URL is valid") }
        return LLMProvider(
            name: "DeepSeek",
            id: "deepseek",
            baseURL: baseURL,
            keychainAccount: "deepseek",
            fastModel: "deepseek-flash",
            strongModel: "deepseek-v4-pro",
            keyPlaceholder: "sk-…",
            fastModelNote: "关闭思考模式",
            extraBody: ["thinking": .object(["type": .string("disabled")])]
        )
    }()

    static let claude: LLMProvider = {
        guard let baseURL = URL(string: "https://api.anthropic.com") else { preconditionFailure("constant URL is valid") }
        return LLMProvider(
            name: "Claude",
            id: "claude",
            baseURL: baseURL,
            keychainAccount: "anthropic",
            fastModel: "claude-haiku-5-5",
            strongModel: "claude-opus-5-5",
            kind: .anthropic,
            keyPlaceholder: "sk-ant-…",
            fastModelNote: "关闭思考"
        )
    }()

    /// Model names and reasoning levels from https://developers.openai.com/api/docs/models (checked 2026-11-16):
    /// `gpt-6-luna` is the cheapest and accepts `reasoning_effort: none`; `gpt-6.1-sol` starts at `low`.
    static let openAI: LLMProvider = {
        guard let baseURL = URL(string: "https://api.openai.com/v1") else { preconditionFailure("constant URL is valid") }
        return LLMProvider(
            name: "OpenAI",
            id: "openai",
            baseURL: baseURL,
            keychainAccount: "openai",
            fastModel: "gpt-6-luna",
            strongModel: "gpt-6.1-sol",
            keyPlaceholder: "sk-proj-…",
            fastModelNote: "关闭推理",
            reasoningEffort: ["gpt-6-luna": "none", "gpt-6.1-sol": "low"]
        )
    }()

    static let all: [LLMProvider] = [.deepSeek, .claude, .openAI]

    static func named(_ id: String) -> LLMProvider? {
        all.first { $0.id == id }
    }

    /// Reads the selected provider's key without persisting it outside the keychain.
    func loadClient() throws -> any LLMClient {
        guard let key = Keychain.read(keychainAccount) else { throw LLMFailure.missingKey(name) }
        switch kind {
        case .openAICompatible: return OpenAICompatibleClient(provider: self, apiKey: key)
        case .anthropic: return AnthropicClient(provider: self, apiKey: key)
        }
    }
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
