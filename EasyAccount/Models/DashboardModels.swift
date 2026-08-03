import Foundation

struct DashboardDTO: Codable, Equatable, Sendable {
    let totalAsset: String
    let netAsset: String
    let curIncome: String?
    let curOutCome: String?
    /// 本月结余；后端补齐前可能缺省，见 docs/dashboard-monthly-balance-handoff.md。
    let curBalance: String?
    let yearIncome: String?
    let yearOutCome: String?
    let yearBalance: String?
    let accounts: [DashboardAccountDTO]?
    let monthDetails: [DashboardMonthDTO]?
}

struct DashboardAccountDTO: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let accountName: String
    let accountAsset: String
    let exemptAsset: String?
    let percent: String?
    let note: String?
}

struct DashboardMonthDTO: Codable, Equatable, Sendable {
    let month: String?
    let income: String?
    let outcome: String?
    let balance: String?
}
