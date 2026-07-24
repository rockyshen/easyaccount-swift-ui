import Foundation

enum AccountService {
    static func list(httpBase: String, token: String) async throws -> [AccountDTO] {
        let data = try await APIClient.request(
            method: "GET",
            path: "/api/accounts",
            httpBase: httpBase,
            token: token
        )
        return try APIClient.decode([AccountDTO].self, from: data)
    }

    static func create(
        httpBase: String,
        token: String,
        request body: CreateAccountRequest
    ) async throws -> AccountDTO {
        let payload = try JSONEncoder().encode(body)
        let data = try await APIClient.request(
            method: "POST",
            path: "/api/accounts",
            httpBase: httpBase,
            token: token,
            body: payload
        )
        return try APIClient.decode(AccountDTO.self, from: data)
    }

    static func update(
        httpBase: String,
        token: String,
        id: Int,
        request body: UpdateAccountRequest
    ) async throws -> AccountDTO {
        let payload = try JSONEncoder().encode(body)
        let data = try await APIClient.request(
            method: "PUT",
            path: "/api/accounts/\(id)",
            httpBase: httpBase,
            token: token,
            body: payload
        )
        return try APIClient.decode(AccountDTO.self, from: data)
    }

    static func delete(httpBase: String, token: String, id: Int) async throws {
        let data = try await APIClient.request(
            method: "DELETE",
            path: "/api/accounts/\(id)",
            httpBase: httpBase,
            token: token
        )
        _ = try? APIClient.decode(OkResponse.self, from: data)
    }
}
