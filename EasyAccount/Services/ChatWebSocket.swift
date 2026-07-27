import Foundation

@MainActor
protocol ChatWebSocketDelegate: AnyObject {
    func chatWebSocketDidOpen(_ socket: ChatWebSocket)
    func chatWebSocket(_ socket: ChatWebSocket, didReceive event: ServerEvent)
    func chatWebSocket(_ socket: ChatWebSocket, didCloseWith code: URLSessionWebSocketTask.CloseCode)
    func chatWebSocket(_ socket: ChatWebSocket, didFailWith error: Error)
}

@MainActor
final class ChatWebSocket: NSObject {
    weak var delegate: ChatWebSocketDelegate?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var isOpen = false
    private var intentionalClose = false
    /// 关闭与失败可能各自回调一次，只向 delegate 上报第一次。
    private var didReportTermination = false

    var wasIntentionalClose: Bool { intentionalClose }

    func connect(url: URL) {
        disconnect(intentional: true)
        intentionalClose = false
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        isOpen = false
        didReportTermination = false
        task.resume()
        receiveLoop()
    }

    /// 返回是否已成功提交到 socket；失败时不进入「等待回复」态。
    @discardableResult
    func sendChat(_ text: String) -> Bool {
        guard isOpen,
              let task,
              let data = try? JSONEncoder().encode(ChatOutbound(type: "chat", content: text)),
              let raw = String(data: data, encoding: .utf8) else { return false }
        task.send(.string(raw)) { [weak self] error in
            guard let self, let error else { return }
            Task { @MainActor in
                self.delegate?.chatWebSocket(self, didFailWith: error)
            }
        }
        return true
    }

    func disconnect(intentional: Bool = true) {
        intentionalClose = intentional
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        isOpen = false
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .failure:
                    // close/fail callbacks handle state; avoid double noise
                    break
                case .success(let message):
                    if !self.isOpen {
                        self.isOpen = true
                        self.delegate?.chatWebSocketDidOpen(self)
                    }
                    if let event = Self.parse(message) {
                        self.delegate?.chatWebSocket(self, didReceive: event)
                    }
                    self.receiveLoop()
                }
            }
        }
    }

    private static func parse(_ message: URLSessionWebSocketTask.Message) -> ServerEvent? {
        let data: Data?
        switch message {
        case .string(let text):
            data = text.data(using: .utf8)
        case .data(let d):
            data = d
        @unknown default:
            data = nil
        }
        guard let data else { return nil }
        return try? JSONDecoder().decode(ServerEvent.self, from: data)
    }
}

extension ChatWebSocket: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor in
            if !isOpen {
                isOpen = true
                delegate?.chatWebSocketDidOpen(self)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor in
            guard webSocketTask === task, !didReportTermination else { return }
            didReportTermination = true
            isOpen = false
            delegate?.chatWebSocket(self, didCloseWith: closeCode)
        }
    }

    /// 握手未完成就失败（如 token 失效返回 401）不会触发 didCloseWith，只能在这里捕获；
    /// 缺少此回调时连接失败将无人知晓，UI 会永久停在「连接中」且不再重试。
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        Task { @MainActor in
            guard task === self.task, !didReportTermination else { return }
            didReportTermination = true
            isOpen = false
            if let error {
                delegate?.chatWebSocket(self, didFailWith: error)
            } else {
                delegate?.chatWebSocket(self, didCloseWith: .normalClosure)
            }
        }
    }
}
