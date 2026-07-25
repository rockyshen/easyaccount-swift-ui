import SwiftUI

@MainActor
final class AccountsViewModel: ObservableObject {
    @Published var accounts: [AccountDTO] = []
    @Published var loading = false
    @Published var saving = false
    @Published var errorMessage = ""
    @Published var editor: AccountEditorState?

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

    func load(force: Bool = false) async {
        // 先用缓存秒开，避免每次进入都白屏转圈
        if !ManagementCache.accounts.isEmpty {
            accounts = ManagementCache.accounts
        }

        if ManagementCache.hasAccountsCache(force: force) {
            errorMessage = ""
            return
        }

        let showSpinner = accounts.isEmpty
        if showSpinner {
            loading = true
        }
        errorMessage = ""
        defer { if showSpinner { loading = false } }

        do {
            let list = try await AccountService.list(httpBase: httpBase(), token: token())
            ManagementCache.setAccounts(list)
            accounts = list
        } catch let error as APIError where error.status == 401 {
            onUnauthorized(error.message)
        } catch let error as APIError {
            if accounts.isEmpty {
                errorMessage = error.message
            } else {
                onToast(error.message)
            }
        } catch {
            if accounts.isEmpty {
                errorMessage = "加载账户失败"
            } else {
                onToast("加载账户失败")
            }
        }
    }

    func openCreate() {
        editor = AccountEditorState(mode: .create)
    }

    func openEdit(_ account: AccountDTO) {
        editor = AccountEditorState(mode: .edit(account))
    }

    func saveEditor() async {
        guard let editor else { return }
        let name = editor.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            onToast("请输入账户名")
            return
        }

        saving = true
        defer { saving = false }

        do {
            switch editor.mode {
            case .create:
                let amountRaw = editor.amountText.trimmingCharacters(in: .whitespacesAndNewlines)
                let initial: String
                if amountRaw.isEmpty {
                    if editor.accountType == 1 {
                        onToast("请输入有效信用额度")
                        return
                    }
                    initial = "0.00"
                } else if let normalized = MoneyFormat.apiString(from: amountRaw) {
                    initial = normalized
                } else {
                    onToast(editor.accountType == 1 ? "请输入有效信用额度" : "请输入有效初始余额")
                    return
                }
                if editor.accountType == 1, MoneyFormat.decimal(from: initial) <= 0 {
                    onToast("信用卡信用额度必须大于 0")
                    return
                }
                let body = CreateAccountRequest(
                    name: name,
                    initialMoney: initial,
                    card: editor.card,
                    note: editor.note,
                    accountType: editor.accountType
                )
                let created = try await AccountService.create(httpBase: httpBase(), token: token(), request: body)
                ManagementCache.upsertAccount(created)
                accounts = ManagementCache.accounts
                onToast("账户已创建")
            case .edit(let account):
                var exemptMoney: String?
                let amountRaw = editor.amountText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !amountRaw.isEmpty {
                    guard let normalized = MoneyFormat.apiString(from: amountRaw) else {
                        onToast(account.isCreditCard ? "请输入有效信用额度" : "请输入有效豁免金额")
                        return
                    }
                    exemptMoney = normalized
                }
                let body = UpdateAccountRequest(
                    name: name,
                    card: editor.card,
                    note: editor.note,
                    exemptMoney: exemptMoney
                )
                let updated = try await AccountService.update(
                    httpBase: httpBase(),
                    token: token(),
                    id: account.id,
                    request: body
                )
                ManagementCache.upsertAccount(updated)
                accounts = ManagementCache.accounts
                onToast("账户已更新")
            }
            self.editor = nil
        } catch let error as APIError where error.status == 401 {
            onUnauthorized(error.message)
        } catch let error as APIError {
            onToast(error.message)
        } catch {
            onToast("保存失败")
        }
    }

    func delete(_ account: AccountDTO) async {
        do {
            try await AccountService.delete(httpBase: httpBase(), token: token(), id: account.id)
            ManagementCache.removeAccount(id: account.id)
            accounts.removeAll { $0.id == account.id }
            onToast("账户已删除")
        } catch let error as APIError where error.status == 401 {
            onUnauthorized(error.message)
        } catch let error as APIError {
            onToast(error.message)
        } catch {
            onToast("删除失败")
        }
    }
}

struct AccountEditorState: Identifiable, Equatable {
    enum Mode: Equatable {
        case create
        case edit(AccountDTO)
    }

