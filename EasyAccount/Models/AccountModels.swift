import Foundation

struct AccountDTO: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let money: String
    let exemptMoney: String
    let card: String?
    let createTime: String?
    let note: String?
    let accountType: Int
    let typeLabel: String?
    let usedMoney: String?

    var isCreditCard: Bool { accountType == 1 }

    var primaryAmountLabel: String {
        isCreditCard ? "可用额度" : "余额"
    }

    var secondarySummary: String? {
        if isCreditCard {
            let used = MoneyFormat.display(usedMoney)
            let limit = MoneyFormat.display(exemptMoney)
            return "已用 \(used) / 额度 \(limit)"
        }
        let exempt = MoneyFormat.decimal(from: exemptMoney)
        guard exempt > 0 else { return nil }
        return "豁免 \(MoneyFormat.display(exemptMoney))"
    }
}

struct CreateAccountRequest: Codable, Sendable {
    let name: String
    let initialMoney: String
    let card: String?
    let note: String?
    let accountType: Int
}

struct UpdateAccountRequest: Codable, Sendable {
    let name: String?
    let card: String?
    let note: String?
    let exemptMoney: String?
}

struct OkResponse: Codable, Sendable {
    let ok: Bool
}
