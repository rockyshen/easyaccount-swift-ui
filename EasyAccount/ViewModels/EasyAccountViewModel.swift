import Foundation
import Combine
import SwiftUI

enum AppStage: Equatable {
    case bootstrapping
    case login
    case live
}

enum AuthMode: Equatable {
    case login
    case register
}

enum LoginRoute: Equatable {
    case landing
    case phone
    case phoneCode
    case accountPassword
}

enum ManagementDestination: String, Identifiable, Equatable {
    case accounts
    case categories
    case dashboard
    case scheduledTasks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accounts: return "账户管理"
        case .categories: return "分类管理"
        case .dashboard: return "概览分析"
        case .scheduledTasks: return "定时任务"
        }
    }
}

@MainActor
final class EasyAccountViewModel: ObservableObject {
    @Published var stage: AppStage = .bootstrapping
    @Published var authMode: AuthMode = .login
    @Published var authError: String = ""
    @Published var loginName: String = ""
    @Published var loginPassword: String = ""
    @Published var showPassword: Bool = false
    @Published var loginBusy: Bool = false
    @Published var showAdvanced: Bool = false

    @Published var loginRoute: LoginRoute = .landing
    @Published var agreedToTerms: Bool = false
    @Published var phoneNumber: String = ""
    @Published var verifyCode: String = ""
    @Published var countryCode: String = "+86"
    @Published var toastMessage: String = ""
    @Published var showSideMenu: Bool = false
    @Published var managementDestination: ManagementDestination?
    @Published var appearanceMode: AppearanceMode

    @Published var httpBase: String

    @Published var currentUser: AuthUser?
    /// 已登录可用（SSE 无长连接；用于侧栏「在线」与状态灯）。
    @Published var connected: Bool = false
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var waitingReply: Bool = false

    private var token: String = ""
    private let chatClient = ChatSSEClient()
    private var streamingMsgId: Int?
    private var sessionInvalidHandled = false
    private var toastTask: Task<Void, Never>?
    private var replyTimeoutTask: Task<Void, Never>?
    private var chatTask: Task<Void, Never>?
    /// 轮次世代：忽略被替换/取消的上一轮 SSE 回调，避免误伤新一轮。
    private var chatGeneration = 0
    /// 回复进行中继续发送时的出站队列（按消息 id 保序）。
    private var pendingOutboundIds: [Int] = []
    /// 当前正在通过 SSE 发送的用户消息 id（用于 409 时重新入队）。
    private var currentOutboundMessageId: Int?
    /// 本轮流游标（断点续传）。
    private var activeStreamId: String?
    private var lastEventId: Int64 = 0
    /// 本地主动断连以待回前台续传；此时 `.cancelled` 不应定稿失败。
    private var disconnectForResume = false
    /// 避免进前台重复 bootstrap 把聊天页卸掉。
    private var didBootstrap = false
    private var persistChatTask: Task<Void, Never>?

    /// 与服务端约 300s 超时对齐。
    private let replyTimeoutNanoseconds: UInt64 = 300_000_000_000

