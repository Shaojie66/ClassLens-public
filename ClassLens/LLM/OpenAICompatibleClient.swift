import Foundation

/// `POST {baseURL}/chat/completions` in the OpenAI format, which DeepSeek and most providers accept.
struct OpenAICompatibleClient: LLMClient {
    enum Failure: LocalizedError, Equatable {
        case missingKey(String)
        case invalidKey
        case insufficientBalance
        case rateLimited
        case server(Int, String)
        case emptyReply

        var errorDescription: String? {
            switch self {
            case .missingKey(let provider): "还没有填写 \(provider) 的 API key，请到“设置”里填写。"
            case .invalidKey: "API key 无效，请到“设置”里检查。"
            case .insufficientBalance: "API 账户余额不足。"
            case .rateLimited: "请求太频繁，被限流了，稍后会自动重试。"
            case .server(let code, let message): "AI 服务返回错误 \(code)：\(message)"
            case .emptyReply: "AI 服务返回了空内容。"
            }
        }
    }

    let provider: LLMProvider
    let apiKey: String
    var session: URLSession = .shared
    var timeout: TimeInterval = 20

    /// Reads the key from the keychain; throws `missingKey` if none is saved.
    static func load(_ provider: LLMProvider) throws -> OpenAICompatibleClient {
        guard let key = Keychain.read(provider.keychainAccount) else { throw Failure.missingKey(provider.name) }
        return OpenAICompatibleClient(provider: provider, apiKey: key)
    }

    func complete(_ request: ChatRequest) async throws -> String {
        let (data, response) = try await session.data(for: urlRequest(for: request, stream: false))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Self.failure(status: status, data: data) }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard let content = reply.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw Failure.emptyReply
        }
        return content
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: urlRequest(for: request, stream: true))
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        throw Self.failure(status: status, data: data)
                    }
                    for try await line in bytes.lines {
                        switch Self.parseStreamLine(line) {
                        case .text(let piece): continuation.yield(piece)
                        case .done: continuation.finish(); return
                        case .skip: continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    enum StreamLine: Equatable {
        case text(String)
        case done
        case skip
    }

    /// Reads one server-sent-events line: `data: {json}` with `choices[0].delta.content`, or `data: [DONE]`.
    static func parseStreamLine(_ line: String) -> StreamLine {
        guard line.hasPrefix("data:") else { return .skip }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: Data(payload.utf8)),
              let piece = chunk.choices.first?.delta.content, !piece.isEmpty else { return .skip }
        return .text(piece)
    }

    private func urlRequest(for request: ChatRequest, stream: Bool) throws -> URLRequest {
        var urlRequest = URLRequest(url: provider.baseURL.appending(path: "chat/completions"), timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try Self.body(for: request, extra: provider.extraBody, stream: stream)
        return urlRequest
    }

    static func body(for request: ChatRequest, extra: [String: JSONValue], stream: Bool = false) throws -> Data {
        var fields: [String: JSONValue] = extra
        fields["model"] = .string(request.model)
        fields["temperature"] = .number(request.temperature)
        fields["max_tokens"] = .number(Double(request.maxTokens))
        fields["stream"] = .bool(stream)
        if request.jsonOutput {
            fields["response_format"] = .object(["type": .string("json_object")])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var object = try JSONSerialization.jsonObject(with: encoder.encode(fields)) as? [String: Any] ?? [:]
        object["messages"] = request.messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }

    static func failure(status: Int, data: Data) -> Failure {
        switch status {
        case 401: return .invalidKey
        case 402: return .insufficientBalance
        case 429: return .rateLimited
        default:
            let message = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error.message
                ?? String(data: data.prefix(200), encoding: .utf8) ?? ""
            return .server(status, message)
        }
    }

    private struct Reply: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message
        }
        var choices: [Choice]
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { var content: String? }
            var delta: Delta
        }
        var choices: [Choice]
    }

    private struct ErrorReply: Decodable {
        struct Detail: Decodable { var message: String }
        var error: Detail
    }
}
