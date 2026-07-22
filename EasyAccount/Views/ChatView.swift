import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var vm: EasyAccountViewModel
    @FocusState private var inputFocused: Bool

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

            composer
        }
        .background(EATheme.background.ignoresSafeArea())
    }

    private var chatHeader: some View {
        HStack {
            Button {
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

            Spacer()

            if !vm.connected {
                HStack(spacing: 6) {
                    Circle()
                        .fill(EATheme.orange)
                        .frame(width: 7, height: 7)
                    Text("连接中")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(EATheme.secondary)
                }
                .padding(.trailing, 8)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(EATheme.background.opacity(0.96))
    }

    private var emptyGreeting: some View {
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
                    .disabled(!vm.connected || vm.waitingReply)
                    .opacity(vm.connected && !vm.waitingReply ? 1 : 0.45)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)

            Spacer()
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(vm.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
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
        HStack(alignment: .center, spacing: 10) {
            Button {
                vm.showToast("附件功能即将开放")
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(EATheme.label)
                    .frame(width: 36, height: 36)
                    .background(EATheme.surfaceElevated)
                    .clipShape(Circle())
            }
            .buttonStyle(PressableButtonStyle())

            HStack(spacing: 8) {
                TextField(
                    vm.waitingReply ? "助手正在回复…" : "随便问，记账、图片也可以",
                    text: $vm.inputText,
                    axis: .vertical
                )
                .lineLimit(1...5)
                .disabled(vm.waitingReply || !vm.connected)
                .focused($inputFocused)
                .font(.system(size: 16))
                .foregroundStyle(EATheme.label)
                .onSubmit {
                    if vm.canSend { vm.sendChat() }
                }

                if vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        vm.showToast("语音输入即将开放")
                    } label: {
                        Image(systemName: "waveform")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(EATheme.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        vm.sendChat()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(vm.canSend ? EATheme.blue : EATheme.tertiary)
                    }
                    .disabled(!vm.canSend)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(EATheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(EATheme.background.opacity(0.96))
    }
}

struct MessageBubble: View {
    let message: ChatMessage

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
            Text(message.text)
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(EATheme.blue)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 18,
                        bottomLeadingRadius: 18,
                        bottomTrailingRadius: 6,
                        topTrailingRadius: 18,
                        style: .continuous
                    )
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 40)

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
