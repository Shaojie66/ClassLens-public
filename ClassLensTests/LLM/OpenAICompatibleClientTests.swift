import Foundation
import Testing
@testable import ClassLens

/// Answers every request with a canned response and remembers the last request.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            return data
        } ?? request.httpBody
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

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
        (401, OpenAICompatibleClient.Failure.invalidKey),
        (402, .insufficientBalance),
        (429, .rateLimited),
        (500, .server(500, "busy")),
    ])
    func mapsErrors(status: Int, expected: OpenAICompatibleClient.Failure) async {
        StubProtocol.status = status
        StubProtocol.body = Data(#"{"error":{"message":"busy"}}"#.utf8)
        await #expect(throws: expected) { try await client().complete(request) }
    }

    @Test func emptyContentIsAnError() async {
        StubProtocol.status = 200
        StubProtocol.body = Data(#"{"choices":[{"message":{"content":""}}]}"#.utf8)
        await #expect(throws: OpenAICompatibleClient.Failure.emptyReply) { try await client().complete(request) }
    }
}
