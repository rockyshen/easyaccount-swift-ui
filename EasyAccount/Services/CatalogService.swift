import Foundation

enum CatalogService {
    static func fetchActions(httpBase: String, token: String) async throws -> [ActionDTO] {
        let data = try await APIClient.request(
            method: "GET",
            path: "/api/actions",
            httpBase: httpBase,
            token: token
        )
        return try APIClient.decode([ActionDTO].self, from: data)
    }

    static func fetchTypes(httpBase: String, token: String, actionId: Int) async throws -> [TypeNodeDTO] {
        let data = try await APIClient.request(
            method: "GET",
            path: "/api/types",
            httpBase: httpBase,
            token: token,
            query: [URLQueryItem(name: "actionId", value: String(actionId))]
        )
        return try APIClient.decode([TypeNodeDTO].self, from: data)
    }

    static func createType(
        httpBase: String,
        token: String,
        request body: CreateTypeRequest
    ) async throws {
        let payload = try JSONEncoder().encode(body)
        // 代理层未开放 POST /api/types，创建走 /api/types/create。
        let data = try await APIClient.request(
            method: "POST",
            path: "/api/types/create",
            httpBase: httpBase,
            token: token,
            body: payload
        )
        _ = try? APIClient.decode(OkResponse.self, from: data)
    }

    static func updateType(
        httpBase: String,
        token: String,
        id: Int,
        request body: UpdateTypeRequest
    ) async throws {
        let payload = try JSONEncoder().encode(body)
        let data = try await APIClient.request(
            method: "PUT",
            path: "/api/types/\(id)",
            httpBase: httpBase,
            token: token,
            body: payload
        )
        _ = try? APIClient.decode(OkResponse.self, from: data)
    }

    static func deleteType(httpBase: String, token: String, id: Int) async throws {
        let data = try await APIClient.request(
            method: "DELETE",
            path: "/api/types/\(id)",
            httpBase: httpBase,
            token: token
        )
        _ = try? APIClient.decode(OkResponse.self, from: data)
    }
}
