import Foundation

enum SseChatEvent: Equatable {
    case started(streamId: String?, eventId: Int64?)
    case delta(String, streamId: String?, eventId: Int64?)
    case end(String, streamId: String?, eventId: Int64?)
    case error(String, streamId: String?, eventId: Int64?)
}

enum ChatSSEError: Error, LocalizedError, Equatable {
    case invalidURL
    case emptyContent
    case http(status: Int, message: String)
    case conflict(ChatBusyError)
    case notFound(String)
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
        case .conflict(let busy):
            return busy.message
        case .notFound(let message):
            return message
        case .cancelled:
            return "已取消"
        case .transport(let message):
            return message
        }
    }

    var status: Int? {
        switch self {
        case .http(let status, _): return status
        case .conflict: return 409
        case .notFound: return 404
        default: return nil
        }
    }
}

/// POST `/api/chat` / GET 续传 SSE 客户端（Authorization Header，非 query token）。
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

        try await runBytesRequest(request, onEvent: onEvent)
    }

    /// 断点续传：`GET /api/chat/streams/{streamId}?afterEventId=`
    func resume(
        httpBase: String,
        token: String,
        streamId: String,
        afterEventId: Int64,
        onEvent: @escaping (SseChatEvent) -> Void
    ) async throws {
        let trimmed = streamId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChatSSEError.invalidURL }

        let base = APIClient.stripTrailingSlash(httpBase)
        var comps = URLComponents(string: "\(base)/api/chat/streams/\(trimmed)")
        comps?.queryItems = [URLQueryItem(name: "afterEventId", value: String(afterEventId))]
        guard let url = comps?.url else {
            throw ChatSSEError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        try await runBytesRequest(request, onEvent: onEvent)
    }

    /// 显式取消本轮（仅用户点「停止」时调用）。
    func cancelRemote(httpBase: String, token: String, streamId: String) async throws {
        let trimmed = streamId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChatSSEError.invalidURL }

        let base = APIClient.stripTrailingSlash(httpBase)
        guard let url = URL(string: "\(base)/api/chat/streams/\(trimmed)/cancel") else {
            throw ChatSSEError.invalidURL
        }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 200 { return }

        let body = try? JSONDecoder().decode(AuthErrorBody.self, from: data)
        let fallback: String
        switch status {
        case 401: fallback = "未登录或会话已失效"
        case 403: fallback = "无权访问该流"
        case 404: fallback = "流不存在或已过期"
        default: fallback = "取消失败（\(status)）"
        }
        if status == 404 {
            throw ChatSSEError.notFound(body?.message ?? fallback)
        }
        throw ChatSSEError.http(status: status, message: body?.message ?? fallback)
    }

    /// 用独立 Task 包装，便于 ViewModel 持有并 `cancel()` / 断连。
    @discardableResult
    func start(
        httpBase: String,
        token: String,
        content: String,
        onEvent: @escaping (SseChatEvent) -> Void,
        onComplete: @escaping (Result<Void, ChatSSEError>) -> Void
    ) -> Task<Void, Never> {
        beginTask(onComplete: onComplete) { [weak self] in
            try await self?.stream(
                httpBase: httpBase,
                token: token,
                content: content,
                onEvent: onEvent
            )
        }
    }

    @discardableResult
    func startResume(
        httpBase: String,
        token: String,
        streamId: String,
        afterEventId: Int64,
        onEvent: @escaping (SseChatEvent) -> Void,
        onComplete: @escaping (Result<Void, ChatSSEError>) -> Void
    ) -> Task<Void, Never> {
        beginTask(onComplete: onComplete) { [weak self] in
            try await self?.resume(
                httpBase: httpBase,
                token: token,
                streamId: streamId,
                afterEventId: afterEventId,
                onEvent: onEvent
            )
        }
    }

    /// 仅断开本地 URLSession；**不会**调用服务端 cancel。
    func disconnect() {
        streamTask?.cancel()
        streamTask = nil
        session?.invalidateAndCancel()
        session = nil
    }

    /// 与 `disconnect()` 相同，保留旧名给调用方。
    func cancel() {
        disconnect()
    }

    // MARK: - Internals

    private func beginTask(
        onComplete: @escaping (Result<Void, ChatSSEError>) -> Void,
        work: @escaping () async throws -> Void
    ) -> Task<Void, Never> {
        disconnect()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await work()
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

    private func runBytesRequest(
        _ request: URLRequest,
        onEvent: @escaping (SseChatEvent) -> Void
    ) async throws {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 300
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
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
                throw Self.mapHTTPError(status: status, data: collected)
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

    private static func mapHTTPError(status: Int, data: Data) -> ChatSSEError {
        if status == 409 {
            if let busy = try? JSONDecoder().decode(ChatBusyError.self, from: data) {
                return .conflict(busy)
            }
            let body = try? JSONDecoder().decode(AuthErrorBody.self, from: data)
            return .conflict(
                ChatBusyError(message: body?.message ?? "上一条消息仍在处理中")
            )
        }
        if status == 404 {
            let body = try? JSONDecoder().decode(AuthErrorBody.self, from: data)
            return .notFound(body?.message ?? "流不存在或已过期")
        }
        let body = try? JSONDecoder().decode(AuthErrorBody.self, from: data)
        let fallback: String
        switch status {
        case 400: fallback = "消息不能为空"
        case 401: fallback = "未登录或会话已失效"
        case 403: fallback = "无权访问该流"
        default: fallback = "请求失败（\(status)）"
        }
        return .http(status: status, message: body?.message ?? fallback)
    }

    // MARK: - SSE parsing

    /// 按字节缓冲拆行，避免 `AsyncBytes.lines` 在多字节 UTF-8 边界上解码失败；
    /// 并以「新 event: / 空行」双条件提交事件，兼容缺空行的流。
    private static func consumeSSE(
        bytes: URLSession.AsyncBytes,
        onEvent: @escaping (SseChatEvent) -> Void
    ) async throws {
        var buffer = Data()
        var eventName: String?
        var dataLines: [String] = []
        var frameEventId: Int64?

        func flush() {
            guard let event = decodeEvent(
                name: eventName,
                dataLines: dataLines,
                frameEventId: frameEventId
            ) else {
                eventName = nil
                dataLines.removeAll(keepingCapacity: true)
                frameEventId = nil
                return
            }
            onEvent(event)
            eventName = nil
            dataLines.removeAll(keepingCapacity: true)
            frameEventId = nil
        }

        func handleLine(_ line: String) {
            if line.isEmpty {
                flush()
                return
            }
            if line.hasPrefix(":") {
                return
            }
            if line.hasPrefix("id:") {
                let raw = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                frameEventId = Int64(raw)
                return
            }
            if line.hasPrefix("event:") {
                // 上一事件若未以空行结束，先提交，避免多段 data 拼成非法 JSON。
                if eventName != nil || !dataLines.isEmpty {
                    flush()
                }
                eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                return
            }
            if line.hasPrefix("data:") {
                let part = String(line.dropFirst(5))
                // SSE 规范：data: 后可选的一个前导空格应去掉；其余内容保留。
                if part.hasPrefix(" ") {
                    dataLines.append(String(part.dropFirst()))
                } else {
                    dataLines.append(part.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
                }
                return
            }
        }

        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                var line = String(data: lineData, encoding: .utf8) ?? ""
                if line.hasSuffix("\r") {
                    line.removeLast()
                }
                handleLine(line)
            }
        }

        if !buffer.isEmpty {
            var line = String(data: buffer, encoding: .utf8) ?? ""
            if line.hasSuffix("\r") {
                line.removeLast()
            }
            if !line.isEmpty {
                handleLine(line)
            }
        }
        if eventName != nil || !dataLines.isEmpty {
            flush()
        }
    }

    private static func decodeEvent(
        name: String?,
        dataLines: [String],
        frameEventId: Int64?
    ) -> SseChatEvent? {
        guard !dataLines.isEmpty else { return nil }
        let joined = dataLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }

        if let event = decodeJSONEvent(name: name, jsonText: joined, frameEventId: frameEventId) {
            return event
        }
        // 容错：若误拼了多段 JSON，按行分别解析。
        if dataLines.count > 1 {
            var last: SseChatEvent?
            for line in dataLines {
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if let event = decodeJSONEvent(name: name, jsonText: text, frameEventId: frameEventId) {
                    last = event
                }
            }
            return last
        }
        return nil
    }

    private static func decodeJSONEvent(
        name: String?,
        jsonText: String,
        frameEventId: Int64?
    ) -> SseChatEvent? {
        let raw = Data(jsonText.utf8)
        guard !raw.isEmpty else { return nil }
        guard let obj = try? JSONDecoder().decode(ChatServerEvent.self, from: raw) else {
            return nil
        }
        let resolved = (name?.isEmpty == false ? name : nil) ?? obj.type
        let streamId = obj.streamId
        let eventId = frameEventId ?? obj.eventId
        switch resolved {
        case "started":
            return .started(streamId: streamId, eventId: eventId)
        case "message_delta":
            return .delta(obj.content ?? "", streamId: streamId, eventId: eventId)
        case "message_end":
            return .end(obj.content ?? "", streamId: streamId, eventId: eventId)
        case "error":
            return .error(obj.message ?? obj.content ?? "处理失败", streamId: streamId, eventId: eventId)
        case "resume":
            // 可选续传提示，忽略即可。
            return nil
        default:
            return nil
        }
    }
}
