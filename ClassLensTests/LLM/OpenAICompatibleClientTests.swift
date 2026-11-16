import Foundation
import Testing
@testable import ClassLens

extension LLMClientTests {
    @Suite(.serialized)
    struct OpenAICompatibleClientTests {
        private func client() -> OpenAICompatibleClient {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubProtocol.self]
            return OpenAICompatibleClient(provider: .deepSeek, apiKey: "test-key", session: URLSession(configuration: configuration))
        }

        private let request = ChatRequest(model: "deepseek-flash", messages: [ChatMessage(role: .user, content: "hi")])

        @Test func sendsDeepSeekRequestWithThinkingOff() async throws {
            StubProtocol.status = 200
            StubProtocol.body = Data(#"{"choices":[{"message":{"role":"assistant","content":"  你好  "}}]}"#.utf8)
            let reply = try await client().complete(request)
            #expect(reply == "你好")

            let sent = try #require(StubProtocol.lastRequest)
            #expect(sent.url?.absoluteString == "https://api.deepseek.com/chat/completions")
            #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            let body = try #require(StubProtocol.lastBody)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["model"] as? String == "deepseek-flash")
            #expect((json["thinking"] as? [String: Any])?["type"] as? String == "disabled")
            #expect(json["stream"] as? Bool == false)
            #expect((json["messages"] as? [[String: String]])?.first?["content"] == "hi")
        }

        @Test(arguments: [
            (401, LLMFailure.invalidKey),
            (402, .insufficientBalance),
            (429, .rateLimited),
            (500, .server(500, "busy")),
        ])
        func mapsErrors(status: Int, expected: LLMFailure) async {
            StubProtocol.status = status
            StubProtocol.body = Data(#"{"error":{"message":"busy"}}"#.utf8)
            await #expect(throws: expected) { try await client().complete(request) }
        }

        @Test func sendsOpenAIReasoningRequests() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubProtocol.self]
            let openAI = OpenAICompatibleClient(provider: .openAI, apiKey: "test-key", session: URLSession(configuration: configuration))
            StubProtocol.status = 200
            StubProtocol.body = Data(#"{"choices":[{"message":{"role":"assistant","content":"好"}}]}"#.utf8)

            let fast = ChatRequest(model: "gpt-6-luna", messages: [ChatMessage(role: .user, content: "hi")], maxTokens: 300, jsonOutput: true)
            #expect(try await openAI.complete(fast) == "好")
            let sent = try #require(StubProtocol.lastRequest)
            #expect(sent.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
            var body = try #require(StubProtocol.lastBody)
            var json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["reasoning_effort"] as? String == "none")
            #expect(json["max_completion_tokens"] as? Int == 300)
            #expect(json["max_tokens"] == nil)
            #expect(json["temperature"] == nil)
            #expect((json["response_format"] as? [String: String])?["type"] == "json_object")

            let strong = ChatRequest(model: "gpt-6.1-sol", messages: [ChatMessage(role: .user, content: "hi")], maxTokens: 1000)
            _ = try await openAI.complete(strong)
            body = try #require(StubProtocol.lastBody)
            json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["reasoning_effort"] as? String == "low")
            #expect(json["max_completion_tokens"] as? Int == 1000 + 4096)
            #expect(json["temperature"] == nil)
        }

        @Test func deepSeekKeepsMaxTokensAndTemperature() throws {
            let body = try OpenAICompatibleClient.body(for: request, extra: LLMProvider.deepSeek.extraBody, reasoningEffort: LLMProvider.deepSeek.reasoningEffort)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["max_tokens"] as? Int == request.maxTokens)
            #expect(json["temperature"] != nil)
            #expect(json["reasoning_effort"] == nil)
            #expect(json["max_completion_tokens"] == nil)
        }

        @Test func exhaustedOpenAIQuotaIsABalanceError() async {
            StubProtocol.status = 429
            StubProtocol.body = Data(#"{"error":{"message":"You exceeded your current quota.","type":"insufficient_quota","code":"insufficient_quota"}}"#.utf8)
            await #expect(throws: LLMFailure.insufficientBalance) { try await client().complete(request) }
        }

        @Test func openAIIsSelectable() {
            #expect(LLMProvider.named("openai") == .openAI)
            #expect(LLMProvider.openAI.kind == .openAICompatible)
            #expect(LLMProvider.openAI.keychainAccount == "openai")
        }

        @Test func emptyContentIsAnError() async {
            StubProtocol.status = 200
            StubProtocol.body = Data(#"{"choices":[{"message":{"content":""}}]}"#.utf8)
            await #expect(throws: LLMFailure.emptyReply) { try await client().complete(request) }
        }
    }
}
