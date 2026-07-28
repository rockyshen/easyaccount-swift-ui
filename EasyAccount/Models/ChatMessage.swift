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
}

/// SSE `data:` JSON 载荷（与 event 名对应的 type 可作校验）。
struct ChatServerEvent: Decodable {
    let type: String
    let content: String?
    let message: String?
}

struct ChatOutbound: Encodable {
    let content: String
}
