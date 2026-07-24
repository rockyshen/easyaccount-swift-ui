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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accounts: return "账户管理"
        case .categories: return "分类管理"
        case .dashboard: return "概览分析"
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
    @Published var menuSearch: String = ""
    @Published var managementDestination: ManagementDestination?
    @Published var appearanceMode: AppearanceMode

    @Published var wsUrl: String
    @Published var httpBase: String

    @Published var currentUser: AuthUser?
    @Published var connected: Bool = false
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
        guard !text.isEmpty, connected, !waitingReply else { return }
        socket.sendChat(text)
        pushMessage(ChatMessage(id: nextId(), kind: .user, text: text))
        inputText = ""
        waitingReply = true
        streamingMsgId = nil
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
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            showSideMenu = false
        }
        managementDestination = destination
    }

    func closeManagement() {
        managementDestination = nil
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
        resetChatState()
        authMode = .login
        loginRoute = .landing
        stage = .login
        authError = ""
    }

    // MARK: - WebSocket

    private func connectWs() {
        guard !token.isEmpty else {
            Task { await forceToLogin("请先登录") }
            return
        }
        reconnectTask?.cancel()
        if stage != .live { stage = .connecting }
        connected = false

        guard let url = AuthService.buildChatWsUrl(wsUrl: wsUrl, token: token) else {
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
            stage = .live
            reconnectAttempts = 0
            // 空会话时用欢迎语，不再推系统灰条打扰首屏
            if !messages.isEmpty {
                pushMessage(ChatMessage(id: nextId(), kind: .system, text: msg.content ?? "记账助手已连接"))
            }
        case .messageDelta:
            if streamingMsgId == nil {
                let id = nextId()
                streamingMsgId = id
                pushMessage(ChatMessage(id: id, kind: .assistant, text: msg.content ?? "", streaming: true))
            } else if let sid = streamingMsgId, let idx = messages.firstIndex(where: { $0.id == sid }) {
                messages[idx].text += msg.content ?? ""
            }
        case .messageEnd:
            if let sid = streamingMsgId, let idx = messages.firstIndex(where: { $0.id == sid }) {
                if let content = msg.content, !content.isEmpty {
                    messages[idx].text = content
                }
                messages[idx].streaming = false
                streamingMsgId = nil
            } else if let content = msg.content, !content.isEmpty {
                pushMessage(ChatMessage(id: nextId(), kind: .assistant, text: content))
            }
            waitingReply = false
        case .error:
            pushMessage(ChatMessage(id: nextId(), kind: .error, text: msg.message ?? "发生错误"))
            if let sid = streamingMsgId, let idx = messages.firstIndex(where: { $0.id == sid }) {
                messages[idx].streaming = false
                streamingMsgId = nil
            }
            waitingReply = false
        }
    }

    private func handleSocketClosed() {
        connected = false
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
                pushMessage(ChatMessage(id: nextId(), kind: .system, text: "连接已断开，正在重连…"))
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
        waitingReply = false
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
