import PhotosUI
import SwiftUI
import UIKit

struct ChatView: View {
    @EnvironmentObject private var vm: EasyAccountViewModel
    @EnvironmentObject private var scrollBridge: ChatScrollBridge
    @FocusState private var inputFocused: Bool
    @StateObject private var speech = SpeechInputController()
    @State private var voiceMode = false
    @State private var isHoldPressing = false
    /// 按住说话时上滑进入取消区。
    @State private var willCancelHold = false
    /// 本次按压手势是否已处理过按下，避免 onChanged 逐帧重复触发。
    @State private var holdGestureBegan = false
    /// 本次按下开始时间；用于区分点按（松手立刻取消）与有效按住。
    @State private var holdPressStartedAt: Date?
    /// 复用同一个发生器并预热，否则临时创建的发生器首次震动会延迟或丢失。
    @State private var holdImpact = UIImpactFeedbackGenerator(style: .medium)
    private let holdCancelDistance: CGFloat = 56
    /// 按住短于此阈值视为点按：按下已即时开录，松手静默取消且不发送。
    private let holdTapMaxDuration: TimeInterval = 0.2

    @State private var showAttachMenu = false
    @State private var showPhotoPicker = false
    @State private var showCameraPicker = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var previewImage: UIImage?

    private var suggestions: [String] {
        if vm.needsOnboarding {
            return [
                "建个微信，余额 200",
                "建个招行信用卡",
                "我有哪些分类"
            ]
        }
        return [
            "今天午饭花了 35 元",
            "列出我的账户",
            "本月支出概况"
        ]
    }

