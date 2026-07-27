import SwiftUI

struct EasyAccountRootView: View {
    @EnvironmentObject private var vm: EasyAccountViewModel

    private let menuWidthRatio: CGFloat = 0.78

    /// 拖动手势过程中的额外水平位移；松手后归零并由 `showSideMenu` 决定最终开合。
    @State private var menuDragTranslation: CGFloat = 0
    @State private var menuWidthCache: CGFloat = 280
    @State private var isMenuDragging = false

    /// 管理子页右划返回时的水平位移。
    @State private var managementDragOffset: CGFloat = 0
    @State private var isManagementDragging = false

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

            if isChatStage, vm.managementDestination == nil {
                ConnectionStatusDot(kind: connectionDotKind)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 14)
                    .padding(.trailing, 16)
                    .allowsHitTesting(false)
                    .zIndex(4)
            }

            if !vm.toastMessage.isEmpty {
                toastBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 54)
            }

            if let destination = vm.managementDestination {
                managementPage(for: destination)
                    .environmentObject(vm)
                    .offset(x: max(0, managementDragOffset))
                    .simultaneousGesture(managementBackSwipeGesture)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing),
                            removal: .move(edge: .trailing)
                        )
                    )
                    .zIndex(5)
                    .id(destination)
                    .onAppear { resetManagementDrag() }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.toastMessage.isEmpty)
        .animation(
            isManagementDragging ? nil : .spring(response: 0.34, dampingFraction: 0.9),
            value: vm.managementDestination
        )
        .background(EATheme.background.ignoresSafeArea())
        .preferredColorScheme(vm.appearanceMode.preferredColorScheme)
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
        case .scheduledTasks:
            ComingSoonManagementView(
                title: destination.title,
                systemImage: "clock.arrow.circlepath",
                message: "定时记账与提醒即将开放"
            )
        }
    }

    private var isChatStage: Bool {
        vm.stage == .live || vm.stage == .connecting
    }

    private var connectionDotKind: ConnectionStatusDot.Kind {
        if vm.connected {
            return .connected
        }
        if vm.isSocketConnecting {
            return .connecting
        }
        return .disconnected
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
                guard isChatStage, vm.managementDestination == nil, !vm.showSideMenu else { return }
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

    /// 管理子页从左缘右划返回（自定义覆盖层，无系统 interactive pop）。
    private var managementBackSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard vm.managementDestination != nil else { return }
                // 仅左缘起手，避免与横向列表/分类滚动冲突。
                guard value.startLocation.x <= 28 || isManagementDragging else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                guard dx > 0, abs(dx) > abs(dy) * 1.05 else { return }
                if !isManagementDragging { isManagementDragging = true }
                managementDragOffset = dx
            }
            .onEnded { value in
                guard isManagementDragging else { return }
                let dx = value.translation.width
                let predicted = value.predictedEndTranslation.width
                let shouldClose = dx > 88 || predicted > 180

                if shouldClose {
                    let dismissX = max(UIScreen.main.bounds.width, managementDragOffset + 120)
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        managementDragOffset = dismissX
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                        // 跟手滑出后无动画卸页，再打开侧栏，避免跳回聊天主界面。
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            vm.managementDestination = nil
                        }
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                            vm.showSideMenu = true
                        }
                        resetManagementDrag()
                    }
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        resetManagementDrag()
                    }
                }
            }
    }

    private func resetManagementDrag() {
        managementDragOffset = 0
        isManagementDragging = false
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

/// 管理页导航栏圆形图标按钮（黑箭头 / 加号等，参考系统浅灰圆底样式）。
struct ManagementCircleIconButton: View {
    let systemName: String
    var fontSize: CGFloat = 16
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(EATheme.label)
                .frame(width: 34, height: 34)
                .background(EATheme.surfaceElevated.opacity(0.92))
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

struct ManagementBackButton: View {
    let action: () -> Void

    var body: some View {
        ManagementCircleIconButton(systemName: "chevron.left", fontSize: 15, action: action)
    }
}

struct ComingSoonManagementView: View {
    @EnvironmentObject private var appVM: EasyAccountViewModel

    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: systemImage)
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(EATheme.tertiary)
                Text(message)
                    .font(.system(size: 15))
                    .foregroundStyle(EATheme.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(EATheme.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ManagementBackButton { appVM.closeManagement() }
                }
            }
        }
    }
}
