import Foundation

/// 会话内内存缓存：账户 / 分类再次进入时先秒开，未过期则跳过网络。
@MainActor
enum ManagementCache {
    /// 新鲜数据在该时间内再次进入页面不发请求；下拉刷新 / 增删改仍强制刷新。
    static let softTTL: TimeInterval = 120

    private(set) static var accounts: [AccountDTO] = []
    private static var accountsFetchedAt: Date?

    private(set) static var actions: [ActionDTO] = []
    private static var actionsFetchedAt: Date?

    private static var typesByActionId: [Int: [TypeNodeDTO]] = [:]
    private static var typesFetchedAt: [Int: Date] = [:]

    static func clear() {
        accounts = []
        accountsFetchedAt = nil
        actions = []
        actionsFetchedAt = nil
        typesByActionId = [:]
        typesFetchedAt = [:]
    }

    // MARK: - Accounts

    static func hasAccountsCache(force: Bool) -> Bool {
        !force && !accounts.isEmpty && isFresh(accountsFetchedAt)
    }

    static func setAccounts(_ list: [AccountDTO]) {
        accounts = list
        accountsFetchedAt = Date()
    }

    static func upsertAccount(_ account: AccountDTO) {
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx] = account
        } else {
            accounts.insert(account, at: 0)
        }
        accountsFetchedAt = Date()
    }

    static func removeAccount(id: Int) {
        accounts.removeAll { $0.id == id }
        accountsFetchedAt = Date()
    }

    // MARK: - Actions / types

    static func hasActionsCache(force: Bool) -> Bool {
        !force && !actions.isEmpty && isFresh(actionsFetchedAt)
    }

    static func setActions(_ list: [ActionDTO]) {
        actions = list
        actionsFetchedAt = Date()
    }

    static func types(for actionId: Int) -> [TypeNodeDTO]? {
        typesByActionId[actionId]
    }

    static func hasTypesCache(actionId: Int, force: Bool) -> Bool {
        guard !force, let cached = typesByActionId[actionId], !cached.isEmpty || typesFetchedAt[actionId] != nil else {
            return false
        }
        return isFresh(typesFetchedAt[actionId])
    }

    static func setTypes(_ list: [TypeNodeDTO], for actionId: Int) {
        typesByActionId[actionId] = list
        typesFetchedAt[actionId] = Date()
    }

    private static func isFresh(_ date: Date?) -> Bool {
        guard let date else { return false }
        return Date().timeIntervalSince(date) < softTTL
    }
}
