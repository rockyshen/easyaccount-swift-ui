import Foundation

struct ActionDTO: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let hName: String
    let exempt: Bool
    let handle: Int

    /// 后端实际返回 `hname`（文档写作 hName）。
    private enum CodingKeys: String, CodingKey {
        case id, exempt, handle
        case hName = "hname"
    }

    var handleLabel: String {
        switch handle {
        case 0: return "收入"
        case 1: return "支出"
        case 2: return "转账"
        default: return "其他"
        }
    }
}

struct TypeNodeDTO: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let tName: String
    let parent: Int?
    let childrenTypes: [TypeNodeDTO]?

    /// 后端实际返回 `tname`（文档写作 tName）。
    private enum CodingKeys: String, CodingKey {
        case id, parent, childrenTypes
        case tName = "tname"
    }

    var children: [TypeNodeDTO] {
        childrenTypes ?? []
    }
}
