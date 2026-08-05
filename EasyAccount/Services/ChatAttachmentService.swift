import Foundation

/// 聊天附件上传（`POST /api/chat/attachments` multipart）。
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
