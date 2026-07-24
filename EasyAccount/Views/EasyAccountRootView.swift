import SwiftUI

struct EasyAccountRootView: View {
    @EnvironmentObject private var vm: EasyAccountViewModel

    private let menuWidthRatio: CGFloat = 0.78

    /// 拖动手势过程中的额外水平位移；松手后归零并由 `showSideMenu` 决定最终开合。
    @State private var menuDragTranslation: CGFloat = 0
    @State private var menuWidthCache: CGFloat = 280
    @State private var isMenuDragging = false

    var body: some View {
        ZStack(alignment: .leading) {
            EATheme.background.ignoresSafeArea()

            mainContent
                .disabled(vm.showSideMenu && isChatStage)
                .simultaneousGesture(menuOpenSwipeGesture)
                .overlay {
                    if isChatStage, vm.showSideMenu || isMenuDragging {
                        EATheme.scrim
                            .opacity(Double(revealedMenuProgress))
                            .ignoresSafeArea()
                            .onTapGesture {
                                guard !isMenuDragging else { return }
                                closeSideMenu()
                            }
                            .highPriorityGesture(menuCloseDragGesture)
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

    private var revealedMenuProgress: CGFloat {
        let closed = -menuWidthCache - 8
        let current = resolvedMenuOffset(menuWidth: menuWidthCache)
        let span = -closed
        guard span > 0 else { return vm.showSideMenu ? 1 : 0 }
        return min(1, max(0, (current - closed) / span))
    }

    /// GeometryReader 只包侧栏，避免把聊天主界面锁死在固定高度，导致键盘无法把输入区顶起。
    private var sideMenuLayer: some View {
        GeometryReader { geo in
            let menuWidth = min(geo.size.width * menuWidthRatio, 320)

            HStack(spacing: 0) {
                SideMenuView()
                    .frame(width: menuWidth)
                    .offset(x: resolvedMenuOffset(menuWidth: menuWidth))
                    .highPriorityGesture(menuCloseDragGesture)

                Spacer(minLength: 0)
                    .allowsHitTesting(false)
            }
            .onAppear { menuWidthCache = menuWidth }
            .onChange(of: geo.size.width) { _, _ in
                menuWidthCache = menuWidth
            }
        }
        .zIndex(2)
        .allowsHitTesting(vm.showSideMenu || isMenuDragging)
    }

    private func resolvedMenuOffset(menuWidth: CGFloat) -> CGFloat {
        let closed = -menuWidth - 8
        let base: CGFloat = vm.showSideMenu ? 0 : closed
        return min(0, max(closed, base + menuDragTranslation))
    }

    /// 聊天主界面右划打开侧栏（需明显水平滑动，避免干扰列表上下滚）。
    private var menuOpenSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onChanged { value in
                guard isChatStage, !vm.showSideMenu else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                guard dx > 0, abs(dx) > abs(dy) * 1.15 else { return }
                if !isMenuDragging { isMenuDragging = true }
                menuDragTranslation = dx
            }
            .onEnded { value in
                guard isMenuDragging else { return }
                finishMenuDrag(value)
            }
    }

    /// 侧栏打开后左划关闭。
    private var menuCloseDragGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                guard isChatStage, vm.showSideMenu || isMenuDragging else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) >= abs(dy) * 0.85 else { return }
                if !isMenuDragging { isMenuDragging = true }
                menuDragTranslation = min(0, dx)
            }
            .onEnded { value in
                guard isMenuDragging else { return }
                finishMenuDrag(value)
            }
    }

    private func finishMenuDrag(_ value: DragGesture.Value) {
        let dx = value.translation.width
        let predicted = value.predictedEndTranslation.width
        let threshold = menuWidthCache * 0.28
        let shouldOpen: Bool

        if vm.showSideMenu {
            shouldOpen = !(dx < -threshold || predicted < -menuWidthCache * 0.45)
        } else {
            shouldOpen = dx > threshold || predicted > menuWidthCache * 0.45
        }

        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            vm.showSideMenu = shouldOpen
            menuDragTranslation = 0
            isMenuDragging = false
        }
    }

    private func closeSideMenu() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            vm.showSideMenu = false
            menuDragTranslation = 0
            isMenuDragging = false
        }
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
