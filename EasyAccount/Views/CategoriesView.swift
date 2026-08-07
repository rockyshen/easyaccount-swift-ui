import SwiftUI

@MainActor
final class CategoriesViewModel: ObservableObject {
    @Published var actions: [ActionDTO] = []
    @Published var selectedActionId: Int?
    @Published var types: [TypeNodeDTO] = []
    /// 已展开的父分类 id；默认空 = 只显示父级。
    @Published var expandedParentIds: Set<Int> = []
    @Published var loadingActions = false
    @Published var loadingTypes = false
    @Published var saving = false
    @Published var errorMessage = ""
    @Published var editor: TypeEditorState?

    private let httpBase: () -> String
    private let token: () -> String
    private let onUnauthorized: (String) -> Void
    private let onToast: (String) -> Void

    init(
        httpBase: @escaping () -> String,
        token: @escaping () -> String,
        onUnauthorized: @escaping (String) -> Void,
        onToast: @escaping (String) -> Void
    ) {
        self.httpBase = httpBase
        self.token = token
        self.onUnauthorized = onUnauthorized
        self.onToast = onToast
    }

    /// 一级分类，供新建时选择父级。
    var rootTypes: [TypeNodeDTO] {
        types.filter(\.isRootLevel)
    }

    /// 仅展示常用三项：收入 / 支出 / 内部转账（按名称匹配，id 来自 `/api/actions`）。
    var visibleActions: [ActionDTO] {
        let preferredTitles = ["收入", "支出", "内部转账"]
        return preferredTitles.compactMap { title in
            actions.first { action in
                let name = action.normalizedName
                if title == "内部转账" {
                    return name == "内部转账" || name.contains("内部转账")
                }
                return name == title
            }
        }
    }

    /// 扁平化树：默认只出父级；展开后带出其子节点。
    var flatRows: [FlatTypeRow] {
        var rows: [FlatTypeRow] = []
        for node in types where node.isRootLevel {
            let hasChildren = !node.children.isEmpty
            rows.append(
                FlatTypeRow(
                    id: node.id,
                    node: node,
                    depth: 0,
                    hasChildren: hasChildren,
                    isExpanded: expandedParentIds.contains(node.id)
                )
            )
            if hasChildren, expandedParentIds.contains(node.id) {
                for child in node.children {
                    rows.append(
                        FlatTypeRow(
                            id: child.id,
                            node: child,
                            depth: 1,
                            hasChildren: false,
                            isExpanded: false
                        )
                    )
                }
            }
        }
        // 若后端偶发未标 parent 但仍挂在根数组，保持兼容：非根且无父展示的节点不单独列出。
        return rows
    }

    func toggleExpanded(parentId: Int) {
        if expandedParentIds.contains(parentId) {
            expandedParentIds.remove(parentId)
        } else {
            expandedParentIds.insert(parentId)
        }
    }

    func loadActions(force: Bool = false) async {
        ManagementCache.prepareCatalogIfNeeded()
        if !ManagementCache.actions.isEmpty {
            actions = ManagementCache.actions
            ensureValidSelectedAction()
            if let actionId = selectedActionId, let cachedTypes = ManagementCache.types(for: actionId) {
                types = cachedTypes
            }
        }

        if ManagementCache.hasActionsCache(force: force) {
            errorMessage = ""
            if let actionId = selectedActionId {
                await loadTypes(actionId: actionId, force: force)
            }
            return
        }

        let showSpinner = actions.isEmpty
        if showSpinner {
            loadingActions = true
        }
        errorMessage = ""
        defer { if showSpinner { loadingActions = false } }

        do {
            let list = try await CatalogService.fetchActions(httpBase: httpBase(), token: token())
            ManagementCache.setActions(list)
            actions = list
            ensureValidSelectedAction()
            if let actionId = selectedActionId {
                await loadTypes(actionId: actionId, force: force)
            }
        } catch let error as APIError where error.status == 401 {
            onUnauthorized(error.message)
        } catch let error as APIError {
            if actions.isEmpty {
                errorMessage = error.message
            }
        } catch {
            if actions.isEmpty {
                errorMessage = "加载收支类型失败"
            }
        }
    }

    /// 切换收入/支出/内部转账 Tab：用 `/api/actions` 返回的真实 id 再拉 `/api/types`。
    func selectAction(_ actionId: Int) async {
        guard visibleActions.contains(where: { $0.id == actionId }) else { return }
        guard selectedActionId != actionId else { return }
        selectedActionId = actionId
        errorMessage = ""
        expandedParentIds = []
        types = ManagementCache.types(for: actionId) ?? []
        await loadTypes(actionId: actionId, force: false)
    }

