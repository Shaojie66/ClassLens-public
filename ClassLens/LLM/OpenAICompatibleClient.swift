import Foundation

/// `POST {baseURL}/chat/completions` in the OpenAI format, which DeepSeek and most providers accept.
struct OpenAICompatibleClient: LLMClient {
    let provider: LLMProvider
    let apiKey: String
    var session: URLSession = .shared
    var timeout: TimeInterval = 20

    func complete(_ request: ChatRequest) async throws -> String {
        let (data, response) = try await session.data(for: urlRequest(for: request, stream: false))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Self.failure(status: status, data: data) }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard let content = reply.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw LLMFailure.emptyReply
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
        urlRequest.httpBody = try Self.body(for: request, extra: provider.extraBody, reasoningEffort: provider.reasoningEffort, stream: stream)
        return urlRequest
    }

    static func body(
        for request: ChatRequest,
        extra: [String: JSONValue],
        reasoningEffort: [String: String] = [:],
        stream: Bool = false
    ) throws -> Data {
        var fields: [String: JSONValue] = extra
        fields["model"] = .string(request.model)
        if let effort = reasoningEffort[request.model] {
            // OpenAI reasoning models reject `max_tokens`; their cap also covers the hidden reasoning.
            fields["reasoning_effort"] = .string(effort)
            let headroom = effort == "none" ? 0 : 4096
            fields["max_completion_tokens"] = .number(Double(request.maxTokens + headroom))
        } else {
            fields["temperature"] = .number(request.temperature)
            fields["max_tokens"] = .number(Double(request.maxTokens))
        }
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

    static func failure(status: Int, data: Data) -> LLMFailure {
        let error = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error
        switch status {
        case 401: return .invalidKey
        case 402: return .insufficientBalance
        // OpenAI answers an exhausted quota with 429 too; retrying would not help.
        case 429: return error?.code == "insufficient_quota" ? .insufficientBalance : .rateLimited
        default:
            return .server(status, error?.message ?? String(data: data.prefix(200), encoding: .utf8) ?? "")
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
        struct Detail: Decodable {
            var message: String
            var code: String?
        }
        var error: Detail
    }
}
