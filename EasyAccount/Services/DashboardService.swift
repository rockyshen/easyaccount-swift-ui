import Foundation

enum DashboardService {
    static func fetch(httpBase: String, token: String) async throws -> DashboardDTO {
        let data = try await APIClient.request(
            method: "GET",
            path: "/api/dashboard",
            httpBase: httpBase,
            token: token
        )
        return try APIClient.decode(DashboardDTO.self, from: data)
    }
}
