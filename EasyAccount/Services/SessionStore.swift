import Foundation

enum SessionStore {
    private static let tokenKey = "easyaccount_agent_token"
    private static let userKey = "easyaccount_agent_user"
    private static let appearanceKey = "easyaccount_appearance_mode"

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
}
