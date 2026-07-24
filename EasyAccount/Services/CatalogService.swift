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
}
