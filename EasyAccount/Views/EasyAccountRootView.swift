import SwiftUI

struct EasyAccountRootView: View {
    @EnvironmentObject private var vm: EasyAccountViewModel

    private let menuWidthRatio: CGFloat = 0.78

    var body: some View {
        GeometryReader { geo in
            let menuWidth = min(geo.size.width * menuWidthRatio, 320)

            ZStack(alignment: .leading) {
                EATheme.background.ignoresSafeArea()

                mainContent
                    .frame(width: geo.size.width, height: geo.size.height)
                    .disabled(vm.showSideMenu && isChatStage)
                    .overlay {
                        if vm.showSideMenu && isChatStage {
                            Color.black.opacity(0.45)
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
                    SideMenuView()
                        .frame(width: menuWidth)
                        .offset(x: vm.showSideMenu ? 0 : -menuWidth - 8)
                        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: vm.showSideMenu)
                        .zIndex(2)
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
        }
        .background(EATheme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { vm.onAppear() }
        .onDisappear { vm.onDisappear() }
    }

    private var isChatStage: Bool {
        vm.stage == .live || vm.stage == .connecting
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
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
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
