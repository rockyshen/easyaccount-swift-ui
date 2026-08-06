import Foundation
import UIKit

enum ChatMessageKind: String, Equatable, Codable {
    case system
    case assistant
    case user
    case error
}

struct ChatMessage: Identifiable, Equatable, Codable {
    let id: Int
    var kind: ChatMessageKind
    var text: String
    var streaming: Bool = false
    /// 已展示在对话中，等待上一轮 SSE 结束后再真正发往服务端。
    var pending: Bool = false
    /// 本地附件 JPEG（气泡缩略图）；SessionStore 旁路落盘，重启后回填。
    var attachmentJPEGs: [Data] = []

    enum CodingKeys: String, CodingKey {
        case id, kind, text, streaming, pending
    }

    init(
        id: Int,
        kind: ChatMessageKind,
        text: String,
        streaming: Bool = false,
        pending: Bool = false,
        attachmentJPEGs: [Data] = []
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.streaming = streaming
        self.pending = pending
        self.attachmentJPEGs = attachmentJPEGs
    }

    /// 附件 Data 不参与字节级相等判断，避免大图导致 diff 过重 / 列表异常刷新。
    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
            && lhs.kind == rhs.kind
            && lhs.text == rhs.text
            && lhs.streaming == rhs.streaming
            && lhs.pending == rhs.pending
            && lhs.attachmentJPEGs.count == rhs.attachmentJPEGs.count
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        kind = try container.decode(ChatMessageKind.self, forKey: .kind)
        text = try container.decode(String.self, forKey: .text)
        streaming = try container.decodeIfPresent(Bool.self, forKey: .streaming) ?? false
        pending = try container.decodeIfPresent(Bool.self, forKey: .pending) ?? false
        // 旧 UserDefaults JSON 无附件字段；磁盘回填见 SessionStore。
        attachmentJPEGs = []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(text, forKey: .text)
        try container.encode(streaming, forKey: .streaming)
        try container.encode(pending, forKey: .pending)
    }
}

/// 输入框待命区中的本地附件（发送前可增删预览）。
struct ChatDraftAttachment: Identifiable, Equatable {
    let id: UUID
    let image: UIImage

    static func == (lhs: ChatDraftAttachment, rhs: ChatDraftAttachment) -> Bool {
        lhs.id == rhs.id
    }
}

/// SSE `data:` JSON 载荷（与 event 名对应的 type 可作校验）。
struct ChatServerEvent: Decodable {
    let type: String?
    let content: String?
    let message: String?
    let streamId: String?
    let eventId: Int64?
    /// `resume` 可选字段，客户端可忽略。
    let afterEventId: Int64?
    let serverLastEventId: Int64?
    let status: String?

    private enum CodingKeys: String, CodingKey {
        case type, content, message, streamId, eventId
        case afterEventId, serverLastEventId, status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        streamId = try container.decodeIfPresent(String.self, forKey: .streamId)
        eventId = Self.decodeInt64(container, forKey: .eventId)
        afterEventId = Self.decodeInt64(container, forKey: .afterEventId)
        serverLastEventId = Self.decodeInt64(container, forKey: .serverLastEventId)
        status = try container.decodeIfPresent(String.self, forKey: .status)

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

    private static func decodeInt64(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int64? {
        if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Int64(value)
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key),
           let value = Int64(text) {
            return value
        }
        return nil
    }
}

/// POST `/api/chat` 在已有 running 流时的 409 体。
struct ChatBusyError: Decodable, Equatable {
    let message: String
    let streamId: String?
    let lastEventId: Int64?
    let status: String?

    private enum CodingKeys: String, CodingKey {
        case message, streamId, lastEventId, status
    }

    init(message: String, streamId: String? = nil, lastEventId: Int64? = nil, status: String? = nil) {
        self.message = message
        self.streamId = streamId
        self.lastEventId = lastEventId
        self.status = status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decodeIfPresent(String.self, forKey: .message)
            ?? "上一条消息仍在处理中"
        streamId = try container.decodeIfPresent(String.self, forKey: .streamId)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        if let value = try? container.decodeIfPresent(Int64.self, forKey: .lastEventId) {
            lastEventId = value
        } else if let value = try? container.decodeIfPresent(Int.self, forKey: .lastEventId) {
            lastEventId = Int64(value)
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .lastEventId),
                  let value = Int64(text) {
            lastEventId = value
        } else {
            lastEventId = nil
        }
    }
}

/// 未完成助手气泡的本地游标（建议随用户持久化）。
struct StreamingBubbleState: Codable, Equatable {
    var streamId: String
    var lastEventId: Int64
    var assistantText: String
    /// streaming | completed | failed
    var status: String
    /// 本地助手气泡 id，便于恢复时对齐。
    var messageId: Int?

    static let statusStreaming = "streaming"
    static let statusCompleted = "completed"
    static let statusFailed = "failed"
}

struct ChatOutbound: Encodable {
    let content: String
    /// 已上传附件 id；无附件时省略字段以兼容旧服务端。
    let attachmentIds: [String]?

    init(content: String, attachmentIds: [String]? = nil) {
        self.content = content
        if let attachmentIds, !attachmentIds.isEmpty {
            self.attachmentIds = attachmentIds
        } else {
            self.attachmentIds = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(content, forKey: .content)
        if let attachmentIds {
            try container.encode(attachmentIds, forKey: .attachmentIds)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case content, attachmentIds
    }
}

/// `POST /api/chat/attachments` 上传成功体。
struct ChatAttachmentDTO: Decodable, Equatable {
    let id: String
    let kind: String?
    let mimeType: String?
    let sizeBytes: Int?
    let width: Int?
    let height: Int?
    let url: String?
    let expiresAt: String?
    let createdAt: String?
}
