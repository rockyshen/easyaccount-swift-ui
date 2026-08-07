import Foundation

/// 管理页缓存：账户短 TTL；分类/actions 变化少，长 TTL + 磁盘持久化。
@MainActor
enum ManagementCache {
    /// 账户：再次进入页面的软过期（下拉 / 增删改仍强制刷新）。
    static let accountsSoftTTL: TimeInterval = 120
    /// 分类与收支类型很少变，本地可多用一会儿。
    static let catalogSoftTTL: TimeInterval = 24 * 60 * 60

    /// 兼容旧调用点。
    static let softTTL: TimeInterval = accountsSoftTTL

    private(set) static var accounts: [AccountDTO] = []
    private static var accountsFetchedAt: Date?

    private(set) static var actions: [ActionDTO] = []
    private static var actionsFetchedAt: Date?

    private static var typesByActionId: [Int: [TypeNodeDTO]] = [:]
    private static var typesFetchedAt: [Int: Date] = [:]
    private static var didHydrateCatalog = false

    static func clear() {
        accounts = []
        accountsFetchedAt = nil
        actions = []
        actionsFetchedAt = nil
        typesByActionId = [:]
        typesFetchedAt = [:]
        didHydrateCatalog = false
        removeCatalogDisk()
    }

    // MARK: - Accounts

    static func hasAccountsCache(force: Bool) -> Bool {
        !force && !accounts.isEmpty && isFresh(accountsFetchedAt, ttl: accountsSoftTTL)
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

    /// 进入分类页前调用：内存空时从磁盘恢复，减少重复拉网。
    static func prepareCatalogIfNeeded() {
        guard !didHydrateCatalog else { return }
        didHydrateCatalog = true
        loadCatalogFromDisk()
    }

    static func hasActionsCache(force: Bool) -> Bool {
        prepareCatalogIfNeeded()
        return !force && !actions.isEmpty && isFresh(actionsFetchedAt, ttl: catalogSoftTTL)
    }

    static func setActions(_ list: [ActionDTO]) {
        actions = list
        actionsFetchedAt = Date()
        persistCatalogToDisk()
    }

    static func types(for actionId: Int) -> [TypeNodeDTO]? {
        prepareCatalogIfNeeded()
        return typesByActionId[actionId]
    }

    static func hasTypesCache(actionId: Int, force: Bool) -> Bool {
        prepareCatalogIfNeeded()
        guard !force, typesFetchedAt[actionId] != nil else { return false }
        // 允许空树也算命中（该 action 下确实无分类），避免反复打空接口。
        return isFresh(typesFetchedAt[actionId], ttl: catalogSoftTTL)
    }

    static func setTypes(_ list: [TypeNodeDTO], for actionId: Int) {
        typesByActionId[actionId] = list
        typesFetchedAt[actionId] = Date()
        persistCatalogToDisk()
    }

    static func invalidateTypes(for actionId: Int) {
        typesByActionId[actionId] = nil
        typesFetchedAt[actionId] = nil
        persistCatalogToDisk()
    }

    // MARK: - Freshness / disk

    private static func isFresh(_ date: Date?, ttl: TimeInterval) -> Bool {
        guard let date else { return false }
        return Date().timeIntervalSince(date) < ttl
    }

    private static func catalogDiskURL() -> URL? {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = root.appendingPathComponent("EasyAccount/CatalogCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(sanitizedUserId()).json")
    }

    private static func sanitizedUserId() -> String {
        if let id = SessionStore.getStoredUser()?.id?.trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty {
            return sanitize(id)
        }
        let name = SessionStore.getStoredUser()?.displayName ?? ""
        if !name.isEmpty { return sanitize("name:\(name)") }
        return "anonymous"
    }

    private static func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return mapped.isEmpty ? "anonymous" : mapped
    }

    private static func persistCatalogToDisk() {
        guard let url = catalogDiskURL() else { return }
        let payload = PersistedCatalogCache(
            actions: actions,
            actionsFetchedAt: actionsFetchedAt,
            typesByActionId: typesByActionId.mapKeys { String($0) },
            typesFetchedAt: typesFetchedAt.mapKeys { String($0) }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func loadCatalogFromDisk() {
        guard let url = catalogDiskURL(),
              let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let payload = try? decoder.decode(PersistedCatalogCache.self, from: data) else { return }
        actions = payload.actions
        actionsFetchedAt = payload.actionsFetchedAt
        typesByActionId = payload.typesByActionId.compactMapKeys { Int($0) }
        typesFetchedAt = payload.typesFetchedAt.compactMapKeys { Int($0) }
    }

    private static func removeCatalogDisk() {
        guard let url = catalogDiskURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

private struct PersistedCatalogCache: Codable {
    var actions: [ActionDTO]
    var actionsFetchedAt: Date?
    var typesByActionId: [String: [TypeNodeDTO]]
    var typesFetchedAt: [String: Date]
}

private extension Dictionary {
    func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] {
        var result: [T: Value] = [:]
        result.reserveCapacity(count)
        for (key, value) in self {
            result[transform(key)] = value
        }
        return result
    }

    func compactMapKeys<T: Hashable>(_ transform: (Key) -> T?) -> [T: Value] {
        var result: [T: Value] = [:]
        result.reserveCapacity(count)
        for (key, value) in self {
            if let mapped = transform(key) {
                result[mapped] = value
            }
        }
        return result
    }
}