    func openCreate() {
        guard selectedActionId != nil else {
            onToast("分类数据尚未就绪，请稍后重试")
            return
        }
        editor = TypeEditorState(mode: .create)
    }

    func openEdit(_ node: TypeNodeDTO) {
        editor = TypeEditorState(mode: .edit(node))
    }

    func saveEditor() async {
        guard let editor else { return }
        guard let actionId = selectedActionId else {
            onToast("分类数据尚未就绪，请稍后重试")
            return
        }
        let name = editor.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            onToast("请输入分类名")
            return
        }

        saving = true
        defer { saving = false }

        do {
            switch editor.mode {
            case .create:
                let body = CreateTypeRequest(
                    tname: name,
                    actionId: actionId,
                    parent: editor.parentId ?? -1
                )
                try await CatalogService.createType(httpBase: httpBase(), token: token(), request: body)
                onToast("分类已创建")
            case .edit(let node):
                let body = UpdateTypeRequest(
                    tname: name,
                    actionId: actionId,
                    parent: editor.parentId ?? -1
                )
                try await CatalogService.updateType(
                    httpBase: httpBase(),
                    token: token(),
                    id: node.id,
                    request: body
                )
                onToast("分类已更新")
            }
            self.editor = nil
            await reloadTypes(actionId: actionId)
        } catch let error as APIError where error.status == 401 {
            onUnauthorized(error.message)
        } catch let error as APIError {
            onToast(error.message)
        } catch {
            onToast("保存分类失败")
        }
    }

    func delete(_ node: TypeNodeDTO) async {
        guard let actionId = selectedActionId else { return }
        do {
            try await CatalogService.deleteType(httpBase: httpBase(), token: token(), id: node.id)
            onToast("分类已删除")
            await reloadTypes(actionId: actionId)
        } catch let error as APIError where error.status == 401 {
            onUnauthorized(error.message)
        } catch let error as APIError {
            onToast(error.message)
        } catch {
            onToast("删除分类失败")
        }
    }

    private func reloadTypes(actionId: Int) async {
        ManagementCache.invalidateTypes(for: actionId)
        await loadTypes(actionId: actionId, force: true)
    }

    private func loadTypes(actionId: Int, force: Bool) async {
        if let cached = ManagementCache.types(for: actionId) {
            types = cached
            pruneExpandedParents()
        }

        if ManagementCache.hasTypesCache(actionId: actionId, force: force) {
            return
        }

        let showSpinner = types.isEmpty
        if showSpinner {
            loadingTypes = true
        }
        defer { if showSpinner { loadingTypes = false } }

        do {
            let list = try await CatalogService.fetchTypes(
                httpBase: httpBase(),
                token: token(),
                actionId: actionId
            )
            ManagementCache.setTypes(list, for: actionId)
            if selectedActionId == actionId {
                types = list
                pruneExpandedParents()
            }
        } catch let error as APIError where error.status == 401 {
            onUnauthorized(error.message)
        } catch let error as APIError {
            if selectedActionId == actionId {
                if types.isEmpty {
                    errorMessage = error.message
                    types = []
                } else {
                    onToast(error.message)
                }
            }
        } catch {
            if selectedActionId == actionId {
                if types.isEmpty {
                    errorMessage = "加载分类失败"
                    types = []
                } else {
                    onToast("加载分类失败")
                }
            }
        }
    }

    /// 默认选中可见 Tab 第一项（收入）；若当前 id 不在常用三项中则重置。
    private func ensureValidSelectedAction() {
        let visible = visibleActions
        guard !visible.isEmpty else {
            selectedActionId = nil
            return
        }
        if let selectedActionId, visible.contains(where: { $0.id == selectedActionId }) {
            return
        }
        selectedActionId = visible.first?.id
    }

    private func pruneExpandedParents() {
        let validIds = Set(types.filter(\.isRootLevel).map(\.id))
        expandedParentIds = expandedParentIds.intersection(validIds)
    }
}

struct CategoriesView: View {
    @EnvironmentObject private var appVM: EasyAccountViewModel
    @StateObject private var vm: CategoriesViewModel

