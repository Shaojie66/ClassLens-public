import Foundation

enum LLMFailure: LocalizedError, Equatable {
    case missingKey(String)
    case invalidKey
    case insufficientBalance
    case rateLimited
    case server(Int, String)
    case emptyReply
    case refused

    var errorDescription: String? {
        switch self {
        case .missingKey(let provider): "还没有填写 \(provider) 的 API key，请到“设置”里填写。"
        case .invalidKey: "API key 无效，请到“设置”里检查。"
        case .insufficientBalance: "API 账户余额不足。"
        case .rateLimited: "请求太频繁，被限流了，稍后会自动重试。"
        case .server(let code, let message): "AI 服务返回错误 \(code)：\(message)"
        case .emptyReply: "AI 服务返回了空内容。"
        case .refused: "AI 服务拒绝回答这个请求。"
        }
    }
}
