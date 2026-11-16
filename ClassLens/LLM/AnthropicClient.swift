import Foundation

/// `POST {baseURL}/v1/messages` in Anthropic's Messages format.
struct AnthropicClient: LLMClient {
    let provider: LLMProvider
    let apiKey: String
    var session: URLSession = .shared
    var timeout: TimeInterval = 30

    func complete(_ request: ChatRequest) async throws -> String {
        let (data, response) = try await session.data(for: urlRequest(for: request, stream: false))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Self.failure(status: status, data: data) }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        if reply.stop_reason == "refusal" { throw LLMFailure.refused }
        let text = (reply.content ?? []).filter { $0.type == "text" }.compactMap(\.text).joined()
        let content = request.jsonOutput ? Self.stripCodeFence(text) : text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw LLMFailure.emptyReply }
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
                        case .refused: throw LLMFailure.refused
                        case .failed(let message): throw LLMFailure.server(0, message)
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
        case refused
        case failed(String)
        case skip
    }

    /// Only text deltas are visible; thinking and fallback events remain internal to the service.
    static func parseStreamLine(_ line: String) -> StreamLine {
        guard line.hasPrefix("data:") else { return .skip }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: Data(payload.utf8)) else { return .skip }
        switch chunk.type {
        case "content_block_delta":
            guard chunk.delta?.type == "text_delta", let text = chunk.delta?.text, !text.isEmpty else { return .skip }
            return .text(text)
        case "message_stop": return .done
        case "message_delta" where chunk.delta?.stop_reason == "refusal": return .refused
        case "error": return .failed(chunk.error?.message ?? "")
        default: return .skip
        }
    }

    private func urlRequest(for request: ChatRequest, stream: Bool) throws -> URLRequest {
        var urlRequest = URLRequest(url: provider.baseURL.appending(path: "v1/messages"), timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if request.model != provider.fastModel {
            urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = try Self.body(for: request, provider: provider, stream: stream)
        return urlRequest
    }

    static func body(for request: ChatRequest, provider: LLMProvider, stream: Bool = false) throws -> Data {
        var fields: [String: Any] = [
            "model": request.model,
            "stream": stream,
            "messages": request.messages.filter { $0.role != .system }.map { ["role": $0.role.rawValue, "content": $0.content] },
        ]
        var system = request.messages.filter { $0.role == .system }.map(\.content)
        if request.jsonOutput {
            system.append("Reply with a single JSON object and nothing else. Do not wrap it in a code fence.")
        }
        if !system.isEmpty { fields["system"] = system.joined(separator: "\n\n") }
        if request.model == provider.fastModel {
            fields["thinking"] = ["type": "disabled"]
            fields["max_tokens"] = request.maxTokens
        } else {
            fields["output_config"] = ["effort": "low"]
            fields["max_tokens"] = request.maxTokens + 4096
            fields["fallbacks"] = "default"
        }
        return try JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)
    }

    /// Removes a surrounding JSON or plain Markdown fence, preserving unfenced replies.
    static func stripCodeFence(_ reply: String) -> String {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2,
              let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              first == "```json" || first == "```",
              lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" else { return text }
        return lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func failure(status: Int, data: Data) -> LLMFailure {
        let message = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error.message
            ?? String(data: data.prefix(200), encoding: .utf8) ?? ""
        switch status {
        case 401: return .invalidKey
        case 429: return .rateLimited
        case 400, 403:
            return message.localizedCaseInsensitiveContains("credit balance") ? .insufficientBalance : .server(status, message)
        default: return .server(status, message)
        }
    }

    private struct Reply: Decodable {
        struct Block: Decodable {
            var type: String
            var text: String?
        }
        var content: [Block]?
        var stop_reason: String?
    }

    private struct StreamChunk: Decodable {
        struct Delta: Decodable {
            var type: String?
            var text: String?
            var stop_reason: String?
        }
        var type: String
        var delta: Delta?
        var error: ErrorReply.Detail?
    }

    private struct ErrorReply: Decodable {
        struct Detail: Decodable { var message: String }
        var error: Detail
    }
}