    /// 顶部玻璃栏内容区高度（不含状态栏），用于给滚动内容留出起始间距。
    private let chatHeaderContentHeight: CGFloat = 52

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if vm.messages.isEmpty {
                    emptyGreeting
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    messageList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .simultaneousGesture(dismissKeyboardDrag)

            chatHeader
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if vm.needsOnboarding {
                    onboardingHintBar
                }
                composer
            }
        }
        .background(EATheme.background.ignoresSafeArea())
        .sheet(isPresented: $showAttachMenu) {
            ChatAttachSheet(
                isPresented: $showAttachMenu,
                remainingSlots: vm.remainingDraftAttachmentSlots,
                onPickRecent: { image in
                    guard vm.remainingDraftAttachmentSlots > 0 else {
                        vm.showToast("最多添加 \(ChatAttachmentLimits.maxCount) 张图片")
                        return
                    }
                    vm.addDraftImages([image])
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    // 选完一张即回到聊天页，便于继续打字或再点加号追加。
                    showAttachMenu = false
                    DispatchQueue.main.async {
                        inputFocused = true
                    }
                },
                onPhotos: {
                    showAttachMenu = false
                    guard vm.remainingDraftAttachmentSlots > 0 else {
                        vm.showToast("最多添加 \(ChatAttachmentLimits.maxCount) 张图片")
                        return
                    }
                    // 等 sheet 收起再弹系统相册，避免多层模态抢焦点。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showPhotoPicker = true
                    }
                },
                onCamera: {
                    showAttachMenu = false
                    guard vm.remainingDraftAttachmentSlots > 0 else {
                        vm.showToast("最多添加 \(ChatAttachmentLimits.maxCount) 张图片")
                        return
                    }
                    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                        vm.showToast("当前设备无法使用相机")
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showCameraPicker = true
                    }
                },
                onFiles: {
                    vm.showToast("文件附件即将开放")
                }
            )
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoPickerItems,
            maxSelectionCount: max(1, vm.remainingDraftAttachmentSlots),
            matching: .images
        )
        .onChange(of: photoPickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPhotoPickerItems(items) }
        }
        .fullScreenCover(isPresented: $showCameraPicker) {
            CameraImagePicker(
                onImage: { image in
                    showCameraPicker = false
                    vm.addDraftImages([image])
                    // 选完图后回到输入框，方便继续补文字说明。
                    DispatchQueue.main.async {
                        inputFocused = true
                    }
                },
                onCancel: {
                    showCameraPicker = false
                }
            )
            .ignoresSafeArea()
        }
        .fullScreenCover(item: previewImageBinding) { item in
            ChatAttachmentPreviewView(image: item.image) {
                previewImage = nil
            }
        }
    }

    /// 将可选 UIImage 适配为 fullScreenCover(item:)。
    private var previewImageBinding: Binding<PreviewableImage?> {
        Binding(
            get: { previewImage.map { PreviewableImage(image: $0) } },
            set: { previewImage = $0?.image }
        )
    }

    /// 顶部渐隐栏：与页面背景同色，内容滚到下方时沿下沿淡出。
    /// 不用 Material：它在近黑背景上会明显提亮，形成一块可见的色块。
    private var chatHeader: some View {
        HStack {
            ManagementCircleIconButton(systemName: "line.3.horizontal", fontSize: 17) {
                dismissKeyboard()
                if !vm.showSideMenu {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                // 顶栏浮在列表之上，点它不会打断惯性；不手动按住的话侧栏滑出时列表还在自己滚。
                scrollBridge.stopScrolling()
                withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                    vm.showSideMenu = true
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // 渐变终点用同色的 0 透明度而非 .clear，避免插值经过灰色产生暗带。
            LinearGradient(
                stops: [
                    .init(color: EATheme.background, location: 0),
                    .init(color: EATheme.background, location: 0.68),
                    .init(color: EATheme.background.opacity(0), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        }
    }

    private var emptyGreeting: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 40)

                VStack(spacing: 10) {
                    Text(vm.greetingLines.0)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(EATheme.label)
                    Text(vm.greetingLines.1)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(EATheme.label)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

                Text(
                    vm.needsOnboarding
                        ? "先和助手聊聊建个账户，建好后就可以记账了"
                        : "可以说收支、查余额，或让我帮你整理账本"
                )
                    .font(.system(size: 14))
                    .foregroundStyle(EATheme.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                VStack(spacing: 10) {
                    ForEach(suggestions, id: \.self) { text in
                        Button {
                            dismissKeyboard()
                            vm.sendSuggestion(text)
                        } label: {
                            Text(text)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(EATheme.label)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 13)
                                .background(EATheme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 8)

                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, chatHeaderContentHeight)
            .background(ChatScrollViewProbe(bridge: scrollBridge))
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.always)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(vm.messages) { message in
                        MessageBubble(
                            message: message,
                            onUserShortTap: {
                                reuseUserMessage(message.text)
                            },
                            onUserLongPressCopy: {
                                copyUserMessage(message.text)
                            }
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, chatHeaderContentHeight + 8)
                .padding(.bottom, 12)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .background(ChatScrollViewProbe(bridge: scrollBridge))
            }
            .scrollDismissesKeyboard(.interactively)
            // 即使内容不足一屏也允许回弹，短对话可轻微上划。
            .scrollBounceBehavior(.always)
            .eaChatScrollAnchors()
            .onAppear {
                scrollChatToBottom(proxy: proxy, animated: false)
            }
            .onChange(of: vm.messages) { _, _ in
                scrollChatToBottom(proxy: proxy, animated: true)
            }
            // 语音 ↔ 文字切换会改底部 inset；键盘弹出时 LazyVStack 偶发把位置重置到顶部。
            .onChange(of: voiceMode) { _, _ in
                pinChatToLatestAfterLayoutChange(proxy: proxy)
            }
            .onChange(of: inputFocused) { _, focused in
                guard focused else { return }
                pinChatToLatestAfterLayoutChange(proxy: proxy)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                scrollChatToBottom(proxy: proxy, animated: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                scrollChatToBottom(proxy: proxy, animated: false)
            }
        }
    }

    private func scrollChatToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard let lastId = vm.messages.last?.id else { return }
        // 等 LazyVStack 完成布局再滚，避免首次打开仍停在顶部。
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }

    /// 底部栏/键盘动画过程中多钉几次，避免停在历史顶部。
    private func pinChatToLatestAfterLayoutChange(proxy: ScrollViewProxy) {
        scrollChatToBottom(proxy: proxy, animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            scrollChatToBottom(proxy: proxy, animated: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            scrollChatToBottom(proxy: proxy, animated: false)
        }
    }

    /// 仅手指按住时展示录制 UI；松手后的续录/出最终结果在后台进行。
    private var isVoiceCaptureActive: Bool {
        isHoldPressing
    }

    /// 无账户时的轻提示（非全屏向导）；建账户后随 onboarding 刷新自动消失。
    private var onboardingHintBar: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(EATheme.cyan)
                .padding(.top, 2)
            Text("先建一个账户才能记账，跟我说「建个微信，余额 200」也可以。")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(EATheme.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(EATheme.surfaceElevated.opacity(0.92))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(EATheme.surface)
                .frame(height: 1)
        }
    }

    private var composer: some View {
        VStack(spacing: 10) {
            if voiceMode, isVoiceCaptureActive {
                voiceRecordingHint
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if voiceMode {
                voiceComposerBar
            } else {
                textComposerBar
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, isVoiceCaptureActive ? 8 : 10)
        .padding(.bottom, 10)
        .background(EATheme.background.opacity(0.96))
        .animation(.easeOut(duration: 0.16), value: isVoiceCaptureActive)
        .animation(.easeOut(duration: 0.12), value: willCancelHold)
        .onDisappear {
            if speech.isListening || speech.isFinalizing {
                speech.cancel()
            }
            isHoldPressing = false
            willCancelHold = false
            holdGestureBegan = false
            holdPressStartedAt = nil
        }
    }

    /// 文字输入：有待命附件时为圆角卡片（Cursor 式顶部缩略图 + 输入行）；否则保持胶囊。
    private var textComposerBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !vm.draftAttachments.isEmpty {
                attachmentStagingRow
            }

            HStack(spacing: 10) {
                composerCircleButton(systemName: "plus") {
                    presentAttachMenu()
                }

                TextField(
                    vm.composerPlaceholder,
                    text: $vm.inputText,
                    axis: .vertical
                )
                .lineLimit(1...5)
                .focused($inputFocused)
                .font(.system(size: 16))
                .foregroundStyle(EATheme.label)
                .onSubmit {
                    sendFromComposer()
                }

                composerTrailingActions
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(EATheme.surface)
        .clipShape(
            RoundedRectangle(
                cornerRadius: vm.draftAttachments.isEmpty ? 28 : 22,
                style: .continuous
            )
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, y: 3)
        .animation(.easeOut(duration: 0.18), value: vm.draftAttachments.count)
    }

    private var attachmentStagingRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(vm.draftAttachments) { draft in
                    DraftAttachmentThumbnail(
                        image: draft.image,
                        onTap: { previewImage = draft.image },
                        onRemove: { vm.removeDraftAttachment(id: draft.id) }
                    )
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 8)
        }
    }

    @ViewBuilder
    private var composerTrailingActions: some View {
        if vm.canSend {
            Button {
                sendFromComposer()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(EATheme.blue)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("发送")
        } else if vm.waitingReply {
            Button {
                vm.stopGeneration()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(EATheme.label)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("停止生成")
        } else {
            composerCircleButton(systemName: "dot.radiowaves.right") {
                Task { await enterVoiceMode() }
            }
        }
    }

    /// 语音模式：单条白色胶囊，左 + / 中「按住说话」/ 右键盘；按住后变为蓝色长条。
    ///
    /// 按住期间只改变透明度与背景色、不增删子视图也不改变布局尺寸：
    /// 手势宿主视图一旦被重建，进行中的 DragGesture 会被取消而收不到 onEnded。
    private var voiceComposerBar: some View {
        HStack(spacing: 10) {
            composerCircleButton(systemName: "plus") {
                presentAttachMenu()
            }
            .opacity(isVoiceCaptureActive ? 0 : 1)
            .allowsHitTesting(!isVoiceCaptureActive)

            Text("按住说话")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(EATheme.label)
                .opacity(isHoldPressing ? 0 : 1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
                .gesture(holdToTalkGesture)

            composerCircleButton(systemName: "keyboard") {
                exitVoiceMode()
            }
            .opacity(isVoiceCaptureActive ? 0 : 1)
            .allowsHitTesting(!isVoiceCaptureActive)
            .disabled(isHoldPressing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(holdBarBackground)
        .clipShape(Capsule())
        .shadow(
            color: Color.black.opacity(isVoiceCaptureActive ? 0.08 : 0.06),
            radius: isVoiceCaptureActive ? 10 : 8,
            y: 3
        )
    }

    private var holdBarBackground: Color {
        if !isHoldPressing { return EATheme.surface }
        return willCancelHold ? EATheme.secondary : EATheme.blue
    }

    private var voiceRecordingHint: some View {
        VStack(spacing: 10) {
            VoiceSoundWaveView(isActive: isHoldPressing, isCanceling: willCancelHold)
                .frame(height: 40)

            // 与 Cursor iOS 一致：按住时展示实时转写，而不是空等松手。
            Group {
                if willCancelHold {
                    Text("松开取消")
                } else if speech.partialText.isEmpty {
                    Text("松开发送，上滑取消")
                } else {
                    Text(speech.partialText)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(willCancelHold ? EATheme.danger : EATheme.secondary)
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.12), value: speech.partialText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func composerCircleButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(EATheme.label)
                .frame(width: 36, height: 36)
                .background(EATheme.surfaceElevated)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var holdToTalkGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if !holdGestureBegan {
                    holdGestureBegan = true
                    // Cursor 式：按下立刻开录 + 实时转写，不做启动延迟。
                    beginHoldToTalk()
                }
                guard isHoldPressing else { return }
                let canceling = value.translation.height < -holdCancelDistance
                if canceling != willCancelHold {
                    willCancelHold = canceling
                    holdImpact.impactOccurred()
                    holdImpact.prepare()
                }
            }
            .onEnded { _ in
                holdGestureBegan = false
                guard isHoldPressing else { return }
                endHoldToTalk()
            }
    }

    private func enterVoiceMode() async {
        dismissKeyboard()
        let allowed = await speech.requestPermissions()
        guard allowed else {
            vm.showToast(SpeechInputError.permissionDenied.localizedDescription)
            return
        }
        guard speech.isAvailable else {
            vm.showToast(SpeechInputError.recognizerUnavailable.localizedDescription)
            return
        }
        holdImpact.prepare()
        withAnimation(.easeInOut(duration: 0.15)) {
            voiceMode = true
        }
    }

    private func exitVoiceMode() {
        if speech.isListening || speech.isFinalizing {
            speech.cancel()
        }
        isHoldPressing = false
        willCancelHold = false
        holdGestureBegan = false
        holdPressStartedAt = nil
        withAnimation(.easeInOut(duration: 0.15)) {
            voiceMode = false
        }
        inputFocused = true
    }

    private func beginHoldToTalk() {
        guard !isHoldPressing else { return }
        isHoldPressing = true
        willCancelHold = false
        holdPressStartedAt = Date()
        // 先给震动反馈再启动录音，并立刻重新预热以备上滑取消时使用。
        holdImpact.impactOccurred()
        holdImpact.prepare()
        do {
            // start() 内部会 cancel 上一轮后台续录，避免两路识别打架。
            try speech.start()
        } catch {
            isHoldPressing = false
            willCancelHold = false
            holdPressStartedAt = nil
            vm.showToast((error as? LocalizedError)?.errorDescription ?? "无法开始语音识别")
        }
    }

    private func endHoldToTalk() {
        guard isHoldPressing else { return }
        let cancelBySwipe = willCancelHold
        let pressDuration = holdPressStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let cancelByTap = pressDuration < holdTapMaxDuration
        // 先收起录制 UI；点按/上滑取消不进入后台续录。
        isHoldPressing = false
        willCancelHold = false
        holdPressStartedAt = nil

        if cancelBySwipe || cancelByTap {
            speech.cancel()
            if cancelBySwipe {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                vm.showToast("已取消")
            }
            // 点按：静默取消，不弹 toast（与 Cursor 误触忽略一致）。
            return
        }

        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        // 松手后续录约 1.2s 并等待最终结果，减少句尾丢字；界面已恢复「按住说话」。
        Task {
            let spoken = await speech.finish(tailSeconds: 1.2)
            // 若期间又按住开了新一轮，finish 会被 cancel，不再弹失败提示。
            guard !speech.isListening, !isHoldPressing else { return }
            let text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                vm.showToast("没有识别到内容，请再试一次")
                return
            }
            // 松开发送：直接发出，保持语音模式便于连续说下一条。
            vm.inputText = text
            vm.sendChat()
        }
    }

    private var dismissKeyboardDrag: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onChanged { value in
                guard inputFocused, value.translation.height > 24 else { return }
                dismissKeyboard()
            }
    }

    private func dismissKeyboard() {
        inputFocused = false
    }

    private func sendFromComposer() {
        guard vm.canSend else { return }
        dismissKeyboard()
        vm.sendChat()
    }

    private func presentAttachMenu() {
        if voiceMode {
            // 回到文字输入以便看到待命缩略图。
            if speech.isListening || speech.isFinalizing {
                speech.cancel()
            }
            isHoldPressing = false
            willCancelHold = false
            holdGestureBegan = false
            holdPressStartedAt = nil
            withAnimation(.easeInOut(duration: 0.15)) {
                voiceMode = false
            }
        }
        showAttachMenu = true
    }

    @MainActor
    private func loadPhotoPickerItems(_ items: [PhotosPickerItem]) async {
        defer { photoPickerItems = [] }
        var images: [UIImage] = []
        for item in items {
            guard vm.draftAttachments.count + images.count < ChatAttachmentLimits.maxCount else { break }
            if let picked = try? await item.loadTransferable(type: ChatPickedImage.self) {
                images.append(picked.image)
            }
        }
        if !images.isEmpty {
            vm.addDraftImages(images)
            // 选完图后回到输入框，方便继续补文字说明。
            inputFocused = true
        } else if !items.isEmpty {
            vm.showToast("无法读取所选图片")
        }
    }

    /// 短按用户气泡：把内容回填到输入框以便重新编辑发送。
    private func reuseUserMessage(_ text: String) {
        vm.inputText = text
        inputFocused = true
    }

    /// 长按用户气泡：复制到剪贴板。
    private func copyUserMessage(_ text: String) {
        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        vm.showToast("已复制")
    }
}

private struct PreviewableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

private extension View {
    /// 聊天列表：长对话初始停在底部；iOS 18+ 短内容仍按顶部对齐，避免整块贴底难读。
    @ViewBuilder
    func eaChatScrollAnchors() -> some View {
        if #available(iOS 18.0, *) {
            self.defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(.top, for: .alignment)
        } else {
            self.defaultScrollAnchor(.bottom)
        }
    }
}

/// 按住说话时的蓝色声波提示（取消态变为灰色）。
struct VoiceSoundWaveView: View {
    var isActive: Bool
    var isCanceling: Bool

    private let barCount = 28

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(isCanceling ? EATheme.tertiary : EATheme.blue)
                        .frame(width: 3, height: barHeight(index: index, time: t))
                }
            }
            .frame(maxWidth: 220)
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.12), value: isCanceling)
        }
        .accessibilityHidden(true)
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        let center = Double(barCount - 1) / 2
        let distance = abs(Double(index) - center) / center
        let envelope = max(0.2, 1 - distance * 0.85)
        let wave = abs(sin(time * 9.5 + Double(index) * 0.62))
        let secondary = abs(sin(time * 5.2 + Double(index) * 1.1)) * 0.35
        return max(4, CGFloat((wave + secondary) * 30 * envelope + 4))
    }
}

