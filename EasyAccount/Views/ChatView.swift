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
    private let holdCancelDistance: CGFloat = 56

    private let suggestions = [
        "今天午饭花了 35 元",
        "列出我的账户",
        "本月支出概况"
    ]

    var body: some View {
        VStack(spacing: 0) {
            chatHeader

            ZStack {
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
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
        .background(EATheme.background.ignoresSafeArea())
    }

    private var chatHeader: some View {
        HStack {
            Button {
                dismissKeyboard()
                withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                    vm.showSideMenu = true
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(EATheme.label)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(EATheme.background.opacity(0.96))
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
                        .disabled(vm.waitingReply)
                        .opacity(vm.waitingReply ? 0.45 : 1)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 8)

                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
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
                .padding(.vertical, 12)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: vm.messages) { _, _ in
                if let last = vm.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
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
            .disabled(vm.isComposerEditingDisabled)
            .focused($inputFocused)
            .font(.system(size: 16))
            .foregroundStyle(EATheme.label)
            .onSubmit {
                sendFromComposer()
            }

            if vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                composerCircleButton(systemName: "dot.radiowaves.right") {
                    Task { await enterVoiceMode() }
                }
                .disabled(vm.waitingReply)
                .opacity(vm.waitingReply ? 0.45 : 1)
            } else {
                Button {
                    sendFromComposer()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(vm.canSend ? EATheme.blue : EATheme.tertiary)
                        .frame(width: 36, height: 36)
                }
                .disabled(vm.waitingReply || vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    private var voiceComposerBar: some View {
        HStack(spacing: 10) {
            if !isHoldPressing {
                composerCircleButton(systemName: "plus") {
                    vm.showToast("附件功能即将开放")
                }
                .transition(.opacity)
            }

            Group {
                if isHoldPressing {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                } else {
                    Text("按住说话")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(EATheme.label)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
            }
            .contentShape(Rectangle())
            .gesture(holdToTalkGesture)
            .disabled(vm.waitingReply)

            if !isHoldPressing {
                composerCircleButton(systemName: "keyboard") {
                    exitVoiceMode()
                }
                .disabled(speech.isListening)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, isHoldPressing ? 0 : 8)
        .padding(.vertical, isHoldPressing ? 0 : 6)
        .background(holdBarBackground)
        .clipShape(Capsule())
        .shadow(
            color: Color.black.opacity(isHoldPressing ? 0.08 : 0.06),
            radius: isHoldPressing ? 10 : 8,
            y: 3
        )
        .opacity(vm.waitingReply ? 0.45 : 1)
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
                if !isHoldPressing {
                    beginHoldToTalk()
                }
                guard isHoldPressing else { return }
                let canceling = value.translation.height < -holdCancelDistance
                if canceling != willCancelHold {
                    willCancelHold = canceling
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }
            .onEnded { _ in
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
        withAnimation(.easeInOut(duration: 0.15)) {
            voiceMode = false
        }
        inputFocused = true
    }

    private func beginHoldToTalk() {
        // 断连时也允许语音录入；发送仍走队列/连接校验。
        guard !vm.waitingReply, !isHoldPressing else { return }
        isHoldPressing = true
        willCancelHold = false
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
        guard !text.isEmpty, !vm.waitingReply else { return }
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

/// 右上角 WebSocket 连接状态圆点：绿=已连接，黄闪=连接中，红=断开。
struct ConnectionStatusDot: View {
    enum Kind: Equatable {
        case connected
        case connecting
        case disconnected
    }

    let kind: Kind

    @State private var blinkBright = false

    private var dotColor: Color {
        switch kind {
        case .connected: return EATheme.green
        case .connecting: return Color(red: 1.0, green: 0.78, blue: 0.12)
        case .disconnected: return EATheme.danger
        }
    }

    private var accessibilityText: String {
        switch kind {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .disconnected: return "已断开"
        }
    }

    var body: some View {
        ZStack {
            // 外层柔光
            Circle()
                .fill(dotColor.opacity(0.55))
                .frame(width: 16, height: 16)
                .blur(radius: 4.5)
                .opacity(glowOpacity)

            // 中层光晕
            Circle()
                .fill(dotColor.opacity(0.35))
                .frame(width: 12, height: 12)
                .blur(radius: 1.2)
                .opacity(glowOpacity)

            // 实心圆点 + 高光
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.95),
                            dotColor,
                            dotColor.opacity(0.85)
                        ],
                        center: UnitPoint(x: 0.32, y: 0.28),
                        startRadius: 0,
                        endRadius: 6
                    )
                )
                .frame(width: 8, height: 8)
                .shadow(color: dotColor.opacity(0.85), radius: 4.5, x: 0, y: 0)
                .opacity(coreOpacity)
        }
        .frame(width: 22, height: 22)
        .accessibilityLabel(accessibilityText)
        .onAppear { updateBlink() }
        .onChange(of: kind) { _, _ in
            updateBlink()
        }
    }

    private var glowOpacity: Double {
        switch kind {
        case .connected: return 0.85
        case .connecting: return blinkBright ? 1.0 : 0.2
        case .disconnected: return 0.7
        }
    }

    private var coreOpacity: Double {
        switch kind {
        case .connected, .disconnected: return 1
        case .connecting: return blinkBright ? 1.0 : 0.28
        }
    }

    private func updateBlink() {
        blinkBright = false
        guard kind == .connecting else { return }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            blinkBright = true
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
            .accessibilityHint(message.pending ? "待连接恢复后自动发送" : "轻点回填到输入框，长按复制")

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
