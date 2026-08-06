import Foundation

enum SessionStore {
    private static let tokenKey = "easyaccount_agent_token"
    private static let userKey = "easyaccount_agent_user"
    private static let appearanceKey = "easyaccount_appearance_mode"
    private static let chatMessagesKeyPrefix = "easyaccount_chat_messages_"
    private static let streamingBubbleKeyPrefix = "easyaccount_streaming_bubble_"

    /// 会话文字清单目录（附件二进制在 ChatAttachmentCache）。
    private static let chatTranscriptFolder = "EasyAccount/ChatTranscripts"

    static func getStoredToken() -> String {
        UserDefaults.standard.string(forKey: tokenKey) ?? ""
    }

    static func getStoredUser() -> AuthUser? {
        guard let data = UserDefaults.standard.data(forKey: userKey) else { return nil }
        return try? JSONDecoder().decode(AuthUser.self, from: data)
    }

    static func persistSession(token: String?, user: AuthUser?) {
        if let token, !token.isEmpty {
            UserDefaults.standard.set(token, forKey: tokenKey)
        }
        if let user, let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: userKey)
        }
    }

    static func clearSession() {
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: userKey)
    }

    static func getAppearanceMode() -> AppearanceMode {
        guard let raw = UserDefaults.standard.string(forKey: appearanceKey),
              let mode = AppearanceMode(rawValue: raw) else {
            return .system
        }
        return mode
    }

    static func persistAppearanceMode(_ mode: AppearanceMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: appearanceKey)
    }

    // MARK: - Chat transcript

    static func persistChatMessages(_ messages: [ChatMessage], userId: String) {
        let dir = chatTranscriptDirectory(userId: userId)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return
        }

        let records: [PersistedChatMessage] = messages.map { message in
            PersistedChatMessage(
                id: message.id,
                kind: message.kind,
                text: message.text,
                pending: message.pending,
                attachments: message.attachments.map {
                    PersistedAttachmentRef(id: $0.id, remoteId: $0.remoteId)
                }
            )
        }

        let manifestURL = dir.appendingPathComponent("messages.json")
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: manifestURL, options: .atomic)

        // 清理旧版旁路大图文件名（att_{msg}_{i}.jpg），缩略图已迁到 AttachmentCache。
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for name in names where name.hasPrefix("att_") && name.hasSuffix(".jpg") {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }

        UserDefaults.standard.removeObject(forKey: chatMessagesKey(userId))
    }

    static func loadChatMessages(userId: String) -> [ChatMessage] {
        let dir = chatTranscriptDirectory(userId: userId)
        let manifestURL = dir.appendingPathComponent("messages.json")
        if let data = try? Data(contentsOf: manifestURL),
           let records = try? JSONDecoder().decode([PersistedChatMessage].self, from: data) {
            return records.map { record in
                let attachments = migrateAttachmentsIfNeeded(record: record, userId: userId, dir: dir)
                return ChatMessage(
                    id: record.id,
                    kind: record.kind,
                    text: record.text,
                    streaming: false,
                    pending: record.pending,
                    attachments: attachments
                )
            }
        }

        // 兼容：迁移旧 UserDefaults 纯文字会话。
        let key = chatMessagesKey(userId)
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([ChatMessage].self, from: data) else {
            return []
        }
        let migrated = list.map {
            ChatMessage(
                id: $0.id,
                kind: $0.kind,
                text: $0.text,
                streaming: false,
                pending: $0.pending,
                attachments: []
            )
        }
        if !migrated.isEmpty {
            persistChatMessages(migrated, userId: userId)
        }
        return migrated
    }

    static func clearChatMessages(userId: String) {
        UserDefaults.standard.removeObject(forKey: chatMessagesKey(userId))
        let dir = chatTranscriptDirectory(userId: userId)
        try? FileManager.default.removeItem(at: dir)
        ChatAttachmentCache.clearAll(userId: userId)
        clearStreamingBubble(userId: userId)
    }

    // MARK: - Incomplete SSE bubble (resume cursor)

    static func persistStreamingBubble(_ state: StreamingBubbleState?, userId: String) {
        let key = streamingBubbleKey(userId)
        guard let state else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func loadStreamingBubble(userId: String) -> StreamingBubbleState? {
        let key = streamingBubbleKey(userId)
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(StreamingBubbleState.self, from: data) else {
            return nil
        }
        return state
    }

    static func clearStreamingBubble(userId: String) {
        UserDefaults.standard.removeObject(forKey: streamingBubbleKey(userId))
    }

    // MARK: - Paths / migration

    private static func chatMessagesKey(_ userId: String) -> String {
        let safe = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        return chatMessagesKeyPrefix + (safe.isEmpty ? "anonymous" : safe)
    }

    private static func streamingBubbleKey(_ userId: String) -> String {
        let safe = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        return streamingBubbleKeyPrefix + (safe.isEmpty ? "anonymous" : safe)
    }

    private static func sanitizedUserId(_ userId: String) -> String {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed.isEmpty ? "anonymous" : trimmed
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(safe.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    private static func chatTranscriptDirectory(userId: String) -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent(chatTranscriptFolder, isDirectory: true)
            .appendingPathComponent(sanitizedUserId(userId), isDirectory: true)
    }

    /// 新清单用 attachments；旧清单 attachmentFiles 为大图旁路，迁移进缩略图/原图缓存。
    private static func migrateAttachmentsIfNeeded(
        record: PersistedChatMessage,
        userId: String,
        dir: URL
    ) -> [ChatMessageAttachment] {
        if let attachments = record.attachments, !attachments.isEmpty {
            return attachments.map {
                ChatMessageAttachment(id: $0.id, remoteId: $0.remoteId)
            }
        }
        guard let files = record.attachmentFiles, !files.isEmpty else { return [] }
        var migrated: [ChatMessageAttachment] = []
        for (index, name) in files.enumerated() {
            let url = dir.appendingPathComponent(name)
            guard let jpeg = try? Data(contentsOf: url), !jpeg.isEmpty else { continue }
            let localId = "migrated_\(record.id)_\(index)"
            ChatAttachmentCache.saveOriginal(userId: userId, id: localId, jpegData: jpeg)
            ChatAttachmentCache.saveThumbnail(userId: userId, id: localId, jpegData: jpeg)
            migrated.append(ChatMessageAttachment(id: localId, remoteId: nil))
            try? FileManager.default.removeItem(at: url)
        }
        return migrated
    }
}

/// 会话落盘清单：只存文字 + 附件 id 引用。
private struct PersistedChatMessage: Codable, Equatable {
    let id: Int
    let kind: ChatMessageKind
    let text: String
    let pending: Bool
    let attachments: [PersistedAttachmentRef]?
    /// 旧版：旁路大图文件名。
    let attachmentFiles: [String]?

    init(
        id: Int,
        kind: ChatMessageKind,
        text: String,
        pending: Bool,
        attachments: [PersistedAttachmentRef]
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.pending = pending
        self.attachments = attachments
        self.attachmentFiles = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        kind = try container.decode(ChatMessageKind.self, forKey: .kind)
        text = try container.decode(String.self, forKey: .text)
        pending = try container.decodeIfPresent(Bool.self, forKey: .pending) ?? false
        attachments = try container.decodeIfPresent([PersistedAttachmentRef].self, forKey: .attachments)
        attachmentFiles = try container.decodeIfPresent([String].self, forKey: .attachmentFiles)
    }
}

private struct PersistedAttachmentRef: Codable, Equatable {
    let id: String
    let remoteId: String?
}
