import Foundation

enum SessionStore {
    private static let tokenKey = "easyaccount_agent_token"
    private static let userKey = "easyaccount_agent_user"
    private static let appearanceKey = "easyaccount_appearance_mode"
    private static let chatMessagesKeyPrefix = "easyaccount_chat_messages_"
    private static let streamingBubbleKeyPrefix = "easyaccount_streaming_bubble_"

    /// 会话清单 + 附件 JPEG 旁路目录（避免把大图塞进 UserDefaults）。
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

        var records: [PersistedChatMessage] = []
        var keptFiles = Set<String>()
        records.reserveCapacity(messages.count)

        for message in messages {
            var fileNames: [String] = []
            fileNames.reserveCapacity(message.attachmentJPEGs.count)
            for (index, jpeg) in message.attachmentJPEGs.enumerated() {
                let name = attachmentFileName(messageId: message.id, index: index)
                let url = dir.appendingPathComponent(name)
                // 消息附件发送后不变：已有文件则跳过，避免流式落盘反复写大图。
                if !FileManager.default.fileExists(atPath: url.path) {
                    guard (try? jpeg.write(to: url, options: .atomic)) != nil else { continue }
                }
                fileNames.append(name)
                keptFiles.insert(name)
            }
            records.append(
                PersistedChatMessage(
                    id: message.id,
                    kind: message.kind,
                    text: message.text,
                    pending: message.pending,
                    attachmentFiles: fileNames
                )
            )
        }

        let manifestURL = dir.appendingPathComponent("messages.json")
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: manifestURL, options: .atomic)

        // 清理已删除消息留下的孤儿附件。
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for name in names where name.hasPrefix("att_") && name.hasSuffix(".jpg") && !keptFiles.contains(name) {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }

        // 旧版只存文字的 UserDefaults 记录作废，避免恢复时读到无附件副本。
        UserDefaults.standard.removeObject(forKey: chatMessagesKey(userId))
    }

    static func loadChatMessages(userId: String) -> [ChatMessage] {
        let dir = chatTranscriptDirectory(userId: userId)
        let manifestURL = dir.appendingPathComponent("messages.json")
        if let data = try? Data(contentsOf: manifestURL),
           let records = try? JSONDecoder().decode([PersistedChatMessage].self, from: data) {
            return records.map { record in
                let jpegs: [Data] = record.attachmentFiles.compactMap { name in
                    try? Data(contentsOf: dir.appendingPathComponent(name))
                }
                return ChatMessage(
                    id: record.id,
                    kind: record.kind,
                    text: record.text,
                    streaming: false,
                    pending: record.pending,
                    attachmentJPEGs: jpegs
                )
            }
        }

        // 兼容：迁移旧 UserDefaults 纯文字会话（无附件）。
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
                attachmentJPEGs: []
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

    // MARK: - Paths

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

    private static func attachmentFileName(messageId: Int, index: Int) -> String {
        "att_\(messageId)_\(index).jpg"
    }
}

/// 会话落盘清单：文字进 JSON，图片用旁路文件名引用。
private struct PersistedChatMessage: Codable, Equatable {
    let id: Int
    let kind: ChatMessageKind
    let text: String
    let pending: Bool
    let attachmentFiles: [String]

    init(id: Int, kind: ChatMessageKind, text: String, pending: Bool, attachmentFiles: [String]) {
        self.id = id
        self.kind = kind
        self.text = text
        self.pending = pending
        self.attachmentFiles = attachmentFiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        kind = try container.decode(ChatMessageKind.self, forKey: .kind)
        text = try container.decode(String.self, forKey: .text)
        pending = try container.decodeIfPresent(Bool.self, forKey: .pending) ?? false
        attachmentFiles = try container.decodeIfPresent([String].self, forKey: .attachmentFiles) ?? []
    }
}
