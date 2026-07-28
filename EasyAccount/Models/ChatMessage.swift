import Foundation

enum ChatMessageKind: String, Equatable {
    case system
    case assistant
    case user
    case error
}

struct ChatMessage: Identifiable, Equatable {
    let id: Int
    var kind: ChatMessageKind
    var text: String
    var streaming: Bool = false
    /// 已展示在对话中，等待上一轮 SSE 结束后再真正发往服务端。
    var pending: Bool = false
}

/// SSE `data:` JSON 载荷（与 event 名对应的 type 可作校验）。
struct ChatServerEvent: Decodable {
    let type: String?
    let content: String?
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case type, content, message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        if let text = try? container.decodeIfPresent(String.self, forKey: .content) {
            content = text
        } else if let number = try? container.decodeIfPresent(Double.self, forKey: .content) {
            content = String(number)
        } else if let bool = try? container.decodeIfPresent(Bool.self, forKey: .content) {
            content = bool ? "true" : "false"
        } else {
            content = nil
        }
    }
}

struct ChatOutbound: Encodable {
    let content: String
}
