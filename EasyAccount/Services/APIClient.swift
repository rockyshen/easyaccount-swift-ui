import Foundation

enum APIClient {
    static func stripTrailingSlash(_ value: String) -> String {
        var raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        return raw
    }

    static func request(
        method: String,
        path: String,
        httpBase: String,
        token: String?,
        body: Data? = nil,
        query: [URLQueryItem]? = nil
    ) async throws -> Data {
        var components = URLComponents(string: "\(stripTrailingSlash(httpBase))\(path)")
        if let query, !query.isEmpty {
            components?.queryItems = query
        }
        guard let url = components?.url else {
            throw APIError(status: -1, message: "无效的服务地址")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if !(200..<300).contains(status) {
            let errorBody = try? JSONDecoder().decode(AuthErrorBody.self, from: data)
            let fallback: String
            switch status {
            case 401:
                fallback = "未登录或会话已失效"
            case 404:
                fallback = "接口不存在，请确认后端已部署对应能力"
            default:
                fallback = "请求失败（\(status)）"
            }
            throw APIError(status: status, message: errorBody?.message ?? fallback)
        }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
