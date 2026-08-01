import SwiftUI
import UIKit

struct ChatView: View {
    @EnvironmentObject private var vm: EasyAccountViewModel
    @FocusState private var inputFocused: Bool
    @StateObject private var speech = SpeechInputController()
    @State private var voiceMode = false
    @State private var isHoldPressing = false
    /// 按住说话时上滑进入取消区。
    @State private var willCancelHold = false
    /// 本次按压手势是否已处理过按下，避免 onChanged 逐帧重复触发。
    @State private var holdGestureBegan = false
    /// 复用同一个发生器并预热，否则临时创建的发生器首次震动会延迟或丢失。
    @State private var holdImpact = UIImpactFeedbackGenerator(style: .medium)
    private let holdCancelDistance: CGFloat = 56

    private let suggestions = [
        "今天午饭花了 35 元",
        "列出我的账户",
        "本月支出概况"
    ]

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
            composer
        }
        .background(EATheme.background.ignoresSafeArea())
    }

    /// 顶部渐隐栏：与页面背景同色，内容滚到下方时沿下沿淡出。
    /// 不用 Material：它在近黑背景上会明显提亮，形成一块可见的色块。
    private var chatHeader: some View {
        HStack {
            ManagementCircleIconButton(systemName: "line.3.horizontal", fontSize: 17) {
                dismissKeyboard()
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

                Text("可以说收支、查余额，或让我帮你整理账本")
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
            }
            .scrollDismissesKeyboard(.interactively)
            // 即使内容不足一屏也允许回弹，短对话可轻微上划。
            .scrollBounceBehavior(.always)
            // 重新打开时默认停在最新消息，而不是历史顶部。
            .defaultScrollAnchor(.bottom)
            .onAppear {
                scrollChatToBottom(proxy: proxy, animated: false)
            }
            .onChange(of: vm.messages) { _, _ in
                scrollChatToBottom(proxy: proxy, animated: true)
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

    private var composer: some View {
        VStack(spacing: 10) {
            if voiceMode, isHoldPressing {
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
        .padding(.top, isHoldPressing ? 8 : 10)
        .padding(.bottom, 10)
        .background(EATheme.background.opacity(0.96))
        .animation(.easeOut(duration: 0.16), value: isHoldPressing)
        .animation(.easeOut(duration: 0.12), value: willCancelHold)
        .onDisappear {
            if speech.isListening {
                speech.cancel()
            }
            isHoldPressing = false
            willCancelHold = false
            holdGestureBegan = false
        }
    }

    /// 默认文字输入（图1）：单条浅色胶囊，左 + / 中输入框 / 右语音（有字时为发送）。
    private var textComposerBar: some View {
        HStack(spacing: 10) {
            composerCircleButton(systemName: "plus") {
                vm.showToast("附件功能即将开放")
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

            if vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if vm.waitingReply {
                    // 仅用户点停止才调服务端 cancel；进后台断连不会走这里。
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
            } else {
                Button {
                    sendFromComposer()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(vm.canSend ? EATheme.blue : EATheme.tertiary)
                        .frame(width: 36, height: 36)
                }
                .disabled(!vm.canSend)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(EATheme.surface)
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(0.06), radius: 8, y: 3)
    }

    /// 语音模式：单条白色胶囊，左 + / 中「按住说话」/ 右键盘；按住后变为蓝色长条。
    ///
    /// 按住期间只改变透明度与背景色、不增删子视图也不改变布局尺寸：
    /// 手势宿主视图一旦被重建，进行中的 DragGesture 会被取消而收不到 onEnded。
    private var voiceComposerBar: some View {
        HStack(spacing: 10) {
            composerCircleButton(systemName: "plus") {
                vm.showToast("附件功能即将开放")
            }
            .opacity(isHoldPressing ? 0 : 1)
            .allowsHitTesting(!isHoldPressing)

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
            .opacity(isHoldPressing ? 0 : 1)
            .allowsHitTesting(!isHoldPressing)
            .disabled(speech.isListening)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(holdBarBackground)
        .clipShape(Capsule())
        .shadow(
            color: Color.black.opacity(isHoldPressing ? 0.08 : 0.06),
            radius: isHoldPressing ? 10 : 8,
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

            Text(willCancelHold ? "松开取消" : "松开发送，上滑取消")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(willCancelHold ? EATheme.danger : EATheme.secondary)
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
        if speech.isListening {
            speech.cancel()
        }
        isHoldPressing = false
        willCancelHold = false
        holdGestureBegan = false
        withAnimation(.easeInOut(duration: 0.15)) {
            voiceMode = false
        }
        inputFocused = true
    }

    private func beginHoldToTalk() {
        guard !isHoldPressing else { return }
        isHoldPressing = true
        willCancelHold = false
        // 先给震动反馈再启动录音，并立刻重新预热以备上滑取消时使用。
        holdImpact.impactOccurred()
        holdImpact.prepare()
        do {
            try speech.start()
        } catch {
            isHoldPressing = false
            willCancelHold = false
            vm.showToast((error as? LocalizedError)?.errorDescription ?? "无法开始语音识别")
        }
    }

    private func endHoldToTalk() {
        guard isHoldPressing else { return }
        let cancel = willCancelHold
        isHoldPressing = false
        willCancelHold = false

        if cancel {
            speech.cancel()
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            vm.showToast("已取消")
            return
        }

        let spoken = speech.stop()
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()

        let text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            vm.showToast("没有识别到内容，请再试一次")
            return
        }

        // 松开发送：直接发出，保持语音模式便于连续说下一条。
        vm.inputText = text
        vm.sendChat()
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
        let text = vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        dismissKeyboard()
        vm.sendChat()
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
    let message: ChatMessage
    var onUserShortTap: (() -> Void)? = nil
    var onUserLongPressCopy: (() -> Void)? = nil

    var body: some View {
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
            .background(EATheme.surface)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 18,
                    bottomLeadingRadius: 6,
                    bottomTrailingRadius: 18,
                    topTrailingRadius: 18,
                    style: .continuous
                )
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 40)

        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                Text(message.text)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(EATheme.blue.opacity(message.pending ? 0.72 : 1))
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 18,
                            bottomLeadingRadius: 18,
                            bottomTrailingRadius: 6,
                            topTrailingRadius: 18,
                            style: .continuous
                        )
                    )
                    .contentShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 18,
                            bottomLeadingRadius: 18,
                            bottomTrailingRadius: 6,
                            topTrailingRadius: 18,
                            style: .continuous
                        )
                    )
                    .onTapGesture {
                        onUserShortTap?()
                    }
                    .onLongPressGesture(minimumDuration: 0.35) {
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
}
