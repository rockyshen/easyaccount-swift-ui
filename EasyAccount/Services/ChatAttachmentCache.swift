import Foundation
import UIKit

/// 聊天附件本地缓存：列表用缩略图常驻磁盘；原图按需缓存，避免 messages 常驻大块 Data。
enum ChatAttachmentCache {
    private static let rootFolder = "EasyAccount/AttachmentCache"

    static func saveThumbnail(userId: String, id: String, image: UIImage) {
        guard let data = image.chatAttachmentJPEG(
            maxPixel: ChatAttachmentLimits.thumbnailMaxPixel,
            quality: ChatAttachmentLimits.thumbnailJpegQuality
        ) else { return }
        write(data, to: thumbnailURL(userId: userId, id: id))
    }

    static func saveThumbnail(userId: String, id: String, jpegData: Data) {
        guard let image = UIImage(data: jpegData) else {
            write(jpegData, to: thumbnailURL(userId: userId, id: id))
            return
        }
        saveThumbnail(userId: userId, id: id, image: image)
    }

    static func saveOriginal(userId: String, id: String, jpegData: Data) {
        write(jpegData, to: originalURL(userId: userId, id: id))
    }

    static func loadThumbnailImage(userId: String, id: String) -> UIImage? {
        guard let data = loadThumbnailData(userId: userId, id: id) else { return nil }
        return UIImage(data: data)
    }

    static func loadThumbnailData(userId: String, id: String) -> Data? {
        try? Data(contentsOf: thumbnailURL(userId: userId, id: id))
    }

    static func loadOriginalImage(userId: String, id: String) -> UIImage? {
        guard let data = loadOriginalData(userId: userId, id: id) else { return nil }
        return UIImage(data: data)
    }

    static func loadOriginalData(userId: String, id: String) -> Data? {
        try? Data(contentsOf: originalURL(userId: userId, id: id))
    }

    /// 上传成功后把 local_* 缓存键替换为服务端 attachmentId。
    static func rekey(userId: String, from oldId: String, to newId: String) {
        let trimmedOld = oldId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNew = newId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOld.isEmpty, !trimmedNew.isEmpty, trimmedOld != trimmedNew else { return }
        moveIfNeeded(
            from: thumbnailURL(userId: userId, id: trimmedOld),
            to: thumbnailURL(userId: userId, id: trimmedNew)
        )
        moveIfNeeded(
            from: originalURL(userId: userId, id: trimmedOld),
            to: originalURL(userId: userId, id: trimmedNew)
        )
    }

    static func clearAll(userId: String) {
        let dir = userDirectory(userId: userId)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Paths

    private static func thumbnailURL(userId: String, id: String) -> URL {
        variantDirectory(userId: userId, variant: "thumb")
            .appendingPathComponent(safeFileName(id) + ".jpg")
    }

    private static func originalURL(userId: String, id: String) -> URL {
        variantDirectory(userId: userId, variant: "original")
            .appendingPathComponent(safeFileName(id) + ".jpg")
    }

    private static func variantDirectory(userId: String, variant: String) -> URL {
        let dir = userDirectory(userId: userId).appendingPathComponent(variant, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func userDirectory(userId: String) -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent(rootFolder, isDirectory: true)
            .appendingPathComponent(sanitizedUserId(userId), isDirectory: true)
    }

    private static func sanitizedUserId(_ userId: String) -> String {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed.isEmpty ? "anonymous" : trimmed
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(safe.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    private static func safeFileName(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = String(trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return mapped.isEmpty ? UUID().uuidString : mapped
    }

    private static func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    private static func moveIfNeeded(from: URL, to: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from.path) else { return }
        try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: to.path) {
            try? fm.removeItem(at: from)
            return
        }
        try? fm.moveItem(at: from, to: to)
    }
}
