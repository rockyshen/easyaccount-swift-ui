import Foundation

enum SessionStore {
    private static let tokenKey = "easyaccount_agent_token"
    private static let userKey = "easyaccount_agent_user"
    private static let appearanceKey = "easyaccount_appearance_mode"
    private static let chatMessagesKeyPrefix = "easyaccount_chat_messages_"
    private static let streamingBubbleKeyPrefix = "easyaccount_streaming_bubble_"

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
        let key = chatMessagesKey(userId)
        // 落盘时去掉 streaming，避免恢复后假打字机状态。
        let snapshot = messages.map {
            ChatMessage(id: $0.id, kind: $0.kind, text: $0.text, streaming: false, pending: $0.pending)
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func loadChatMessages(userId: String) -> [ChatMessage] {
        let key = chatMessagesKey(userId)
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([ChatMessage].self, from: data) else {
            return []
        }
        return list.map {
            ChatMessage(id: $0.id, kind: $0.kind, text: $0.text, streaming: false, pending: $0.pending)
        }
    }

    static func clearChatMessages(userId: String) {
        UserDefaults.standard.removeObject(forKey: chatMessagesKey(userId))
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

    private static func chatMessagesKey(_ userId: String) -> String {
        let safe = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        return chatMessagesKeyPrefix + (safe.isEmpty ? "anonymous" : safe)
    }

    private static func streamingBubbleKey(_ userId: String) -> String {
        let safe = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        return streamingBubbleKeyPrefix + (safe.isEmpty ? "anonymous" : safe)
    }
}