    private var chatStorageUserId: String {
        if let id = currentUser?.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return id
        }
        let name = currentUser?.displayName ?? ""
        if !name.isEmpty { return "name:\(name)" }
        return "anonymous"
    }

    var canSubmitAuth: Bool {
        let name = loginName.trimmingCharacters(in: .whitespacesAndNewlines)
        let pwd = loginPassword
        return !loginBusy
            && agreedToTerms
            && !name.isEmpty && name.count <= 50
            && !pwd.isEmpty && pwd.count <= 128
    }

    var canContinuePhone: Bool {
        !loginBusy && agreedToTerms && isValidPhone(phoneNumber)
    }

    var canSubmitPhoneCode: Bool {
        !loginBusy
            && agreedToTerms
            && isValidPhone(phoneNumber)
            && verifyCode.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4
    }

    var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var pendingOutboundCount: Int { pendingOutboundIds.count }

    /// 输入框占位：有缓存时提示将在回复后自动发送。
    var composerPlaceholder: String {
        if pendingOutboundCount > 0 {
            return "已缓存 \(pendingOutboundCount) 条，回复后自动发送"
        }
        return "尽管问…"
    }

    /// 始终允许编辑输入框。
    var isComposerEditingDisabled: Bool {
        false
    }

    var displayUserName: String {
        let name = currentUser?.displayName ?? ""
        return name.isEmpty ? "记账用户" : name
    }

    var greetingLines: (String, String) {
        ("Hi \(displayUserName)，", "今天想记点什么账？")
    }

    var headerSubtitle: String? {
        switch stage {
        case .live:
            let name = currentUser?.displayName ?? ""
            return name.isEmpty ? "已登录" : "已登录 · \(name)"
        case .bootstrapping:
            return "校验登录中…"
        default:
            return nil
        }
    }

    init(defaultHttpUrl: String = AppConfig.defaultHttpURL) {
        self.httpBase = AuthService.resolveHttpBase(defaultHttpUrl)
        self.appearanceMode = SessionStore.getAppearanceMode()
    }

    func setAppearanceMode(_ mode: AppearanceMode) {
        guard appearanceMode != mode else { return }
        appearanceMode = mode
        SessionStore.persistAppearanceMode(mode)
    }

    func onAppear() {
        guard !didBootstrap else { return }
        didBootstrap = true
        Task { await bootstrap() }
    }

    func onDisappear() {
        // 进后台也会触发 onDisappear，此处只落盘，不取消 SSE（由 scenePhase 处理）。
        toastTask?.cancel()
        persistChatMessagesNow()
    }

    /// 进后台：只断本地 SSE，不调服务端 cancel；回前台：若未完成则 GET 续传。
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            disconnectTransportForResume()
            persistChatMessagesNow()
            persistStreamingBubbleNow()
        case .active:
            if stage == .live {
                resumeIncompleteStreamIfNeeded()
                if !waitingReply {
                    flushPendingOutbound()
                }
            }
        default:
            break
        }
    }

    /// 用户点「停止」：调服务端 cancel，并定稿本地气泡。
    func stopGeneration() {
        Task { await stopGenerationAndCancelRemote(toast: "已停止") }
    }

    func switchAuthMode(_ mode: AuthMode) {
        authMode = mode
        authError = ""
    }

    func goLoginRoute(_ route: LoginRoute) {
        authError = ""
        loginRoute = route
    }

    func backFromLoginSubpage() {
        authError = ""
        switch loginRoute {
        case .phoneCode:
            verifyCode = ""
            loginRoute = .phone
        case .phone, .accountPassword:
            loginRoute = .landing
        case .landing:
            break
        }
    }

    func wechatLoginTapped() {
        guard requireAgreement() else { return }
        showToast("微信登录即将开放")
    }

    func appleLoginTapped() {
        guard requireAgreement() else { return }
        showToast("Apple ID 登录即将开放")
    }

    func phoneLoginTapped() {
        guard requireAgreement() else { return }
        goLoginRoute(.phone)
    }

    func continuePhoneLogin() {
        guard canContinuePhone else {
            if !agreedToTerms {
                showToast("请先同意用户协议与隐私政策")
            } else if !isValidPhone(phoneNumber) {
                authError = "请输入正确的手机号"
            }
            return
        }
        authError = ""
        loginRoute = .phoneCode
    }

    func submitPhoneCodeLogin() {
        Task { await onPhoneCodeSubmit() }
    }

    func submitAuth() {
        Task { await onAuthSubmit() }
    }

    func logoutTapped() {
        showSideMenu = false
        Task { await onLogout() }
    }

    func sendChat() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""

        // 上一轮未结束（或已有排队）：先入队保序，结束后自动发送。
        if waitingReply || !pendingOutboundIds.isEmpty {
            enqueuePending(text)
            return
        }
        dispatchOutbound(text: text)
    }

    func sendSuggestion(_ text: String) {
        inputText = text
        sendChat()
    }

    func showToast(_ message: String) {
        toastMessage = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            if toastMessage == message {
                toastMessage = ""
            }
        }
    }

    func menuPlaceholderTapped(_ title: String) {
        showToast("「\(title)」即将上线")
    }

    /// 保持侧栏展开，让管理子页覆盖其上；这样右划返回时露出的直接是侧栏而非聊天界面。
    func openManagement(_ destination: ManagementDestination) {
        showSideMenu = true
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            managementDestination = destination
        }
    }

    /// 关闭管理子页并回到汉堡侧边栏（箭头返回 / 右划返回共用）。
    func closeManagement() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            managementDestination = nil
            showSideMenu = true
        }
    }

    func handleUnauthorized(_ message: String) {
        managementDestination = nil
        showSideMenu = false
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await forceToLogin(text.isEmpty ? "登录已失效 / 已在其他设备登录" : text)
        }
    }

    // MARK: - Auth / bootstrap

    private func bootstrap() async {
        stage = .bootstrapping
        authError = ""
        let stored = SessionStore.getStoredToken()
        guard !stored.isEmpty else {
            stage = .login
            currentUser = nil
            connected = false
            return
        }
        token = stored
        currentUser = SessionStore.getStoredUser()
        do {
            let me = try await AuthService.fetchMe(httpBase: httpBase, token: stored)
            currentUser = me
            SessionStore.persistSession(token: stored, user: me)
            enterLive()
        } catch let error as APIError where error.status == 401 {
            SessionStore.clearSession()
            token = ""
            currentUser = nil
            connected = false
            stage = .login
            authError = error.message
        } catch {
            stage = .login
            connected = false
            authError = (error as? APIError)?.message ?? "无法校验登录，请检查服务地址"
        }
    }

    private func onPhoneCodeSubmit() async {
        guard canSubmitPhoneCode else {
            if !agreedToTerms {
                showToast("请先同意用户协议与隐私政策")
            } else {
                authError = "请输入验证码"
            }
            return
        }
        let name = normalizedPhone()
        let password = verifyCode.trimmingCharacters(in: .whitespacesAndNewlines)
        loginBusy = true
        authError = ""
        defer { loginBusy = false }
        do {
            // 未注册手机号自动注册；已存在则回退登录（与设计文案一致）
            let data: AuthSessionResponse
            do {
                data = try await AuthService.register(httpBase: httpBase, name: name, password: password)
            } catch let error as APIError where error.status == 409 {
                data = try await AuthService.login(httpBase: httpBase, name: name, password: password)
            }
            applyAuthSuccess(data, name: name)
        } catch let error as APIError {
            authError = error.message
        } catch {
            authError = "登录失败"
        }
    }

    private func onAuthSubmit() async {
        let name = loginName.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = loginPassword
        if !agreedToTerms {
            showToast("请先同意用户协议与隐私政策")
            return
        }
        if name.isEmpty || name.count > 50 {
            authError = "用户名不能为空，最长 50"
            return
        }
        if password.isEmpty || password.count > 128 {
            authError = "密码不能为空，最长 128"
            return
        }
        loginBusy = true
        authError = ""
        defer { loginBusy = false }
        do {
            let data: AuthSessionResponse
            if authMode == .register {
                data = try await AuthService.register(httpBase: httpBase, name: name, password: password)
            } else {
                data = try await AuthService.login(httpBase: httpBase, name: name, password: password)
            }
            applyAuthSuccess(data, name: name)
        } catch let error as APIError {
            authError = error.message
        } catch {
            authError = authMode == .register ? "注册失败" : "登录失败"
        }
    }

    private func applyAuthSuccess(_ data: AuthSessionResponse, name: String) {
        SessionStore.persistSession(token: data.token, user: data.user)
        token = data.token
        currentUser = data.user ?? AuthUser(id: nil, name: name)
        loginPassword = ""
        verifyCode = ""
        showPassword = false
        loginRoute = .landing
        showSideMenu = false
        resetChatState()
        enterLive()
    }

    private func onLogout() async {
        let t = token
        stopChat(toast: nil)
        await AuthService.logout(httpBase: httpBase, token: t)
        SessionStore.clearSession()
        token = ""
        currentUser = nil
        managementDestination = nil
        ManagementCache.clear()
        resetChatState()
        authMode = .login
        loginRoute = .landing
        stage = .login
        authError = ""
    }

    private func enterLive() {
        connected = true
        stage = .live
        restoreChatMessagesIfNeeded()
        resumeIncompleteStreamIfNeeded()
    }

    // MARK: - SSE chat

    private func enqueuePending(_ text: String) {
        let id = nextId()
        pushMessage(ChatMessage(id: id, kind: .user, text: text, pending: true))
        pendingOutboundIds.append(id)
    }

    /// 真正发起一轮 SSE；`messageId` 非空表示从缓存队列取出。
    private func dispatchOutbound(text: String, messageId: Int? = nil) {
        guard !token.isEmpty else {
            Task { await forceToLogin("请先登录") }
            return
        }

        let outboundId: Int
        if let messageId, let idx = messages.firstIndex(where: { $0.id == messageId }) {
            messages[idx].pending = false
            outboundId = messageId
        } else {
            outboundId = nextId()
            pushMessage(ChatMessage(id: outboundId, kind: .user, text: text))
        }
        currentOutboundMessageId = outboundId

        beginWaitingReply(resetStreamCursor: true)
        chatGeneration += 1
        let generation = chatGeneration
        disconnectForResume = false

        chatTask = chatClient.start(
            httpBase: httpBase,
            token: token,
            content: text,
            onEvent: { [weak self] event in
                guard let self, self.chatGeneration == generation else { return }
                self.handleSSEEvent(event)
            },
            onComplete: { [weak self] result in
                guard let self, self.chatGeneration == generation else { return }
                self.handleSSEComplete(result)
            }
        )
    }

    /// 空闲时按入队顺序逐条发送（等上一轮 message_end / error / 中断后再发下一条）。
    private func flushPendingOutbound() {
        guard !waitingReply else { return }
        guard !disconnectForResume else { return }
        guard activeStreamId == nil else { return }
        guard let id = pendingOutboundIds.first else { return }

        guard let message = messages.first(where: { $0.id == id && $0.kind == .user }) else {
            pendingOutboundIds.removeFirst()
            flushPendingOutbound()
            return
        }

        pendingOutboundIds.removeFirst()
        dispatchOutbound(text: message.text, messageId: id)
    }

    private func handleSSEEvent(_ event: SseChatEvent) {
        switch event {
        case .started(let streamId, let eventId):
            applyStreamCursor(streamId: streamId, eventId: eventId)
            persistStreamingBubbleNow()
        case .delta(let chunk, let streamId, let eventId):
            if let eventId, lastEventId > 0, eventId <= lastEventId {
                applyStreamCursor(streamId: streamId, eventId: nil)
                return
            }
            applyStreamCursor(streamId: streamId, eventId: eventId)
            if streamingMsgId == nil {
                let id = nextId()
                streamingMsgId = id
                pushMessage(ChatMessage(id: id, kind: .assistant, text: chunk, streaming: true))
            } else if let sid = streamingMsgId, let idx = messages.firstIndex(where: { $0.id == sid }) {
                messages[idx].text += chunk
                messages[idx].streaming = true
            }
            persistStreamingBubbleNow()
            schedulePersistChatMessages()
        case .end(let content, let streamId, let eventId):
            applyStreamCursor(streamId: streamId, eventId: eventId)
            if let sid = streamingMsgId, let idx = messages.firstIndex(where: { $0.id == sid }) {
                if !content.isEmpty {
                    messages[idx].text = content
                }
                messages[idx].streaming = false
                streamingMsgId = nil
            } else if !content.isEmpty {
                pushMessage(ChatMessage(id: nextId(), kind: .assistant, text: content))
            }
            clearStreamCursor(status: StreamingBubbleState.statusCompleted)
            endWaitingReply()
            persistChatMessagesNow()
            flushPendingOutbound()
        case .error(let message, let streamId, let eventId):
            applyStreamCursor(streamId: streamId, eventId: eventId)
            let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            pushMessage(ChatMessage(id: nextId(), kind: .error, text: text.isEmpty ? "处理失败" : text))
            if let sid = streamingMsgId, let idx = messages.firstIndex(where: { $0.id == sid }) {
                messages[idx].streaming = false
                streamingMsgId = nil
            }
            clearStreamCursor(status: StreamingBubbleState.statusFailed)
            endWaitingReply()
            persistChatMessagesNow()
            flushPendingOutbound()
        }
    }

    private func handleSSEComplete(_ result: Result<Void, ChatSSEError>) {
        chatTask = nil

        switch result {
        case .success:
            // 正常结束应由 message_end / error 事件解锁；流异常提前结束则尝试续传或定稿。
            if waitingReply, !disconnectForResume {
                if activeStreamId != nil {
                    resumeIncompleteStreamIfNeeded()
                } else {
                    finishInterruptedReply(showToast: true, toast: "已中断，请重发")
                }
            }
        case .failure(let error):
            switch error {
            case .cancelled:
                if disconnectForResume {
                    // 进后台主动断连：保留游标与打字机状态，等回前台续传。
                    persistStreamingBubbleNow()
                    persistChatMessagesNow()
                    return
                }
                if waitingReply {
                    finishInterruptedReply(showToast: true, toast: "已中断，请重发")
                }
            case .conflict(let busy):
                if let id = currentOutboundMessageId {
                    requeuePending(id)
                }
                currentOutboundMessageId = nil
                endWaitingReply()
                handleBusyConflict(busy)
            case .notFound(let message):
                finalizeExpiredStream(toast: message.isEmpty ? "回复已结束或过期" : "回复已结束或过期")
            case .http(let status, let message):
                if status == 401 {
                    Task { await forceToLogin(message) }
                    return
                }
                pushMessage(ChatMessage(id: nextId(), kind: .error, text: message))
                finishInterruptedReply(showToast: false)
            case .emptyContent, .invalidURL, .transport:
                if disconnectForResume {
                    persistStreamingBubbleNow()
                    return
                }
                // 传输闪断且仍有 streamId：保留状态并短暂重试续传。
                if waitingReply, activeStreamId != nil {
                    disconnectForResume = true
                    persistStreamingBubbleNow()
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        await MainActor.run {
                            self?.resumeIncompleteStreamIfNeeded()
                        }
                    }
                    return
                }
                pushMessage(ChatMessage(id: nextId(), kind: .error, text: error.localizedDescription))
                finishInterruptedReply(showToast: false)
            }
        }
    }

    private func handleBusyConflict(_ busy: ChatBusyError) {
        guard let streamId = busy.streamId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !streamId.isEmpty else {
            showToast(busy.message)
            schedulePendingFlushRetry()
            return
        }

        let local = SessionStore.loadStreamingBubble(userId: chatStorageUserId)
        let after: Int64
        if let local, local.streamId == streamId {
            after = local.lastEventId
            ensureAssistantBubble(text: local.assistantText, messageId: local.messageId)
        } else {
            // 本地未处理过该流：从 0 补齐；勿用 body.lastEventId 以免跳过未展示文本。
            after = 0
            ensureAssistantBubble(text: "", messageId: nil)
        }

        activeStreamId = streamId
        lastEventId = after
        disconnectForResume = false
        beginWaitingReply(resetStreamCursor: false)
        persistStreamingBubbleNow()
        startResumeStream(streamId: streamId, afterEventId: after)
    }

    private func requeuePending(_ messageId: Int) {
        if let idx = messages.firstIndex(where: { $0.id == messageId }) {
            messages[idx].pending = true
        }
        pendingOutboundIds.removeAll { $0 == messageId }
        pendingOutboundIds.insert(messageId, at: 0)
    }

    private func schedulePendingFlushRetry() {
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            flushPendingOutbound()
        }
    }

    private func stopChat(toast: String?) {
        disconnectForResume = false
        chatGeneration += 1
        chatClient.disconnect()
        chatTask = nil
        finishInterruptedReply(
            showToast: toast != nil,
            toast: toast ?? "已中断，请重发",
            flushQueue: true
        )
    }

    private func stopGenerationAndCancelRemote(toast: String?) async {
        guard waitingReply || activeStreamId != nil || chatTask != nil else { return }
        let streamId = activeStreamId
        disconnectForResume = false
        chatGeneration += 1
        chatClient.disconnect()
        chatTask = nil

        if let streamId, !streamId.isEmpty, !token.isEmpty {
            do {
                try await chatClient.cancelRemote(httpBase: httpBase, token: token, streamId: streamId)
            } catch let error as ChatSSEError where error.status == 401 {
                await forceToLogin(error.localizedDescription)
                return
            } catch {
                // 本地仍定稿；服务端可能已结束。
            }
        }

        if let sid = streamingMsgId, let idx = messages.firstIndex(where: { $0.id == sid }) {
            let text = messages[idx].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                messages.remove(at: idx)
            } else {
                messages[idx].streaming = false
            }
        }
        streamingMsgId = nil
        currentOutboundMessageId = nil
        clearStreamCursor(status: StreamingBubbleState.statusFailed)
        endWaitingReply()
        if let toast {
            showToast(toast)
        }
        persistChatMessagesNow()
        flushPendingOutbound()
    }

    /// 进后台：只断传输，保留 streamId / lastEventId / 打字机文本。
    private func disconnectTransportForResume() {
        guard chatTask != nil || (waitingReply && activeStreamId != nil) else { return }
        guard activeStreamId != nil || streamingMsgId != nil || waitingReply else { return }

        if activeStreamId == nil && streamingMsgId == nil {
            // 尚未拿到 started：只能断连；回前台若仍 waiting 且无 streamId 则按中断处理。
            disconnectForResume = waitingReply
            chatGeneration += 1
            chatClient.disconnect()
            chatTask = nil
            return
        }

        disconnectForResume = true
        chatGeneration += 1
        chatClient.disconnect()
        chatTask = nil
        if let sid = streamingMsgId, let idx = messages.firstIndex(where: { $0.id == sid }) {
            messages[idx].streaming = true
        }
        persistStreamingBubbleNow()
    }

    private func resumeIncompleteStreamIfNeeded() {
        guard stage == .live else { return }
        guard !token.isEmpty else { return }
        guard chatTask == nil else { return }

        let state = currentStreamingState() ?? SessionStore.loadStreamingBubble(userId: chatStorageUserId)
        guard let state,
              state.status == StreamingBubbleState.statusStreaming,
              !state.streamId.isEmpty else {
            if disconnectForResume, waitingReply, activeStreamId == nil {
                // 后台时还没 started，无法续传。
                disconnectForResume = false
                finishInterruptedReply(showToast: true, toast: "连接已中断，请重发")
            }
            return
        }

        ensureAssistantBubble(text: state.assistantText, messageId: state.messageId)
        activeStreamId = state.streamId
        lastEventId = state.lastEventId
        disconnectForResume = false
        beginWaitingReply(resetStreamCursor: false)
        startResumeStream(streamId: state.streamId, afterEventId: state.lastEventId)
    }

    private func startResumeStream(streamId: String, afterEventId: Int64) {
        chatGeneration += 1
        let generation = chatGeneration
        disconnectForResume = false

        chatTask = chatClient.startResume(
            httpBase: httpBase,
            token: token,
            streamId: streamId,
            afterEventId: afterEventId,
            onEvent: { [weak self] event in
                guard let self, self.chatGeneration == generation else { return }
                self.handleSSEEvent(event)
            },
            onComplete: { [weak self] result in
                guard let self, self.chatGeneration == generation else { return }
                self.handleSSEComplete(result)
            }
        )
    }

    private func beginWaitingReply(resetStreamCursor: Bool) {
        waitingReply = true
        if resetStreamCursor {
            streamingMsgId = nil
            activeStreamId = nil
            lastEventId = 0
            SessionStore.clearStreamingBubble(userId: chatStorageUserId)
        }
        replyTimeoutTask?.cancel()
        replyTimeoutTask = Task { [replyTimeoutNanoseconds] in
            try? await Task.sleep(nanoseconds: replyTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            guard waitingReply else { return }
            await stopGenerationAndCancelRemote(toast: "回复超时，请重试")
        }
    }

    private func endWaitingReply() {
        waitingReply = false
        disconnectForResume = false
        replyTimeoutTask?.cancel()
        replyTimeoutTask = nil
    }

    /// 中断进行中的回复：结束 streaming；默认保留半成品文本。
    private func finishInterruptedReply(
        showToast: Bool,
        toast: String = "已中断，请重发",
        flushQueue: Bool = true
    ) {
        if let sid = streamingMsgId, let idx = messages.firstIndex(where: { $0.id == sid }) {
            let text = messages[idx].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                messages.remove(at: idx)
            } else {
                messages[idx].streaming = false
            }
        }
        streamingMsgId = nil
        currentOutboundMessageId = nil
        clearStreamCursor(status: StreamingBubbleState.statusFailed)
        endWaitingReply()
        if showToast {
            self.showToast(toast)
        }
        persistChatMessagesNow()
        if flushQueue {
            flushPendingOutbound()
        }
    }

    private func finalizeExpiredStream(toast: String) {
        if let sid = streamingMsgId, let idx = messages.firstIndex(where: { $0.id == sid }) {
            let text = messages[idx].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                messages.remove(at: idx)
            } else {
                messages[idx].streaming = false
            }
        }
        streamingMsgId = nil
        currentOutboundMessageId = nil
        clearStreamCursor(status: StreamingBubbleState.statusCompleted)
        endWaitingReply()
        showToast(toast)
        persistChatMessagesNow()
        flushPendingOutbound()
    }

    private func applyStreamCursor(streamId: String?, eventId: Int64?) {
        if let streamId {
            let trimmed = streamId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                activeStreamId = trimmed
            }
        }
        if let eventId, eventId > lastEventId {
            lastEventId = eventId
        }
    }

    private func clearStreamCursor(status: String) {
        if let streamId = activeStreamId {
            let text: String = {
                if let sid = streamingMsgId,
                   let idx = messages.firstIndex(where: { $0.id == sid }) {
                    return messages[idx].text
                }
                return currentStreamingState()?.assistantText ?? ""
            }()
            // 终态写一次快照后清除「未完成」标记。
            let final = StreamingBubbleState(
                streamId: streamId,
                lastEventId: lastEventId,
                assistantText: text,
                status: status,
                messageId: streamingMsgId
            )
            if status == StreamingBubbleState.statusStreaming {
                SessionStore.persistStreamingBubble(final, userId: chatStorageUserId)
            } else {
                SessionStore.clearStreamingBubble(userId: chatStorageUserId)
            }
        } else {
            SessionStore.clearStreamingBubble(userId: chatStorageUserId)
        }
        activeStreamId = nil
        lastEventId = 0
        disconnectForResume = false
    }

    private func currentStreamingState() -> StreamingBubbleState? {
        guard let streamId = activeStreamId, !streamId.isEmpty else { return nil }
        let text: String
        if let sid = streamingMsgId, let idx = messages.firstIndex(where: { $0.id == sid }) {
            text = messages[idx].text
        } else {
            text = ""
        }
        return StreamingBubbleState(
            streamId: streamId,
            lastEventId: lastEventId,
            assistantText: text,
            status: StreamingBubbleState.statusStreaming,
            messageId: streamingMsgId
        )
    }

    private func persistStreamingBubbleNow() {
        SessionStore.persistStreamingBubble(currentStreamingState(), userId: chatStorageUserId)
    }

    private func ensureAssistantBubble(text: String, messageId: Int?) {
        if let messageId, let idx = messages.firstIndex(where: { $0.id == messageId }) {
            messages[idx].kind = .assistant
            if messages[idx].text.isEmpty, !text.isEmpty {
                messages[idx].text = text
            } else if !text.isEmpty, messages[idx].text.count < text.count {
                messages[idx].text = text
            }
            messages[idx].streaming = true
            streamingMsgId = messageId
            return
        }
        if let sid = streamingMsgId, let idx = messages.firstIndex(where: { $0.id == sid }) {
            if messages[idx].text.isEmpty, !text.isEmpty {
                messages[idx].text = text
            }
            messages[idx].streaming = true
            return
        }
        // 找最后一条助手气泡复用（冷启动恢复）。
        if let idx = messages.lastIndex(where: { $0.kind == .assistant }),
           messages[idx].text == text || text.isEmpty || messages[idx].text.hasPrefix(text) || text.hasPrefix(messages[idx].text) {
            if messages[idx].text.count < text.count {
                messages[idx].text = text
            }
            messages[idx].streaming = true
            streamingMsgId = messages[idx].id
            return
        }
        let id = nextId()
        streamingMsgId = id
        pushMessage(ChatMessage(id: id, kind: .assistant, text: text, streaming: true))
    }

    private func forceToLogin(_ message: String) async {
        guard !sessionInvalidHandled else { return }
        sessionInvalidHandled = true
        stopChat(toast: nil)
        SessionStore.clearSession()
        token = ""
        currentUser = nil
        managementDestination = nil
        ManagementCache.clear()
        resetChatState()
        stage = .login
        loginRoute = .landing
        authError = message
        sessionInvalidHandled = false
    }

    private func resetChatState() {
        persistChatTask?.cancel()
        // 须在清空 currentUser 之前调用，或先由调用方 clearStreamingBubble。
        SessionStore.clearStreamingBubble(userId: chatStorageUserId)
        messages = []
        authError = ""
        connected = false
        endWaitingReply()
        inputText = ""
        streamingMsgId = nil
        pendingOutboundIds = []
        currentOutboundMessageId = nil
        activeStreamId = nil
        lastEventId = 0
        disconnectForResume = false
        chatGeneration += 1
    }

    private func restoreChatMessagesIfNeeded() {
        guard messages.isEmpty else { return }
        let loaded = SessionStore.loadChatMessages(userId: chatStorageUserId)
        guard !loaded.isEmpty else {
            restoreStreamingBubbleIntoMessages()
            return
        }
        messages = loaded
        pendingOutboundIds = loaded
            .filter { $0.kind == .user && $0.pending }
            .map(\.id)
        restoreStreamingBubbleIntoMessages()
    }

    private func restoreStreamingBubbleIntoMessages() {
        guard let state = SessionStore.loadStreamingBubble(userId: chatStorageUserId),
              state.status == StreamingBubbleState.statusStreaming,
              !state.streamId.isEmpty else { return }
        ensureAssistantBubble(text: state.assistantText, messageId: state.messageId)
        activeStreamId = state.streamId
        lastEventId = state.lastEventId
        waitingReply = true
        disconnectForResume = true
    }

    private func schedulePersistChatMessages() {
        persistChatTask?.cancel()
        persistChatTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            persistChatMessagesNow()
            persistStreamingBubbleNow()
        }
    }

    private func persistChatMessagesNow() {
        persistChatTask?.cancel()
        persistChatTask = nil
        SessionStore.persistChatMessages(messages, userId: chatStorageUserId)
    }

    private func pushMessage(_ message: ChatMessage) {
        messages.append(message)
        schedulePersistChatMessages()
    }

    private func nextId() -> Int {
        (messages.map(\.id).max() ?? -1) + 1
    }

    private func requireAgreement() -> Bool {
        guard agreedToTerms else {
            showToast("请先同意用户协议与隐私政策")
            return false
        }
        return true
    }

    private func isValidPhone(_ raw: String) -> Bool {
        let digits = raw.filter(\.isNumber)
        return digits.count == 11 && digits.hasPrefix("1")
    }

    private func normalizedPhone() -> String {
        phoneNumber.filter(\.isNumber)
    }
}
