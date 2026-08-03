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
                periodSummaryCard(
                    title: "本月",
                    income: dashboard.curIncome,
                    outcome: dashboard.curOutCome,
                    balance: dashboard.curBalance
                )
                periodSummaryCard(
                    title: "本年度",
                    income: dashboard.yearIncome,
                    outcome: dashboard.yearOutCome,
                    balance: dashboard.yearBalance
                )
            }
            .padding(16)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    /// 本月 / 本年度共用：收入绿 / 支出橙 / 结余蓝三列指标卡。
    private func periodSummaryCard(
        title: String,
        income: String?,
        outcome: String?,
        balance: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(EATheme.secondary)
            HStack(spacing: 10) {
                metricBlock(title: "收入", value: income, accent: EATheme.green)
                metricBlock(title: "支出", value: outcome, accent: EATheme.orange)
                metricBlock(title: "结余", value: balance, accent: EATheme.blue)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(EATheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
