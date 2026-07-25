import Foundation
import Combine
import SwiftUI

enum AppStage: Equatable {
    case bootstrapping
    case login
    case connecting
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

    @Published var wsUrl: String
    @Published var httpBase: String

    @Published var currentUser: AuthUser?
    @Published var connected: Bool = false
    /// 正在发起 WS 握手（含重连）；仅此阶段状态灯为黄色。
    @Published private(set) var isSocketConnecting: Bool = false
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var waitingReply: Bool = false

    private var token: String = ""
    private let socket = ChatWebSocket()
    private var streamingMsgId: Int?
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?
    private var sessionInvalidHandled = false
    private var handlingClose = false
    private var toastTask: Task<Void, Never>?
    private var replyTimeoutTask: Task<Void, Never>?

    /// 等待助手回复的最长时长，超时后解锁输入，避免永久卡住。
    private let replyTimeoutNanoseconds: UInt64 = 60_000_000_000

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
        connected && !waitingReply && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 输入框占位：回复中 / 断连 / 常态。
    var composerPlaceholder: String {
        if waitingReply { return "助手正在回复…" }
        if !connected { return "连接断开，可先输入，恢复后发送" }
        return "随便问，记账、图片也可以"
    }

    /// 仅在等待回复时锁输入；断连时仍可编辑草稿。
    var isComposerEditingDisabled: Bool {
        waitingReply
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
            if connected {
                let name = currentUser?.displayName ?? ""
                return name.isEmpty ? "已连接" : "已连接 · \(name)"
            }
            return "连接中…"
        case .bootstrapping:
            return "校验登录中…"
        default:
            return nil
        }
    }

    init(
        defaultWsUrl: String = AppConfig.defaultWsURL,
        defaultHttpUrl: String = AppConfig.defaultHttpURL
    ) {
        self.wsUrl = defaultWsUrl
        self.httpBase = AuthService.resolveHttpBase(httpUrl: defaultHttpUrl, wsUrl: defaultWsUrl)
        self.appearanceMode = SessionStore.getAppearanceMode()
        socket.delegate = self
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
        reconnectTask?.cancel()
        toastTask?.cancel()
        socket.disconnect(intentional: true)
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
        guard !text.isEmpty, !waitingReply else { return }
        guard connected else {
            // 保留输入内容，提示用户待恢复后再发，避免假发送后卡住。
            showToast("当前未连接，请稍后再发")
            return
        }
        guard socket.sendChat(text) else {
            showToast("发送失败，请稍后再试")
            return
        }
        pushMessage(ChatMessage(id: nextId(), kind: .user, text: text))
        inputText = ""
        beginWaitingReply()
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

    func openManagement(_ destination: ManagementDestination) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            showSideMenu = false
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            managementDestination = destination
        }
    }

    func closeManagement() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            managementDestination = nil
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
            return
        }
        token = stored
        currentUser = SessionStore.getStoredUser()
        do {
            let me = try await AuthService.fetchMe(httpBase: httpBase, token: stored)
            currentUser = me
            SessionStore.persistSession(token: stored, user: me)
            connectWs()
        } catch let error as APIError where error.status == 401 {
            SessionStore.clearSession()
            token = ""
            currentUser = nil
            stage = .login
            authError = error.message
        } catch {
            stage = .login
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
        connectWs()
    }

    private func onLogout() async {
        let t = token
        reconnectTask?.cancel()
        socket.disconnect(intentional: true)
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

    // MARK: - WebSocket

    private func connectWs() {
        guard !token.isEmpty else {
            isSocketConnecting = false
            Task { await forceToLogin("请先登录") }
            return
        }
        reconnectTask?.cancel()
        if stage != .live { stage = .connecting }
        connected = false
        isSocketConnecting = true

        guard let url = AuthService.buildChatWsUrl(wsUrl: wsUrl, token: token) else {
            isSocketConnecting = false
            stage = .login
            authError = "无法创建连接，请检查地址"
            return
        }
        socket.connect(url: url)
    }

    private func handleServerMessage(_ msg: ServerEvent) {
        switch msg.type {
        case .connected:
            connected = true
            isSocketConnecting = false
            stage = .live
            reconnectAttempts = 0
            // 重连成功不往对话里插系统提示，保持无感知
        case .messageDelta:
            let chunk = msg.content ?? ""
            // 服务端偶发把重连文案当消息流下发，直接忽略
            if streamingMsgId == nil, isConnectionStatusNoise(chunk) {
                return
            }
            if streamingMsgId == nil {
                let id = nextId()
                streamingMsgId = id
                pushMessage(ChatMessage(id: id, kind: .assistant, text: chunk, streaming: true))
            } else if let sid = streamingMsgId, let idx = messages.firstIndex(where: { $0.id == sid }) {
                messages[idx].text += chunk
            }
        case .messageEnd:
            if let sid = streamingMsgId, let idx = messages.firstIndex(where: { $0.id == sid }) {
                let finalText = {
                    if let content = msg.content, !content.isEmpty { return content }
                    return messages[idx].text
                }()
                if isConnectionStatusNoise(finalText) {
                    messages.remove(at: idx)
                } else {
                    if let content = msg.content, !content.isEmpty {
                        messages[idx].text = content
                    }
                    messages[idx].streaming = false
                }
                streamingMsgId = nil
            } else if let content = msg.content, !content.isEmpty, !isConnectionStatusNoise(content) {
                pushMessage(ChatMessage(id: nextId(), kind: .assistant, text: content))
            }
            endWaitingReply()
        case .error:
            let text = msg.message ?? "发生错误"
            if !isConnectionStatusNoise(text) {
                pushMessage(ChatMessage(id: nextId(), kind: .error, text: text))
            }
            if let sid = streamingMsgId, let idx = messages.firstIndex(where: { $0.id == sid }) {
                messages[idx].streaming = false
                streamingMsgId = nil
            }
            endWaitingReply()
        }
    }

    /// 过滤断线/重连状态文案，避免插入聊天记录。
    private func isConnectionStatusNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let needles = [
            "连接已断开",
            "已断开连接",
            "正在重连",
            "重新连接",
            "记账助手已连接",
            "已重新连接",
            "连接中断",
            "断线重连"
        ]
        return needles.contains { trimmed.contains($0) }
    }

    private func handleSocketClosed() {
        connected = false
        isSocketConnecting = false
        // 断连时若仍在等待回复，必须解锁输入，否则重连后会永久卡在「助手正在回复」。
        let interruptedReply = waitingReply || streamingMsgId != nil
        finishInterruptedReply(showToast: interruptedReply && !socket.wasIntentionalClose)

        if socket.wasIntentionalClose { return }
        guard !handlingClose else { return }
        handlingClose = true

        Task {
            defer { handlingClose = false }
            if stage == .connecting {
                let stillValid = await checkSessionStillValid()
                if !stillValid {
                    await forceToLogin("未登录或会话已失效")
                    return
                }
                reconnectAttempts += 1
                if reconnectAttempts >= 3 {
                    stage = .login
                    authError = "连接失败，请确认 easyaccount-agent 已启动"
                    reconnectAttempts = 0
                    return
                }
                let delay = UInt64(800 * reconnectAttempts) * 1_000_000
                reconnectTask = Task {
                    try? await Task.sleep(nanoseconds: delay)
                    guard !Task.isCancelled else { return }
                    connectWs()
                }
                return
            }

            if stage == .live {
                // 断线后后台静默重连，不在对话中展示断开/重连提示
                let stillValid = await checkSessionStillValid()
                if !stillValid {
                    await forceToLogin("会话已失效（可能被其他设备登录踢下线）")
                    return
                }
                reconnectAttempts += 1
                let delayMs = min(8000, 600 * reconnectAttempts)
                reconnectTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                    guard !Task.isCancelled else { return }
                    connectWs()
                }
            }
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
            finishInterruptedReply(showToast: true, toast: "回复超时，请重试")
        }
    }

    private func endWaitingReply() {
        waitingReply = false
        replyTimeoutTask?.cancel()
        replyTimeoutTask = nil
    }

    /// 中断进行中的回复：结束 streaming、解锁输入，必要时 toast 提示重试。
    private func finishInterruptedReply(
        showToast: Bool,
        toast: String = "连接中断，请重新发送"
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
        endWaitingReply()
        if showToast {
            self.showToast(toast)
        }
    }

    private func checkSessionStillValid() async -> Bool {
        guard !token.isEmpty else { return false }
        do {
            let me = try await AuthService.fetchMe(httpBase: httpBase, token: token)
            currentUser = me
            SessionStore.persistSession(token: token, user: me)
            return true
        } catch let error as APIError where error.status == 401 {
            return false
        } catch {
            return true
        }
    }

    private func forceToLogin(_ message: String) async {
        guard !sessionInvalidHandled else { return }
        sessionInvalidHandled = true
        reconnectTask?.cancel()
        socket.disconnect(intentional: true)
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
        isSocketConnecting = false
        endWaitingReply()
        inputText = ""
        streamingMsgId = nil
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

extension EasyAccountViewModel: ChatWebSocketDelegate {
    func chatWebSocketDidOpen(_ socket: ChatWebSocket) {
        // live stage is driven by server `connected` event, matching web client
    }

    func chatWebSocket(_ socket: ChatWebSocket, didReceive event: ServerEvent) {
        handleServerMessage(event)
    }

    func chatWebSocket(_ socket: ChatWebSocket, didCloseWith code: URLSessionWebSocketTask.CloseCode) {
        handleSocketClosed()
    }

    func chatWebSocket(_ socket: ChatWebSocket, didFailWith error: Error) {
        // browsers hide handshake detail; close path + /me classify auth vs network
        handleSocketClosed()
    }
}
