import SwiftUI
import UIKit

struct EasyAccountRootView: View {
    @EnvironmentObject private var vm: EasyAccountViewModel
    @Environment(\.scenePhase) private var scenePhase

    private let menuWidthRatio: CGFloat = 0.78

    /// 拖动手势过程中的额外水平位移；松手后归零并由 `showSideMenu` 决定最终开合。
    @State private var menuDragTranslation: CGFloat = 0
    @State private var menuWidthCache: CGFloat = 280
    @State private var isMenuDragging = false
    /// 复用并预热，侧栏打开震动更跟手。
    @State private var menuOpenImpact = UIImpactFeedbackGenerator(style: .medium)

    /// 管理子页右划返回时的水平位移。
    @State private var managementDragOffset: CGFloat = 0
    @State private var isManagementDragging = false

    /// 桥接聊天列表的滚动状态，供侧栏手势判定与「开栏前止住惯性」使用。
    @StateObject private var scrollBridge = ChatScrollBridge()

    var body: some View {
        ZStack(alignment: .leading) {
            EATheme.background.ignoresSafeArea()

            // 仅作为 UIKit 手势的挂载点：手势装到窗口根视图上，自身不参与布局命中。
            SideMenuOpenPanGesture(
                bridge: scrollBridge,
                canBegin: { canOpenMenuByGesture },
                onChanged: { updateMenuOpenDrag($0) },
                onEnded: { finishMenuDrag(translation: $0, predicted: $1) }
            )
            .allowsHitTesting(false)

            mainContent
                .environmentObject(scrollBridge)
                .disabled(vm.showSideMenu && isChatStage)
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
        .onChange(of: scenePhase) { _, phase in
            vm.handleScenePhase(phase)
        }
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
        vm.stage == .live
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

    private var canOpenMenuByGesture: Bool {
        isChatStage && vm.managementDestination == nil && !vm.showSideMenu
    }

    private func updateMenuOpenDrag(_ dx: CGFloat) {
        if !isMenuDragging {
            isMenuDragging = true
            menuOpenImpact.prepare()
            // 键盘挡着侧栏很别扭，起手就收起。
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
            )
        }
        menuDragTranslation = max(0, dx)
    }

    /// 侧栏打开后左划关闭。
    private var menuCloseDragGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                guard isChatStage, vm.managementDestination == nil else { return }
                guard vm.showSideMenu || isMenuDragging else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) >= abs(dy) * 0.85 else { return }
                if !isMenuDragging { isMenuDragging = true }
                menuDragTranslation = min(0, dx)
            }
            .onEnded { value in
                guard isMenuDragging else { return }
                finishMenuDrag(
                    translation: value.translation.width,
                    predicted: value.predictedEndTranslation.width
                )
            }
    }

    private func finishMenuDrag(translation: CGFloat, predicted: CGFloat) {
        let threshold = menuWidthCache * 0.28
        let wasOpen = vm.showSideMenu
        let shouldOpen: Bool

        if wasOpen {
            shouldOpen = !(translation < -threshold || predicted < -menuWidthCache * 0.45)
        } else {
            shouldOpen = translation > threshold || predicted > menuWidthCache * 0.45
        }

        if shouldOpen && !wasOpen {
            playSideMenuOpenHaptic()
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

    private func playSideMenuOpenHaptic() {
        menuOpenImpact.impactOccurred()
        menuOpenImpact.prepare()
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
                        // 侧栏已在管理页下方展开，滑出后只需无动画卸页，衔接为一次连续动作。
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            vm.managementDestination = nil
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

/// 管理页 / 聊天顶栏圆形图标按钮：单层实心圆（浅色 / 深色一致）。
/// 放进 Toolbar 时需配合 `eaHideSharedBackground()`，否则系统玻璃底会再套一层圆环。
struct ManagementCircleIconButton: View {
    let systemName: String
    var fontSize: CGFloat = 16
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(EATheme.label)
                .frame(width: 36, height: 36)
                .background(EATheme.surfaceElevated, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

struct ManagementBackButton: View {
    let action: () -> Void

    var body: some View {
        ManagementCircleIconButton(systemName: "chevron.left", fontSize: 15, action: action)
    }
}

extension ToolbarContent {
    /// 隐藏 iOS 26+ 工具栏 Liquid Glass 共享背景，避免与自定义圆形按钮叠成「甜甜圈」。
    ///
    /// `sharedBackgroundVisibility` 属于 iOS 26 SDK：`#available` 只做运行时分支，
    /// 旧版 Xcode（如 15.x / iOS 17 SDK）在编译期就解析不到该符号。
    /// 因此用编译期分支：有新 SDK 时才调用，否则 no-op。
    @ToolbarContentBuilder
    func eaHideSharedBackground() -> some ToolbarContent {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// 聊天列表底层 `UIScrollView` 的桥接口。
///
/// SwiftUI 拿不到滚动阶段（`onScrollPhaseChange` 要 iOS 18），也没法终止惯性减速，
/// 而侧栏手势必须知道列表是否在动、并能在开栏前把它按住，因此下探到 UIKit。
final class ChatScrollBridge: ObservableObject {
    private weak var scrollView: UIScrollView?
    private weak var openPanGesture: UIGestureRecognizer?

    /// 列表正被拖动或处于惯性减速中。
    ///
    /// 这里敢直接读 `isDragging`：开栏手势通过 `require(toFail:)` 排在列表 pan 之前，
    /// 判定时列表 pan 还没可能 began；若探测失败未建立依赖，`scrollView` 为空则一律放行，
    /// 是 fail-open 而非把开栏拦死。
    var isScrolling: Bool {
        guard let scrollView else { return false }
        return scrollView.isDragging || scrollView.isDecelerating
    }

    func attach(scrollView: UIScrollView) {
        guard self.scrollView !== scrollView else { return }
        self.scrollView = scrollView
        linkGestures()
    }

    func attach(openPanGesture: UIGestureRecognizer) {
        guard self.openPanGesture !== openPanGesture else { return }
        self.openPanGesture = openPanGesture
        linkGestures()
    }

    /// 让列表的竖向拖动等侧栏手势判定失败后再开始：一次手势内方向互斥，不会边滚边开栏。
    private func linkGestures() {
        guard let scrollView, let openPanGesture else { return }
        scrollView.panGestureRecognizer.require(toFail: openPanGesture)
    }

    /// 立刻停在当前位置，终止惯性减速。
    func stopScrolling() {
        guard let scrollView, isScrolling else { return }
        // 回弹区内直接定位会把内容卡在越界位置，先夹回合法范围。
        let inset = scrollView.adjustedContentInset
        let minY = -inset.top
        let maxY = max(minY, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
        var offset = scrollView.contentOffset
        offset.y = min(max(offset.y, minY), maxY)
        scrollView.setContentOffset(offset, animated: false)
    }
}

/// 放进聊天列表内容里，向上找到承载它的 `UIScrollView` 并登记到 bridge。
struct ChatScrollViewProbe: UIViewRepresentable {
    let bridge: ChatScrollBridge

    func makeUIView(context: Context) -> UIView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onFind = { [bridge] scrollView in
            bridge.attach(scrollView: scrollView)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class ProbeView: UIView {
        var onFind: ((UIScrollView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var candidate = superview
            while let view = candidate {
                if let scrollView = view as? UIScrollView {
                    onFind?(scrollView)
                    return
                }
                candidate = view.superview
            }
        }
    }
}

/// 右划唤出侧栏的 UIKit 手势。
///
/// 用 `UIPanGestureRecognizer` 而非 SwiftUI `DragGesture`：`UIScrollView` 的 pan 会在极小位移
/// 就抢下手势并锁定竖向，`simultaneousGesture` 挂上去的 DragGesture 常收不到后续更新，
/// 表现就是「列表静止时也很难右划开栏」。
struct SideMenuOpenPanGesture: UIViewRepresentable {
    let bridge: ChatScrollBridge
    let canBegin: () -> Bool
    let onChanged: (CGFloat) -> Void
    let onEnded: (_ translation: CGFloat, _ predicted: CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: bridge, canBegin: canBegin, onChanged: onChanged, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> UIView {
        let view = AttachView()
        view.isUserInteractionEnabled = false
        let coordinator = context.coordinator
        view.onAttach = { host in
            coordinator.attach(to: host)
            bridge.attach(openPanGesture: coordinator.pan)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.canBegin = canBegin
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let bridge: ChatScrollBridge
        var canBegin: () -> Bool
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat, CGFloat) -> Void

        lazy var pan: UIPanGestureRecognizer = {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
            pan.delegate = self
            pan.maximumNumberOfTouches = 1
            // 手势挂在根视图上，默认会压住整个界面的 touchesEnded，让按钮点击显得迟滞。
            pan.delaysTouchesEnded = false
            return pan
        }()

        init(
            bridge: ChatScrollBridge,
            canBegin: @escaping () -> Bool,
            onChanged: @escaping (CGFloat) -> Void,
            onEnded: @escaping (CGFloat, CGFloat) -> Void
        ) {
            self.bridge = bridge
            self.canBegin = canBegin
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func attach(to view: UIView) {
            guard pan.view !== view else { return }
            view.addGestureRecognizer(pan)
        }

        @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
            guard let view = pan.view else { return }
            let dx = pan.translation(in: view).x
            switch pan.state {
            case .began, .changed:
                onChanged(dx)
            case .ended:
                // 对齐 SwiftUI predictedEndTranslation 的口径：按松手速度外推约 0.3s。
                onEnded(dx, dx + pan.velocity(in: view).x * 0.3)
            case .cancelled, .failed:
                onEnded(dx, dx)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer, let view = pan.view else { return false }
            guard canBegin(), !bridge.isScrolling else { return false }
            // 只接明确的右向水平滑动，其余立刻判失败，把手势交还给列表滚动。
            let translation = pan.translation(in: view)
            return translation.x > 0 && translation.x > abs(translation.y) * 1.2
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // 输入框内的横向拖动用于移动光标，不抢。
            var candidate = touch.view
            while let view = candidate {
                if view is UITextView || view is UITextField { return false }
                candidate = view.superview
            }
            return true
        }
    }

    private final class AttachView: UIView {
        var onAttach: ((UIView) -> Void)?

        /// 手势要装在窗口根视图上才能覆盖整个聊天区；自身若铺开成透明层会吃掉底下的点击。
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else { return }
            var host: UIView = self
            while let parent = host.superview, parent !== window {
                host = parent
            }
            onAttach?(host)
        }
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
                .eaHideSharedBackground()
            }
        }
    }
}
