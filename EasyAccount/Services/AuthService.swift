import Foundation

enum AuthService {
    private static func stripTrailingSlash(_ value: String) -> String {
        var raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        return raw
    }

    static func httpBaseFromWs(_ wsUrl: String) -> String {
        let raw = stripTrailingSlash(wsUrl)
        if raw.isEmpty { return AppConfig.defaultHttpURL }
        if raw.hasPrefix("wss://") { return "https://" + raw.dropFirst(6) }
        if raw.hasPrefix("ws://") { return "http://" + raw.dropFirst(5) }
        if raw.hasPrefix("https://") || raw.hasPrefix("http://") { return raw }
        return raw
    }

    static func resolveHttpBase(httpUrl: String?, wsUrl: String) -> String {
        let explicit = stripTrailingSlash(httpUrl ?? "")
        if !explicit.isEmpty { return explicit }
        return httpBaseFromWs(wsUrl)
    }

    static func buildChatWsUrl(wsUrl: String, token: String) -> URL? {
        let base = stripTrailingSlash(wsUrl)
        let fallback = base.isEmpty ? AppConfig.defaultWsURL : base
        var components = URLComponents(string: "\(fallback)/ws")
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        return components?.url
    }

    static func login(httpBase: String, name: String, password: String) async throws -> AuthSessionResponse {
        try await postAuth(path: "/api/auth/login", httpBase: httpBase, name: name, password: password, fallback: "登录失败")
    }

    static func register(httpBase: String, name: String, password: String) async throws -> AuthSessionResponse {
        try await postAuth(path: "/api/auth/register", httpBase: httpBase, name: name, password: password, fallback: "注册失败")
    }

    static func fetchMe(httpBase: String, token: String) async throws -> AuthUser {
        guard let url = URL(string: "\(stripTrailingSlash(httpBase))/api/auth/me") else {
            throw APIError(status: -1, message: "无效的服务地址")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if !(200..<300).contains(status) {
            let body = try? JSONDecoder().decode(AuthErrorBody.self, from: data)
            throw APIError(status: status, message: body?.message ?? "未登录或会话已失效")
        }
        return try JSONDecoder().decode(AuthUser.self, from: data)
    }

    static func logout(httpBase: String, token: String) async {
        guard !token.isEmpty, let url = URL(string: "\(stripTrailingSlash(httpBase))/api/auth/logout") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func postAuth(
        path: String,
        httpBase: String,
        name: String,
        password: String,
        fallback: String
    ) async throws -> AuthSessionResponse {
        guard let url = URL(string: "\(stripTrailingSlash(httpBase))\(path)") else {
            throw APIError(status: -1, message: "无效的服务地址")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["name": name, "password": password])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if !(200..<300).contains(status) {
            let body = try? JSONDecoder().decode(AuthErrorBody.self, from: data)
            let message: String
            if path.contains("register") {
                if status == 409 {
                    message = body?.message ?? "用户名已存在"
                } else if status == 400 {
                    message = body?.message ?? "参数不正确"
                } else {
                    message = body?.message ?? fallback
                }
            } else {
                message = body?.message ?? fallback
            }
            throw APIError(status: status, message: message)
        }
        return try JSONDecoder().decode(AuthSessionResponse.self, from: data)
    }
}
