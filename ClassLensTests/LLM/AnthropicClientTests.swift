import Foundation
import Testing
@testable import ClassLens

extension LLMClientTests {
    @Suite(.serialized)
    struct AnthropicClientTests {
        private let apiKey = UUID().uuidString
        private let request = ChatRequest(model: LLMProvider.claude.fastModel, messages: [ChatMessage(role: .user, content: "hi")])

        private func client() -> AnthropicClient {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubProtocol.self]
            return AnthropicClient(provider: .claude, apiKey: apiKey, session: URLSession(configuration: configuration))
        }

        private func body(_ request: ChatRequest, stream: Bool = false) throws -> [String: Any] {
            let data = try AnthropicClient.body(for: request, provider: .claude, stream: stream)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        @Test func fastModelDisablesThinkingAndOmitsSamplingParameters() throws {
            var request = request
            request.temperature = 0.8
            request.maxTokens = 400
            let json = try body(request)
            #expect(json["model"] as? String == LLMProvider.claude.fastModel)
            #expect((json["thinking"] as? [String: String])?["type"] == "disabled")
            #expect(json["max_tokens"] as? Int == 400)
            #expect(json["stream"] as? Bool == false)
            #expect(json["temperature"] == nil)
            #expect(json["top_p"] == nil)
            #expect(json["top_k"] == nil)
            #expect(json["output_config"] == nil)
            #expect(json["fallbacks"] == nil)
            #expect(json["response_format"] == nil)
        }

        @Test func strongModelAddsThinkingBudgetAndFallbacks() throws {
            var request = request
            request.model = LLMProvider.claude.strongModel
            request.temperature = 0.8
            request.maxTokens = 800
            let json = try body(request, stream: true)
            #expect(json["model"] as? String == LLMProvider.claude.strongModel)
            #expect(json["thinking"] == nil)
            #expect((json["output_config"] as? [String: String])?["effort"] == "low")
            #expect(json["max_tokens"] as? Int == 800 + 4096)
            #expect(json["fallbacks"] as? String == "default")
            #expect(json["stream"] as? Bool == true)
            #expect(json["temperature"] == nil)
            #expect(json["top_p"] == nil)
            #expect(json["top_k"] == nil)
        }

        @Test func hoistsAllSystemMessagesAndPreservesConversationOrder() throws {
            var request = request
            request.messages = [
                ChatMessage(role: .system, content: "First instruction"),
                ChatMessage(role: .user, content: "Question"),
                ChatMessage(role: .system, content: "Second instruction"),
                ChatMessage(role: .assistant, content: "Answer"),
                ChatMessage(role: .user, content: "Follow-up"),
            ]
            let json = try body(request)
            #expect(json["system"] as? String == "First instruction\n\nSecond instruction")
            #expect(json["messages"] as? [[String: String]] == [
                ["role": "user", "content": "Question"],
                ["role": "assistant", "content": "Answer"],
                ["role": "user", "content": "Follow-up"],
            ])
        }

        @Test func omitsSystemWhenThereAreNoSystemMessages() throws {
            #expect(try body(request)["system"] == nil)
        }

        @Test(arguments: [false, true])
        func jsonOutputAppendsInstructionWithOrWithoutExistingSystem(hasSystem: Bool) throws {
            var request = request
            request.jsonOutput = true
            if hasSystem { request.messages.insert(ChatMessage(role: .system, content: "Existing instruction"), at: 0) }
            let json = try body(request)
            let instruction = "Reply with a single JSON object and nothing else. Do not wrap it in a code fence."
            #expect(json["system"] as? String == (hasSystem ? "Existing instruction\n\n" : "") + instruction)
            #expect(json["response_format"] == nil)
            #expect((json["messages"] as? [[String: String]])?.count == 1)
        }

        @Test(arguments: [
            ("```json\n{\"ok\":true}\n```", "{\"ok\":true}"),
            ("```\n{\"ok\":true}\n```", "{\"ok\":true}"),
            ("  {\"ok\":true}\n", "{\"ok\":true}"),
            (" \n```json\r\n  {\"ok\":true}\r\n```\n ", "{\"ok\":true}"),
            ("```json\n\n```", ""),
            ("```json\n{\"ok\":true}", "```json\n{\"ok\":true}"),
            ("Before\n```\ntext\n```", "Before\n```\ntext\n```"),
        ])
        func stripsOnlySurroundingCodeFences(reply: String, expected: String) {
            #expect(AnthropicClient.stripCodeFence(reply) == expected)
        }

        @Test(arguments: [false, true])
        func sendsHeadersAndBetaOnlyForTheStrongModel(strong: Bool) async throws {
            StubProtocol.status = 200
            StubProtocol.body = Data(#"{"content":[{"type":"text","text":"你好"}]}"#.utf8)
            var request = request
            if strong { request.model = LLMProvider.claude.strongModel }
            #expect(try await client().complete(request) == "你好")
            let sent = try #require(StubProtocol.lastRequest)
            #expect(sent.url?.absoluteString == "https://api.anthropic.com/v1/messages")
            #expect(sent.httpMethod == "POST")
            #expect(sent.timeoutInterval == 30)
            #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(sent.value(forHTTPHeaderField: "x-api-key") == apiKey)
            #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
            #expect(sent.value(forHTTPHeaderField: "anthropic-beta") == (strong ? "server-side-fallback-2026-07-01" : nil))
            #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
            let data = try #require(StubProtocol.lastBody)
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["stream"] as? Bool == false)
            #expect(json["model"] as? String == request.model)
        }

        @Test func completeSkipsThinkingAndFallbackBlocksAndJoinsText() async throws {
            StubProtocol.status = 200
            StubProtocol.body = Data(#"{"content":[{"type":"thinking","thinking":"internal","text":"hidden"},{"type":"fallback"},{"type":"text","text":"  你"},{"type":"text","text":"好  "}],"stop_reason":"end_turn"}"#.utf8)
            #expect(try await client().complete(request) == "你好")
        }

        @Test func completeStripsCodeFencesOnlyWhenJSONIsRequested() async throws {
            StubProtocol.status = 200
            StubProtocol.body = Data(#"{"content":[{"type":"text","text":"```json\n{\"ok\":true}\n```"}]}"#.utf8)
            var request = request
            #expect(try await client().complete(request) == "```json\n{\"ok\":true}\n```")
            request.jsonOutput = true
            #expect(try await client().complete(request) == "{\"ok\":true}")
        }

        @Test(arguments: [
            #"{"content":[]}"#,
            #"{"content":[{"type":"thinking","thinking":"internal"}]}"#,
            #"{"content":[{"type":"text","text":" \n "}]}"#,
        ])
        func emptyContentIsAnError(response: String) async {
            StubProtocol.status = 200
            StubProtocol.body = Data(response.utf8)
            await #expect(throws: LLMFailure.emptyReply) { try await client().complete(request) }
        }

        @Test func emptyJSONFenceIsAnError() async {
            StubProtocol.status = 200
            StubProtocol.body = Data(#"{"content":[{"type":"text","text":"```json\n\n```"}]}"#.utf8)
            var request = request
            request.jsonOutput = true
            await #expect(throws: LLMFailure.emptyReply) { try await client().complete(request) }
        }

        @Test(arguments: [
            #"{"content":[],"stop_reason":"refusal"}"#,
            #"{"content":[{"type":"text","text":"Refused"}],"stop_reason":"refusal"}"#,
        ])
        func refusalTakesPriorityOverContent(response: String) async {
            StubProtocol.status = 200
            StubProtocol.body = Data(response.utf8)
            await #expect(throws: LLMFailure.refused) { try await client().complete(request) }
        }

        @Test(arguments: [
            (#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#, AnthropicClient.StreamLine.text("Hello")),
            (#"data: {"type":"message_stop"}"#, .done),
            (#"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#, .refused),
            (#"data: {"type":"error","error":{"type":"overloaded_error","message":"busy"}}"#, .failed("busy")),
            ("event: content_block_delta", .skip),
            (#"data: {"type":"ping"}"#, .skip),
            (#"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"internal"}}"#, .skip),
            (#"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":""}}"#, .skip),
            (#"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#, .skip),
            ("data: invalid JSON", .skip),
            ("", .skip),
        ])
        func parsesStreamLines(line: String, expected: AnthropicClient.StreamLine) {
            #expect(AnthropicClient.parseStreamLine(line) == expected)
        }

        @Test func streamsTextUntilMessageStop() async throws {
            StubProtocol.status = 200
            StubProtocol.body = Data("""
            event: content_block_delta
            data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"internal"}}

            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"你"}}

            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"好"}}

            data: {"type":"message_stop"}

            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"ignored"}}

            """.utf8)
            var pieces: [String] = []
            for try await piece in client().stream(request) { pieces.append(piece) }
            #expect(pieces == ["你", "好"])
            let data = try #require(StubProtocol.lastBody)
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["stream"] as? Bool == true)
        }

        @Test(arguments: [
            (#"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#, LLMFailure.refused),
            (#"{"type":"error","error":{"message":"busy"}}"#, .server(0, "busy")),
        ])
        func streamingErrorsFinishWithSharedFailure(event: String, expected: LLMFailure) async {
            StubProtocol.status = 200
            StubProtocol.body = Data("data: \(event)\n\n".utf8)
            await #expect(throws: expected) {
                for try await _ in client().stream(request) {}
            }
        }

        @Test(arguments: [
            (401, "invalid", LLMFailure.invalidKey),
            (429, "slow down", .rateLimited),
            (400, "Your CREDIT BALANCE is too low", .insufficientBalance),
            (403, "Insufficient credit balance", .insufficientBalance),
            (400, "invalid request", .server(400, "invalid request")),
            (403, "forbidden", .server(403, "forbidden")),
            (529, "overloaded", .server(529, "overloaded")),
        ])
        func mapsErrors(status: Int, message: String, expected: LLMFailure) throws {
            let data = try JSONSerialization.data(withJSONObject: ["type": "error", "error": ["type": "api_error", "message": message]])
            #expect(AnthropicClient.failure(status: status, data: data) == expected)
        }

        @Test func unknownErrorUsesTheFirst200Bytes() {
            let message = String(repeating: "x", count: 250)
            #expect(AnthropicClient.failure(status: 502, data: Data(message.utf8)) == .server(502, String(message.prefix(200))))
        }

        @Test func httpFailuresPropagateInCompleteAndStream() async {
            StubProtocol.status = 401
            StubProtocol.body = Data(#"{"type":"error","error":{"message":"invalid"}}"#.utf8)
            await #expect(throws: LLMFailure.invalidKey) { try await client().complete(request) }
            await #expect(throws: LLMFailure.invalidKey) {
                for try await _ in client().stream(request) {}
            }
        }

        @Test func findsProvidersByStableID() {
            #expect(LLMProvider.named("claude") == .claude)
            #expect(LLMProvider.named("deepseek") == .deepSeek)
            #expect(LLMProvider.named("nope") == nil)
            #expect(LLMProvider.all.map(\.id) == ["deepseek", "claude", "openai"])
            #expect(LLMProvider.deepSeek.kind == .openAICompatible)
            #expect(LLMProvider.claude.kind == .anthropic)
            #expect(LLMProvider.claude.keychainAccount == "anthropic")
            #expect(LLMProvider.claude.extraBody.isEmpty)
        }
    }
}