    init(appVM: EasyAccountViewModel) {
        _vm = StateObject(wrappedValue: CategoriesViewModel(
            httpBase: { appVM.httpBase },
            token: { SessionStore.getStoredToken() },
            onUnauthorized: { appVM.handleUnauthorized($0) },
            onToast: { appVM.showToast($0) }
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.loadingActions && vm.actions.isEmpty {
                    CenterStatusView(text: "加载分类中…")
                } else if !vm.errorMessage.isEmpty && vm.actions.isEmpty {
                    errorState
                } else {
                    typeTree
                }
            }
            .background(EATheme.background.ignoresSafeArea())
            .navigationTitle("我的分类")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ManagementBackButton { appVM.closeManagement() }
                }
                .eaHideSharedBackground()

                ToolbarItem(placement: .topBarTrailing) {
                    ManagementCircleIconButton(systemName: "plus") {
                        vm.openCreate()
                    }
                }
                .eaHideSharedBackground()
            }
            .task { await vm.loadActions() }
            .sheet(item: $vm.editor) { editor in
                TypeEditorSheet(
                    editor: Binding(
                        get: { vm.editor ?? editor },
                        set: { vm.editor = $0 }
                    ),
                    rootTypes: vm.rootTypes,
                    saving: vm.saving,
                    onCancel: { vm.editor = nil },
                    onSave: { Task { await vm.saveEditor() } }
                )
            }
        }
    }

    private var typeTree: some View {
        VStack(spacing: 0) {
            if !vm.visibleActions.isEmpty {
                actionTabs
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }

            Group {
                if vm.loadingTypes && vm.types.isEmpty {
                    CenterStatusView(text: "加载分类树…")
                } else if !vm.errorMessage.isEmpty && vm.types.isEmpty {
                    errorState
                } else if vm.types.isEmpty {
                    emptyTypesState
                } else {
                    typesList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 仅收入 / 支出 / 内部转账；请求树时带对应真实 `actionId`。
    private var actionTabs: some View {
        Picker(
            "收支类型",
            selection: Binding(
                get: { vm.selectedActionId },
                set: { newValue in
                    guard let newValue else { return }
                    Task { await vm.selectAction(newValue) }
                }
            )
        ) {
            ForEach(vm.visibleActions) { action in
                Text(action.primaryTabTitle).tag(Optional(action.id))
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("收支类型")
    }

    private var emptyTypesState: some View {
        VStack(spacing: 16) {
            Text("暂无分类")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(EATheme.label)
            Button("新建分类") { vm.openCreate() }
                .buttonStyle(PressableButtonStyle())
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(EATheme.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var typesList: some View {
        List {
            ForEach(vm.flatRows) { row in
                categoryRow(row)
                    .listRowBackground(EATheme.surface)
                    .listRowSeparatorTint(EATheme.surfaceElevated)
                    // 右划 → 编辑
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            vm.openEdit(row.node)
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(EATheme.blue)
                    }
                    // 左划 → 删除
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await vm.delete(row.node) }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await vm.loadActions(force: true) }
        .animation(.easeInOut(duration: 0.18), value: vm.expandedParentIds)
    }

    private func categoryRow(_ row: FlatTypeRow) -> some View {
        HStack(spacing: 10) {
            if row.hasChildren {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(EATheme.tertiary)
                    .frame(width: 14)
            } else if row.depth > 0 {
                Color.clear.frame(width: 14)
            }

            Text(row.node.tName)
                .font(.system(size: 16, weight: row.depth == 0 ? .semibold : .medium))
                .foregroundStyle(EATheme.label)

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * 16)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            guard row.hasChildren else { return }
            vm.toggleExpanded(parentId: row.node.id)
        }
        .accessibilityAddTraits(row.hasChildren ? .isButton : [])
        .accessibilityHint(row.hasChildren ? (row.isExpanded ? "收起子分类" : "展开子分类") : "")
    }

    private var errorState: some View {
        VStack(spacing: 14) {
            Text(vm.errorMessage)
                .font(.system(size: 15))
                .foregroundStyle(EATheme.danger)
                .multilineTextAlignment(.center)
            Button("重试") {
                Task { await vm.loadActions(force: true) }
            }
            .foregroundStyle(EATheme.blue)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TypeEditorSheet: View {
    @Binding var editor: TypeEditorState
    let rootTypes: [TypeNodeDTO]
    let saving: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    private var parentOptions: [(id: Int?, title: String)] {
        [(nil, "一级分类")] + rootTypes
            .filter { option in
                if case .edit(let node) = editor.mode {
                    return option.id != node.id
                }
                return true
            }
            .map { ($0.id, $0.tName) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("分类名", text: $editor.name)

                    if case .create = editor.mode {
                        Picker("上级分类", selection: $editor.parentId) {
                            ForEach(parentOptions, id: \.id) { option in
                                Text(option.title).tag(option.id as Int?)
                            }
                        }
                    } else {
                        LabeledContent("上级分类") {
                            Text(parentTitle)
                                .foregroundStyle(EATheme.secondary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(EATheme.background.ignoresSafeArea())
            .navigationTitle(editor.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存", action: onSave)
                        .disabled(saving)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var parentTitle: String {
        guard let parentId = editor.parentId else { return "一级分类" }
        return rootTypes.first(where: { $0.id == parentId })?.tName ?? "一级分类"
    }
}
