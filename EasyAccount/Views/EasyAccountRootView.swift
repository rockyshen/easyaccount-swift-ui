import SwiftUI

struct EasyAccountRootView: View {
    @EnvironmentObject private var vm: EasyAccountViewModel

    private let menuWidthRatio: CGFloat = 0.78

    var body: some View {
        ZStack(alignment: .leading) {
            EATheme.background.ignoresSafeArea()

            mainContent
                .disabled(vm.showSideMenu && isChatStage)
                .overlay {
                    if vm.showSideMenu && isChatStage {
                        EATheme.scrim
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                                    vm.showSideMenu = false
                                }
                            }
                            .transition(.opacity)
                    }
                }

            if isChatStage {
                sideMenuLayer
            }

            if !vm.toastMessage.isEmpty {
                toastBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 54)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.toastMessage.isEmpty)
        .background(EATheme.background.ignoresSafeArea())
        .preferredColorScheme(vm.appearanceMode.preferredColorScheme)
        .fullScreenCover(item: $vm.managementDestination) { destination in
            managementPage(for: destination)
                .environmentObject(vm)
                .preferredColorScheme(vm.appearanceMode.preferredColorScheme)
        }
        .onAppear { vm.onAppear() }
        .onDisappear { vm.onDisappear() }
    }

    @ViewBuilder
    private func managementPage(for destination: ManagementDestination) -> some View {
        switch destination {
        case .accounts:
            AccountsView(appVM: vm)
        case .categories:
            CategoriesView(appVM: vm)
        case .dashboard:
            DashboardView(appVM: vm)
        }
    }

    private var isChatStage: Bool {
        vm.stage == .live || vm.stage == .connecting
    }

    /// GeometryReader 只包侧栏，避免把聊天主界面锁死在固定高度，导致键盘无法把输入区顶起。
    private var sideMenuLayer: some View {
        GeometryReader { geo in
            let menuWidth = min(geo.size.width * menuWidthRatio, 320)

            HStack(spacing: 0) {
                SideMenuView()
                    .frame(width: menuWidth)
                    .offset(x: vm.showSideMenu ? 0 : -menuWidth - 8)
                    .animation(.spring(response: 0.32, dampingFraction: 0.88), value: vm.showSideMenu)

                Spacer(minLength: 0)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(2)
        .allowsHitTesting(vm.showSideMenu)
    }

    @ViewBuilder
    private var mainContent: some View {
        switch vm.stage {
        case .bootstrapping:
            CenterStatusView(text: "正在恢复登录状态…")
        case .login:
            LoginView()
        case .connecting:
            ZStack {
                ChatView()
                CenterStatusView(text: "正在连接记账助手…")
                    .background(EATheme.background.opacity(0.72))
            }
        case .live:
            ChatView()
        }
    }

    private var toastBanner: some View {
        Text(vm.toastMessage)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(EATheme.label)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(EATheme.surfaceElevated)
            .clipShape(Capsule())
            .shadow(color: EATheme.toastShadow, radius: 12, y: 6)
            .padding(.horizontal, 24)
    }
}

struct CenterStatusView: View {
    let text: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(EATheme.blue)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(EATheme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
