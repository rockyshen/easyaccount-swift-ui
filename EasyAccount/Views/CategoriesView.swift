import SwiftUI

@MainActor
final class CategoriesViewModel: ObservableObject {
    @Published var actions: [ActionDTO] = []
    @Published var selectedActionId: Int?
    @Published var types: [TypeNodeDTO] = []
    @Published var loadingActions = false
    @Published var loadingTypes = false
    @Published var errorMessage = ""

    private let httpBase: () -> String
    private let token: () -> String
    private let onUnauthorized: (String) -> Void

    init(
        httpBase: @escaping () -> String,
        token: @escaping () -> String,
        onUnauthorized: @escaping (String) -> Void
    ) {
        self.httpBase = httpBase
        self.token = token
        self.onUnauthorized = onUnauthorized
    }

    func loadActions(force: Bool = false) async {
        if !ManagementCache.actions.isEmpty {
            actions = ManagementCache.actions
            if selectedActionId == nil {
                selectedActionId = actions.first?.id
            }
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
            if selectedActionId == nil || !(list.contains { $0.id == selectedActionId }) {
                selectedActionId = list.first?.id
            }
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

    func selectAction(_ actionId: Int) async {
        guard selectedActionId != actionId else { return }
        selectedActionId = actionId
        await loadTypes(actionId: actionId, force: false)
    }

    private func loadTypes(actionId: Int, force: Bool) async {
        if let cached = ManagementCache.types(for: actionId) {
            types = cached
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
            // 用户可能已切到别的 action，只回填当前选中的
            if selectedActionId == actionId {
                types = list
            }
        } catch let error as APIError where error.status == 401 {
            onUnauthorized(error.message)
        } catch let error as APIError {
            if types.isEmpty {
                errorMessage = error.message
                types = []
            }
        } catch {
            if types.isEmpty {
                errorMessage = "加载分类失败"
                types = []
            }
        }
    }
}

struct CategoriesView: View {
    @EnvironmentObject private var appVM: EasyAccountViewModel
    @StateObject private var vm: CategoriesViewModel

    init(appVM: EasyAccountViewModel) {
        _vm = StateObject(wrappedValue: CategoriesViewModel(
            httpBase: { appVM.httpBase },
            token: { SessionStore.getStoredToken() },
            onUnauthorized: { appVM.handleUnauthorized($0) }
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if vm.loadingActions && vm.actions.isEmpty {
                    CenterStatusView(text: "加载分类中…")
                } else if !vm.errorMessage.isEmpty && vm.actions.isEmpty {
                    errorState
                } else {
                    actionPicker
                    Divider().overlay(EATheme.surfaceElevated)
                    typeTree
                }
            }
            .background(EATheme.background.ignoresSafeArea())
            .navigationTitle("分类管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ManagementBackButton { appVM.closeManagement() }
                }
            }
            .task { await vm.loadActions() }
            .refreshable { await vm.loadActions(force: true) }
        }
    }

    private var actionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.actions) { action in
                    let selected = vm.selectedActionId == action.id
                    Button {
                        Task { await vm.selectAction(action.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.hName)
                                .font(.system(size: 14, weight: .semibold))
                            Text(action.handleLabel)
                                .font(.system(size: 11))
                                .opacity(0.8)
                        }
                        .foregroundStyle(selected ? Color.white : EATheme.label)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(selected ? EATheme.blue : EATheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var typeTree: some View {
        if vm.loadingTypes && vm.types.isEmpty {
            CenterStatusView(text: "加载分类树…")
        } else if vm.types.isEmpty {
            VStack(spacing: 10) {
                Text("暂无分类")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(EATheme.label)
                Text("当前收支类型下还没有分类数据")
                    .font(.system(size: 13))
                    .foregroundStyle(EATheme.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(vm.types) { node in
                    TypeNodeRow(node: node)
                        .listRowBackground(EATheme.surface)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
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

private struct TypeNodeRow: View {
    let node: TypeNodeDTO

    var body: some View {
        if node.children.isEmpty {
            Text(node.tName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(EATheme.label)
                .padding(.vertical, 2)
        } else {
            DisclosureGroup {
                ForEach(node.children) { child in
                    TypeNodeRow(node: child)
                        .padding(.leading, 4)
                }
            } label: {
                Text(node.tName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(EATheme.label)
            }
            .tint(EATheme.blue)
        }
    }
}
