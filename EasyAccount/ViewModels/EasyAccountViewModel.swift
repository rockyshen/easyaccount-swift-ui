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

    /// 与服务端约 300s 超时对齐。
    private let replyTimeoutNanoseconds: UInt64 = 300_000_000_000

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
        Task { await bootstrap() }
    }

    func onDisappear() {
        toastTask?.cancel()
        stopChat(toast: nil)
    }

    /// App 进后台可能断流；回前台若仍在等待则提示重发。
    func handleScenePhase(_ phase: ScenePhase) {
        guard phase == .background else { return }
        guard waitingReply else { return }
        stopChat(toast: "已中断，请重发")
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

        beginWaitingReply()
        chatGeneration += 1
        let generation = chatGeneration

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
        case .started:
            break
        case .delta(let chunk):
            if streamingMsgId == nil {
                let id = nextId()
                streamingMsgId = id
                pushMessage(ChatMessage(id: id, kind: .assistant, text: chunk, streaming: true))
            } else if let sid = streamingMsgId, let idx = messages.firstIndex(where: { $0.id == sid }) {
                messages[idx].text += chunk
            }
        case .end(let content):
            if let sid = streamingMsgId, let idx = messages.firstIndex(where: { $0.id == sid }) {
                if !content.isEmpty {
                    messages[idx].text = content
                }
                messages[idx].streaming = false
                streamingMsgId = nil
            } else if !content.isEmpty {
                pushMessage(ChatMessage(id: nextId(), kind: .assistant, text: content))
            }
            endWaitingReply()
            flushPendingOutbound()
        case .error(let message):
            let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            pushMessage(ChatMessage(id: nextId(), kind: .error, text: text.isEmpty ? "处理失败" : text))
            if let sid = streamingMsgId, let idx = messages.firstIndex(where: { $0.id == sid }) {
                messages[idx].streaming = false
                streamingMsgId = nil
            }
            endWaitingReply()
            flushPendingOutbound()
        }
    }

    private func handleSSEComplete(_ result: Result<Void, ChatSSEError>) {
        chatTask = nil

        switch result {
        case .success:
            // 正常结束应由 message_end / error 事件解锁；流异常提前结束则提示重发。
            if waitingReply {
                finishInterruptedReply(showToast: true, toast: "已中断，请重发")
            }
        case .failure(let error):
            switch error {
            case .cancelled:
                if waitingReply {
                    finishInterruptedReply(showToast: true, toast: "已中断，请重发")
                }
            case .http(let status, let message):
                if status == 401 {
                    Task { await forceToLogin(message) }
                    return
                }
                if status == 409 {
                    // 服务端仍忙：把本轮用户消息重新插回队列头部，稍后自动重试。
                    if let id = currentOutboundMessageId {
                        requeuePending(id)
                    }
                    finishInterruptedReply(showToast: true, toast: message)
                    schedulePendingFlushRetry()
                    return
                }
                pushMessage(ChatMessage(id: nextId(), kind: .error, text: message))
                finishInterruptedReply(showToast: false)
            case .emptyContent, .invalidURL, .transport:
                pushMessage(ChatMessage(id: nextId(), kind: .error, text: error.localizedDescription))
                finishInterruptedReply(showToast: false)
            }
        }
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
        guard chatTask != nil || waitingReply || streamingMsgId != nil else { return }
        chatGeneration += 1
        chatClient.cancel()
        chatTask = nil
        if waitingReply || streamingMsgId != nil {
            finishInterruptedReply(showToast: toast != nil, toast: toast ?? "已中断，请重发")
        }
    }

    private func beginWaitingReply() {
        waitingReply = true
        streamingMsgId = nil
        replyTimeoutTask?.cancel()
        replyTimeoutTask = Task { [replyTimeoutNanoseconds] in
            try? await Task.sleep(nanoseconds: replyTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            guard waitingReply else { return }
            stopChat(toast: "回复超时，请重试")
        }
    }

    private func endWaitingReply() {
        waitingReply = false
        replyTimeoutTask?.cancel()
        replyTimeoutTask = nil
    }

    /// 中断进行中的回复：结束 streaming；保留发送队列，空闲后继续 flush。
    private func finishInterruptedReply(
        showToast: Bool,
        toast: String = "已中断，请重发"
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
        endWaitingReply()
        if showToast {
            self.showToast(toast)
        }
        flushPendingOutbound()
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
        messages = []
        authError = ""
        connected = false
        endWaitingReply()
        inputText = ""
        streamingMsgId = nil
        pendingOutboundIds = []
        currentOutboundMessageId = nil
        chatGeneration += 1
    }

    private func pushMessage(_ message: ChatMessage) {
        messages.append(message)
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
