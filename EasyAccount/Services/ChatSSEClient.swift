import Foundation

enum SseChatEvent: Equatable {
    case started
    case delta(String)
    case end(String)
    case error(String)
}

enum ChatSSEError: Error, LocalizedError, Equatable {
    case invalidURL
    case emptyContent
    case http(status: Int, message: String)
    case cancelled
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的服务地址"
        case .emptyContent:
            return "消息不能为空"
        case .http(_, let message):
            return message
        case .cancelled:
            return "已取消"
        case .transport(let message):
            return message
        }
    }

    var status: Int? {
        if case .http(let status, _) = self { return status }
        return nil
    }
}

/// POST `/api/chat` SSE 流式客户端（Authorization Header，非 query token）。
@MainActor
final class ChatSSEClient {
    private var streamTask: Task<Void, Never>?
    private var session: URLSession?

    var isStreaming: Bool { streamTask != nil }

    /// 发起一轮对话；`onEvent` 在主线程回调。同一实例同时只允许一轮。
    func stream(
        httpBase: String,
        token: String,
        content: String,
        onEvent: @escaping (SseChatEvent) -> Void
    ) async throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChatSSEError.emptyContent }

        let base = APIClient.stripTrailingSlash(httpBase)
        guard let url = URL(string: "\(base)/api/chat") else {
            throw ChatSSEError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(ChatOutbound(content: trimmed))

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config)
        self.session = session

        do {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1

            if status != 200 {
                var collected = Data()
                for try await byte in bytes {
                    collected.append(byte)
                    if collected.count > 16_384 { break }
                }
                let body = try? JSONDecoder().decode(AuthErrorBody.self, from: collected)
                let fallback: String
                switch status {
                case 400: fallback = "消息不能为空"
                case 401: fallback = "未登录或会话已失效"
                case 409: fallback = "上一条消息仍在处理中"
                default: fallback = "请求失败（\(status)）"
                }
                throw ChatSSEError.http(status: status, message: body?.message ?? fallback)
            }

            try await Self.consumeSSE(bytes: bytes, onEvent: onEvent)
            self.streamTask = nil
            self.session?.finishTasksAndInvalidate()
            self.session = nil
        } catch is CancellationError {
            session.invalidateAndCancel()
            self.session = nil
            self.streamTask = nil
            throw ChatSSEError.cancelled
        } catch let error as ChatSSEError {
            session.invalidateAndCancel()
            self.session = nil
            self.streamTask = nil
            throw error
        } catch {
            session.invalidateAndCancel()
            self.session = nil
            self.streamTask = nil
            if (error as NSError).code == NSURLErrorCancelled {
                throw ChatSSEError.cancelled
            }
            throw ChatSSEError.transport(error.localizedDescription)
        }
    }

    /// 用独立 Task 包装，便于 ViewModel 持有并 `cancel()`。
    @discardableResult
    func start(
        httpBase: String,
        token: String,
        content: String,
        onEvent: @escaping (SseChatEvent) -> Void,
        onComplete: @escaping (Result<Void, ChatSSEError>) -> Void
    ) -> Task<Void, Never> {
        cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.stream(
                    httpBase: httpBase,
                    token: token,
                    content: content,
                    onEvent: onEvent
                )
                guard !Task.isCancelled else {
                    onComplete(.failure(.cancelled))
                    return
                }
                onComplete(.success(()))
            } catch let error as ChatSSEError {
                onComplete(.failure(error))
            } catch {
                if Task.isCancelled || (error as NSError).code == NSURLErrorCancelled {
                    onComplete(.failure(.cancelled))
                } else {
                    onComplete(.failure(.transport(error.localizedDescription)))
                }
            }
        }
        streamTask = task
        return task
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - SSE parsing

    private static func consumeSSE(
        bytes: URLSession.AsyncBytes,
        onEvent: @escaping (SseChatEvent) -> Void
    ) async throws {
        var lines: [String] = []
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.isEmpty {
                if let event = try decodeEvent(from: lines) {
                    onEvent(event)
                }
                lines.removeAll(keepingCapacity: true)
            } else {
                lines.append(line)
            }
        }
        if !lines.isEmpty, let event = try decodeEvent(from: lines) {
            onEvent(event)
        }
    }

    private static func parseSseLines(_ lines: [String]) -> (String?, String?) {
        var event: String?
        var data: String?
        for line in lines {
            if line.hasPrefix(":") { continue }
            if line.hasPrefix("event:") {
                event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let part = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                data = (data.map { $0 + "\n" } ?? "") + part
            }
        }
        return (event, data)
    }

    private static func decodeEvent(from lines: [String]) throws -> SseChatEvent? {
        let (name, data) = parseSseLines(lines)
        guard let data, let raw = data.data(using: .utf8) else { return nil }
        let obj = try JSONDecoder().decode(ChatServerEvent.self, from: raw)
        switch name ?? obj.type {
        case "started":
            return .started
        case "message_delta":
            return .delta(obj.content ?? "")
        case "message_end":
            return .end(obj.content ?? "")
        case "error":
            return .error(obj.message ?? "处理失败")
        default:
            return nil
        }
    }
}