    let id = UUID()
    var mode: Mode
    var name: String
    var amountText: String
    var card: String
    var note: String
    var accountType: Int

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .create:
            name = ""
            amountText = ""
            card = ""
            note = ""
            accountType = 0
        case .edit(let account):
            name = account.name
            amountText = account.exemptMoney
            card = account.card ?? ""
            note = account.note ?? ""
            accountType = account.accountType
        }
    }

    var title: String {
        switch mode {
        case .create: return "新建账户"
        case .edit: return "编辑账户"
        }
    }

    var amountLabel: String {
        switch mode {
        case .create:
            return accountType == 1 ? "信用额度" : "初始余额"
        case .edit:
            return accountType == 1 ? "信用额度" : "豁免资产"
        }
    }

    var amountHint: String {
        switch mode {
        case .create:
            return accountType == 1 ? "信用卡必填，且须大于 0" : "可留空，默认 0"
        case .edit:
            return accountType == 1 ? "修改信用额度（不得小于已用）" : "修改豁免资产，留空则不改"
        }
    }
}

struct AccountsView: View {
    @EnvironmentObject private var appVM: EasyAccountViewModel
    @StateObject private var vm: AccountsViewModel

    init(appVM: EasyAccountViewModel) {
        _vm = StateObject(wrappedValue: AccountsViewModel(
            httpBase: { appVM.httpBase },
            token: { SessionStore.getStoredToken() },
            onUnauthorized: { appVM.handleUnauthorized($0) },
            onToast: { appVM.showToast($0) }
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.loading && vm.accounts.isEmpty {
                    CenterStatusView(text: "加载账户中…")
                } else if !vm.errorMessage.isEmpty && vm.accounts.isEmpty {
                    errorState
                } else if vm.accounts.isEmpty {
                    emptyState
                } else {
                    accountList
                }
            }
            .background(EATheme.background.ignoresSafeArea())
            .navigationTitle("账户管理")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ManagementBackButton { appVM.closeManagement() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ManagementCircleIconButton(systemName: "plus") {
                        vm.openCreate()
                    }
                }
            }
            .task { await vm.load() }
            .refreshable { await vm.load(force: true) }
            .sheet(item: $vm.editor) { editor in
                AccountEditorSheet(
                    editor: Binding(
                        get: { vm.editor ?? editor },
                        set: { vm.editor = $0 }
                    ),
                    saving: vm.saving,
                    onCancel: { vm.editor = nil },
                    onSave: { Task { await vm.saveEditor() } }
                )
            }
        }
    }

    private var accountList: some View {
        List {
            ForEach(vm.accounts) { account in
                Button {
                    vm.openEdit(account)
                } label: {
                    AccountRow(account: account)
                }
                .buttonStyle(.plain)
                .listRowBackground(EATheme.surface)
                .listRowSeparatorTint(EATheme.surfaceElevated)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        Task { await vm.delete(account) }
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "creditcard")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(EATheme.tertiary)
            Text("还没有账户")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(EATheme.label)
            Text("创建一个储蓄账户或信用卡开始记账")
                .font(.system(size: 14))
                .foregroundStyle(EATheme.secondary)
            Button("新建账户") { vm.openCreate() }
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

    private var errorState: some View {
        VStack(spacing: 14) {
            Text(vm.errorMessage)
                .font(.system(size: 15))
                .foregroundStyle(EATheme.danger)
                .multilineTextAlignment(.center)
            Button("重试") {
                Task { await vm.load(force: true) }
            }
            .foregroundStyle(EATheme.blue)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AccountRow: View {
    let account: AccountDTO

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: account.isCreditCard ? "creditcard.fill" : "banknote.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(account.isCreditCard ? EATheme.orange : EATheme.blue)
                .frame(width: 36, height: 36)
                .background(EATheme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(account.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(EATheme.label)
                    Spacer()
                    Text(account.typeLabel ?? (account.isCreditCard ? "信用卡" : "普通"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(EATheme.secondary)
                }
                Text("\(account.primaryAmountLabel) ¥\(MoneyFormat.display(account.money))")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(EATheme.label)
                if let secondary = account.secondarySummary {
                    Text(secondary)
                        .font(.system(size: 13))
                        .foregroundStyle(EATheme.secondary)
                }
                if let card = account.card, !card.isEmpty {
                    Text(card)
                        .font(.system(size: 12))
                        .foregroundStyle(EATheme.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AccountEditorSheet: View {
    @Binding var editor: AccountEditorState
    let saving: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("账户名", text: $editor.name)
                    if case .create = editor.mode {
                        Picker("账户类型", selection: $editor.accountType) {
                            Text("普通").tag(0)
                            Text("信用卡").tag(1)
                        }
                    } else {
                        LabeledContent("账户类型") {
                            Text(editor.accountType == 1 ? "信用卡" : "普通")
                                .foregroundStyle(EATheme.secondary)
                        }
                    }
                    TextField(editor.amountLabel, text: $editor.amountText)
                        .keyboardType(.decimalPad)
                    Text(editor.amountHint)
                        .font(.system(size: 12))
                        .foregroundStyle(EATheme.tertiary)
                }

                Section("备注") {
                    TextField("卡号备注", text: $editor.card)
                    TextField("备注", text: $editor.note)
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
        .presentationDetents([.medium, .large])
    }
}
