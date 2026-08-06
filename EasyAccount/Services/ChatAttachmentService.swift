import Foundation

/// 聊天附件上传 / 按需拉取（`/api/chat/attachments`）。
enum ChatAttachmentService {
    static func upload(
        httpBase: String,
        token: String,
        jpegData: Data,
        filename: String = "image.jpg"
    ) async throws -> ChatAttachmentDTO {
        guard !jpegData.isEmpty else {
            throw APIError(status: 400, message: "请上传图片文件")
        }
        let base = APIClient.stripTrailingSlash(httpBase)
        guard let url = URL(string: "\(base)/api/chat/attachments") else {
            throw APIError(status: -1, message: "无效的服务地址")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append(multipartField(name: "kind", value: "image", boundary: boundary))
        body.append(
            multipartFile(
                name: "file",
                filename: filename,
                mimeType: "image/jpeg",
                data: jpegData,
                boundary: boundary
            )
        )
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if !(200..<300).contains(status) {
            let errorBody = try? JSONDecoder().decode(AuthErrorBody.self, from: data)
            let fallback: String
            switch status {
            case 401: fallback = "未登录或会话已失效"
            case 413: fallback = "图片过大"
            case 415: fallback = "不支持的文件类型"
            default: fallback = errorBody?.message ?? "上传失败（\(status)）"
            }
            throw APIError(status: status, message: errorBody?.message ?? fallback)
        }
        return try JSONDecoder().decode(ChatAttachmentDTO.self, from: data)
    }

    /// 拉取附件字节：`GET /api/chat/attachments/{id}/content?variant=`
    /// 若 content 接口尚未部署，回退元数据里的 `url` / `thumbnailUrl`。
    static func fetchContent(
        httpBase: String,
        token: String,
        attachmentId: String,
        variant: ChatAttachmentContentVariant
    ) async throws -> Data {
        let id = attachmentId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw APIError(status: 400, message: "附件无效或已过期")
        }

        let base = APIClient.stripTrailingSlash(httpBase)
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var comps = URLComponents(string: "\(base)/api/chat/attachments/\(encodedId)/content")
        comps?.queryItems = [URLQueryItem(name: "variant", value: variant.rawValue)]
        if let url = comps?.url {
            do {
                return try await downloadBinary(url: url, token: token)
            } catch let api as APIError where api.status == 404 || api.status == 405 {
                // 旧后端可能尚未提供 /content，走元数据 URL。
            } catch {
                throw error
            }
        }

        let meta = try await fetchMetadata(httpBase: httpBase, token: token, attachmentId: id)
        let remote: String?
        switch variant {
        case .thumbnail:
            remote = meta.thumbnailUrl ?? meta.url
        case .original:
            remote = meta.url ?? meta.thumbnailUrl
        }
        guard let remote, let remoteURL = URL(string: remote), !remote.isEmpty else {
            throw APIError(status: 404, message: "附件原图暂不可用")
        }
        return try await downloadBinary(url: remoteURL, token: token, sendAuthIfRelative: true)
    }

    static func fetchMetadata(
        httpBase: String,
        token: String,
        attachmentId: String
    ) async throws -> ChatAttachmentDTO {
        let id = attachmentId.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let base = APIClient.stripTrailingSlash(httpBase)
        guard let url = URL(string: "\(base)/api/chat/attachments/\(encodedId)") else {
            throw APIError(status: -1, message: "无效的服务地址")
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if !(200..<300).contains(status) {
            let errorBody = try? JSONDecoder().decode(AuthErrorBody.self, from: data)
            throw APIError(
                status: status,
                message: errorBody?.message ?? (status == 404 ? "附件不存在或已过期" : "获取附件失败（\(status)）")
            )
        }
        return try JSONDecoder().decode(ChatAttachmentDTO.self, from: data)
    }

    // MARK: - Private

    private static func downloadBinary(
        url: URL,
        token: String,
        sendAuthIfRelative: Bool = true
    ) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "GET"
        // 同源 API 带 Bearer；若是绝对签名 URL，后端可不校验 Header。
        if sendAuthIfRelative {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("image/*,application/octet-stream", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if !(200..<300).contains(status) {
            let errorBody = try? JSONDecoder().decode(AuthErrorBody.self, from: data)
            throw APIError(
                status: status,
                message: errorBody?.message ?? "下载附件失败（\(status)）"
            )
        }
        guard !data.isEmpty else {
            throw APIError(status: 500, message: "附件内容为空")
        }
        return data
    }

    private static func multipartField(name: String, value: String, boundary: String) -> Data {
        var part = Data()
        part.append(Data("--\(boundary)\r\n".utf8))
        part.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        part.append(Data("\(value)\r\n".utf8))
        return part
    }

    private static func multipartFile(
        name: String,
        filename: String,
        mimeType: String,
        data: Data,
        boundary: String
    ) -> Data {
        var part = Data()
        part.append(Data("--\(boundary)\r\n".utf8))
        part.append(
            Data(
                "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8
            )
        )
        part.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        part.append(data)
        part.append(Data("\r\n".utf8))
        return part
    }
}
