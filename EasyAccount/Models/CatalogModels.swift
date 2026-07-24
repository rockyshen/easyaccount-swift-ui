import Foundation

struct ActionDTO: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let hName: String
    let exempt: Bool
    let handle: Int

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

    var children: [TypeNodeDTO] {
        childrenTypes ?? []
    }
}