struct MessageBubble: View {
    @EnvironmentObject private var vm: EasyAccountViewModel
    let message: ChatMessage
    var onUserShortTap: (() -> Void)? = nil
    var onUserLongPressCopy: (() -> Void)? = nil
    @State private var previewImage: UIImage?
    @State private var previewLoadingId: String?

    var body: some View {
        bubbleContent
            .fullScreenCover(item: previewBinding) { item in
                ChatAttachmentPreviewView(image: item.image) {
                    previewImage = nil
                }
            }
    }

    private var previewBinding: Binding<PreviewableImage?> {
        Binding(
            get: { previewImage.map { PreviewableImage(image: $0) } },
            set: { previewImage = $0?.image }
        )
    }

    private var showsUserTextBubble: Bool {
        let text = message.text
        guard !text.isEmpty else { return false }
        if text == "【图片】", !message.attachments.isEmpty { return false }
        return true
    }

    @ViewBuilder
    private var bubbleContent: some View {
        switch message.kind {
        case .system:
            Text(message.text)
                .font(.system(size: 12))
                .foregroundStyle(EATheme.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(EATheme.surfaceElevated)
                .clipShape(Capsule())
                .frame(maxWidth: .infinity, alignment: .center)

        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                Text("记账助手")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(EATheme.cyan)
                    .tracking(0.4)
                Text(message.text + (message.streaming ? "▍" : ""))
                    .font(.system(size: 16))
                    .foregroundStyle(EATheme.label)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(EATheme.assistantBubble)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 18,
                    bottomLeadingRadius: 6,
                    bottomTrailingRadius: 18,
                    topTrailingRadius: 18,
                    style: .continuous
                )
            )
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: 18,
                    bottomLeadingRadius: 6,
                    bottomTrailingRadius: 18,
                    topTrailingRadius: 18,
                    style: .continuous
                )
                .strokeBorder(EATheme.assistantBubbleStroke, lineWidth: 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 40)

        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                // 图片 + 文字合进同一条用户气泡，避免缩略图条与文字分居左右。
                userCombinedBubble
                    .onTapGesture {
                        guard showsUserTextBubble else { return }
                        onUserShortTap?()
                    }
                    .onLongPressGesture(minimumDuration: 0.35) {
                        guard showsUserTextBubble else { return }
                        onUserLongPressCopy?()
                    }

