import Foundation

/// 首次引导状态（register / login / me）；旧后端可无此字段。
struct OnboardingDTO: Codable, Equatable, Sendable {
    let needsOnboarding: Bool
    let hasAccounts: Bool
    let hasTypes: Bool
    let typesSeeded: Bool

    init(
        needsOnboarding: Bool,
        hasAccounts: Bool,
        hasTypes: Bool,
        typesSeeded: Bool
    ) {
        self.needsOnboarding = needsOnboarding
        self.hasAccounts = hasAccounts
        self.hasTypes = hasTypes
        self.typesSeeded = typesSeeded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        needsOnboarding = try container.decodeIfPresent(Bool.self, forKey: .needsOnboarding) ?? false
        hasAccounts = try container.decodeIfPresent(Bool.self, forKey: .hasAccounts) ?? false
        hasTypes = try container.decodeIfPresent(Bool.self, forKey: .hasTypes) ?? false
        typesSeeded = try container.decodeIfPresent(Bool.self, forKey: .typesSeeded) ?? hasTypes
    }
}

struct AuthUser: Codable, Equatable, Identifiable {
    var id: String?
    var name: String?

    var displayName: String {
        (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name
    }

    init(id: String?, name: String?) {
        self.id = id
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stringId = try? container.decodeIfPresent(String.self, forKey: .id) {
            id = stringId
        } else if let intId = try? container.decodeIfPresent(Int.self, forKey: .id) {
            id = String(intId)
        } else {
            id = nil
        }
        name = try container.decodeIfPresent(String.self, forKey: .name)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
    }
}

struct AuthSessionResponse: Codable {
    let token: String
    let user: AuthUser?
    /// 旧构建 / 未部署环境可能缺省。
    let onboarding: OnboardingDTO?
}

/// `GET /api/auth/me`：用户字段与 onboarding 平铺在同一对象。
struct AuthMeResponse: Codable {
    var id: String?
    var name: String?
    var onboarding: OnboardingDTO?

    var user: AuthUser {
        AuthUser(id: id, name: name)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, onboarding
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stringId = try? container.decodeIfPresent(String.self, forKey: .id) {
            id = stringId
        } else if let intId = try? container.decodeIfPresent(Int.self, forKey: .id) {
            id = String(intId)
        } else {
            id = nil
        }
        name = try container.decodeIfPresent(String.self, forKey: .name)
        onboarding = try container.decodeIfPresent(OnboardingDTO.self, forKey: .onboarding)
    }
}

struct AuthErrorBody: Codable {
    let message: String?
}

struct APIError: Error, LocalizedError {
    let status: Int
    let message: String

    var errorDescription: String? { message }
}
