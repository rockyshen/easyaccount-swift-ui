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

    /// 一级分类在后端用 parent = -1 / null / 0 表示。
    var isRootLevel: Bool {
        guard let parent else { return true }
        return parent <= 0
    }
}

struct CreateTypeRequest: Encodable, Sendable {
    let tname: String
    let actionId: Int
    /// `-1` 表示一级分类。
    let parent: Int
}

struct UpdateTypeRequest: Encodable, Sendable {
    let tname: String
    let actionId: Int?
    let parent: Int?
}

enum TypeEditorMode: Equatable {
    case create
    case edit(TypeNodeDTO)
}

struct TypeEditorState: Identifiable, Equatable {
    let id = UUID()
    var mode: TypeEditorMode
    var name: String
    /// 新建时可选挂到某个一级分类下；`nil` 表示一级分类。
    var parentId: Int?

    init(mode: TypeEditorMode, parentId: Int? = nil) {
        self.mode = mode
        switch mode {
        case .create:
            self.name = ""
            self.parentId = parentId
        case .edit(let node):
            self.name = node.tName
            self.parentId = node.isRootLevel ? nil : node.parent
        }
    }

    var title: String {
        switch mode {
        case .create: return "新建分类"
        case .edit: return "编辑分类"
        }
    }
}

/// 列表展示用的扁平节点（便于每行右划/左划）。
struct FlatTypeRow: Identifiable, Equatable {
    let id: Int
    let node: TypeNodeDTO
    let depth: Int
}