                if message.pending {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10, weight: .semibold))
                        Text("待发送")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(EATheme.secondary)
                    .padding(.trailing, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
            .accessibilityHint(message.pending ? "等待上一条回复结束后自动发送" : "轻点回填到输入框，长按复制")

        case .error:
            Text(message.text)
                .font(.system(size: 14))
                .foregroundStyle(EATheme.danger)
                .padding(12)
                .background(EATheme.danger.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var userCombinedBubble: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 18,
            bottomLeadingRadius: 18,
            bottomTrailingRadius: 6,
            topTrailingRadius: 18,
            style: .continuous
        )

        return VStack(alignment: .leading, spacing: 8) {
            if !message.attachments.isEmpty {
                userAttachmentStrip(message.attachments)
            }

            if showsUserTextBubble {
                Text(message.text)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .frame(maxWidth: 252, alignment: .leading)
            }
        }
        .padding(.horizontal, message.attachments.isEmpty ? 14 : 10)
        .padding(.vertical, message.attachments.isEmpty ? 10 : 8)
        .background(EATheme.blue.opacity(message.pending ? 0.72 : 1))
        .clipShape(shape)
        .contentShape(shape)
    }

    /// 对话内只渲染本地缩略图；点按再异步拉原图（本地缓存优先，否则请求服务端）。
    @ViewBuilder
    private func userAttachmentStrip(_ attachments: [ChatMessageAttachment]) -> some View {
        let thumb: CGFloat = 72
        if !attachments.isEmpty {
            Group {
                if attachments.count <= 3 {
                    HStack(spacing: 6) {
                        ForEach(attachments) { attachment in
                            userAttachmentThumbnail(attachment, size: thumb)
                        }
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(attachments) { attachment in
                                userAttachmentThumbnail(attachment, size: thumb)
                            }
                        }
                    }
                }
            }
        }
    }

    private func userAttachmentThumbnail(_ attachment: ChatMessageAttachment, size: CGFloat) -> some View {
        UserAttachmentThumbnailView(
            attachment: attachment,
            size: size,
            isPreviewLoading: previewLoadingId == attachment.id,
            onTap: { openAttachmentPreview(attachment) }
        )
        .disabled(previewLoadingId != nil)
    }

    private func openAttachmentPreview(_ attachment: ChatMessageAttachment) {
        guard previewLoadingId == nil else { return }
        previewLoadingId = attachment.id
        Task {
            let image = await vm.loadPreviewImage(for: attachment)
            await MainActor.run {
                previewLoadingId = nil
                if let image {
                    previewImage = image
                } else {
                    vm.showToast("无法打开图片")
                }
            }
        }
    }
}

/// 列表缩略图：本地命中直接显示；被 30 天清理后按 remoteId 向服务端补拉。
private struct UserAttachmentThumbnailView: View {
    @EnvironmentObject private var vm: EasyAccountViewModel
    let attachment: ChatMessageAttachment
    let size: CGFloat
    var isPreviewLoading: Bool
    var onTap: () -> Void

    @State private var image: UIImage?
    @State private var loadingRemote = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipped()
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                        .frame(width: size, height: size)
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.white.opacity(0.85))
                        }
                }

                if isPreviewLoading || loadingRemote {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.28))
                        .frame(width: size, height: size)
                    ProgressView()
                        .tint(.white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .task(id: attachment.id) {
            image = vm.thumbnailImage(for: attachment)
            guard image == nil else { return }
            loadingRemote = true
            image = await vm.ensureThumbnailImage(for: attachment)
            loadingRemote = false
        }
    }
}
