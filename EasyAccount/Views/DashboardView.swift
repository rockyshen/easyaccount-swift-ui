import SwiftUI

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var dashboard: DashboardDTO?
    @Published var loading = false
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

    func load() async {
        loading = true
        errorMessage = ""
        defer { loading = false }
        do {
            dashboard = try await DashboardService.fetch(httpBase: httpBase(), token: token())
        } catch let error as APIError where error.status == 401 {
            onUnauthorized(error.message)
        } catch let error as APIError {
            errorMessage = error.message
        } catch {
            errorMessage = "加载概览失败"
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var appVM: EasyAccountViewModel
    @StateObject private var vm: DashboardViewModel

    init(appVM: EasyAccountViewModel) {
        _vm = StateObject(wrappedValue: DashboardViewModel(
            httpBase: { appVM.httpBase },
            token: { SessionStore.getStoredToken() },
            onUnauthorized: { appVM.handleUnauthorized($0) }
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.loading && vm.dashboard == nil {
                    CenterStatusView(text: "加载概览中…")
                } else if let dashboard = vm.dashboard {
                    content(dashboard)
                } else {
                    errorState
                }
            }
            .background(EATheme.background.ignoresSafeArea())
            .navigationTitle("概览分析")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ManagementBackButton { appVM.closeManagement() }
                }
                .eaHideSharedBackground()
            }
            .task { await vm.load() }
            .refreshable { await vm.load() }
        }
    }

    private func content(_ dashboard: DashboardDTO) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summaryCard(dashboard)
                yearCard(dashboard)
                accountsSection(dashboard.accounts ?? [])
            }
            .padding(16)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    private func summaryCard(_ dashboard: DashboardDTO) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("资产概况")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(EATheme.secondary)
            HStack(spacing: 12) {
                metricBlock(title: "总资产", value: dashboard.totalAsset)
                metricBlock(title: "净资产", value: dashboard.netAsset)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(EATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func yearCard(_ dashboard: DashboardDTO) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("本年度")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(EATheme.secondary)
            HStack(spacing: 10) {
                metricBlock(title: "收入", value: dashboard.yearIncome, accent: EATheme.green)
                metricBlock(title: "支出", value: dashboard.yearOutCome, accent: EATheme.orange)
                metricBlock(title: "结余", value: dashboard.yearBalance, accent: EATheme.blue)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(EATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func accountsSection(_ accounts: [DashboardAccountDTO]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("账户构成")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(EATheme.secondary)
                .padding(.horizontal, 4)

            if accounts.isEmpty {
                Text("暂无账户数据")
                    .font(.system(size: 14))
                    .foregroundStyle(EATheme.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(EATheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        DashboardAccountRow(account: account)
                        if index < accounts.count - 1 {
                            Divider().overlay(EATheme.surfaceElevated)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(EATheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func metricBlock(title: String, value: String?, accent: Color = EATheme.label) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(EATheme.secondary)
            Text("¥\(MoneyFormat.display(value))")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(EATheme.surfaceElevated.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var errorState: some View {
        VStack(spacing: 14) {
            Text(vm.errorMessage.isEmpty ? "暂无概览数据" : vm.errorMessage)
                .font(.system(size: 15))
                .foregroundStyle(vm.errorMessage.isEmpty ? EATheme.secondary : EATheme.danger)
                .multilineTextAlignment(.center)
            Button("重试") {
                Task { await vm.load() }
            }
            .foregroundStyle(EATheme.blue)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DashboardAccountRow: View {
    let account: DashboardAccountDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(account.accountName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(EATheme.label)
                Spacer()
                Text("¥\(MoneyFormat.display(account.accountAsset))")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(EATheme.label)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(EATheme.surfaceElevated)
                    Capsule()
                        .fill(EATheme.blue.opacity(0.85))
                        .frame(width: geo.size.width * MoneyFormat.percentFraction(from: account.percent))
                }
            }
            .frame(height: 6)

            HStack {
                if let exempt = account.exemptAsset, MoneyFormat.decimal(from: exempt) > 0 {
                    Text(exemptLabel(exempt))
                        .font(.system(size: 12))
                        .foregroundStyle(EATheme.secondary)
                }
                Spacer()
                Text(percentLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(EATheme.tertiary)
            }
        }
        .padding(.vertical, 10)
    }

    private func exemptLabel(_ value: String) -> String {
        if account.accountName.contains("信用卡") {
            return "已用 ¥\(MoneyFormat.display(value))"
        }
        return "豁免 ¥\(MoneyFormat.display(value))"
    }

    private var percentLabel: String {
        guard let percent = account.percent?.trimmingCharacters(in: .whitespacesAndNewlines),
              !percent.isEmpty else {
            return ""
        }
        return percent.hasSuffix("%") ? percent : "\(percent)%"
    }
}
