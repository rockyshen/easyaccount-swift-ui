import CoreTransferable
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum ChatAttachmentLimits {
    static let maxCount = 9
    static let maxPixel: CGFloat = 1600
    static let jpegQuality: CGFloat = 0.78
}

/// PhotosPicker → UIImage（Data 直接 Transferable 在部分系统上不稳定）。
struct ChatPickedImage: Transferable {
    let image: UIImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            guard let image = UIImage(data: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return ChatPickedImage(image: image)
        }
    }
}

extension UIImage {
    /// 压缩为聊天附件 JPEG，控制边长与体积。
    func chatAttachmentJPEG(
        maxPixel: CGFloat = ChatAttachmentLimits.maxPixel,
        quality: CGFloat = ChatAttachmentLimits.jpegQuality
    ) -> Data? {
        let longest = max(size.width, size.height)
        let image: UIImage
        if longest > maxPixel, longest > 0 {
            let scale = maxPixel / longest
            let newSize = CGSize(width: size.width * scale, height: size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            image = renderer.image { _ in
                draw(in: CGRect(origin: .zero, size: newSize))
            }
        } else {
            image = self
        }
        return image.jpegData(compressionQuality: quality)
    }
}

/// 系统相机拍照。
struct CameraImagePicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImage: (UIImage) -> Void
        let onCancel: () -> Void

        init(onImage: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onImage = onImage
            self.onCancel = onCancel
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            } else {
                onCancel()
            }
        }
    }
}

/// Cursor 式待命缩略图：圆角预览 + 右上角删除。
struct DraftAttachmentThumbnail: View {
    let image: UIImage
    var onTap: () -> Void
    var onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onTap) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(EATheme.label)
                    .frame(width: 22, height: 22)
                    .background(EATheme.surface.opacity(0.92), in: Circle())
                    .shadow(color: Color.black.opacity(0.12), radius: 2, y: 1)
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel("删除附件")
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
    }
}

/// 全屏查看待命/气泡中的图片。
struct ChatAttachmentPreviewView: View {
    let image: UIImage
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()

            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .white.opacity(0.28))
                    }
                    .padding(.trailing, 16)
                    .padding(.top, 12)
                }
                Spacer()
            }
        }
    }
}

// MARK: - Cursor 式加号底部选图面板

struct RecentPhotoItem: Identifiable, Equatable {
    let id: String
    let thumbnail: UIImage
    let asset: PHAsset

    static func == (lhs: RecentPhotoItem, rhs: RecentPhotoItem) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class RecentPhotoLibrary: ObservableObject {
    @Published private(set) var items: [RecentPhotoItem] = []
    @Published private(set) var authorizationDenied = false
    @Published private(set) var isLoading = false

    private let imageManager = PHCachingImageManager()

    func reload(limit: Int = 30) {
        isLoading = true
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            fetchRecent(limit: limit)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] newStatus in
                Task { @MainActor in
                    guard let self else { return }
                    if newStatus == .authorized || newStatus == .limited {
                        self.fetchRecent(limit: limit)
                    } else {
                        self.authorizationDenied = true
                        self.isLoading = false
                        self.items = []
                    }
                }
            }
        default:
            authorizationDenied = true
            isLoading = false
            items = []
        }
    }

    func loadFullImage(for item: RecentPhotoItem) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            final class ResumeBox: @unchecked Sendable {
                var done = false
            }
            let box = ResumeBox()

            imageManager.requestImage(
                for: item.asset,
                targetSize: CGSize(width: 2048, height: 2048),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return }
                guard !box.done else { return }
                box.done = true
                continuation.resume(returning: image)
            }
        }
    }

    private func fetchRecent(limit: Int) {
        authorizationDenied = false
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        let result = PHAsset.fetchAssets(with: .image, options: options)

        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }

        guard !assets.isEmpty else {
            items = []
            isLoading = false
            return
        }

        let targetSize = CGSize(width: 240, height: 240)
        let requestOptions = PHImageRequestOptions()
        // fastFormat 通常只回调一次，适合横滑缩略图条。
        requestOptions.deliveryMode = .fastFormat
        requestOptions.resizeMode = .fast
        requestOptions.isNetworkAccessAllowed = true

        let group = DispatchGroup()
        var collected: [RecentPhotoItem] = []
        let lock = NSLock()

        for asset in assets {
            group.enter()
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: requestOptions
            ) { image, _ in
                defer { group.leave() }
                guard let image else { return }
                let item = RecentPhotoItem(
                    id: asset.localIdentifier,
                    thumbnail: image,
                    asset: asset
                )
                lock.lock()
                collected.append(item)
                lock.unlock()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let order = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($1.localIdentifier, $0) })
            self.items = collected.sorted {
                (order[$0.id] ?? 0) < (order[$1.id] ?? 0)
            }
            self.isLoading = false
        }
    }
}

/// 加号弹出的底部面板：近期照片横滑 + 相册 / 拍照 / 文件。
struct ChatAttachSheet: View {
    @Binding var isPresented: Bool
    var remainingSlots: Int
    var onPickRecent: (UIImage) -> Void
    var onPhotos: () -> Void
    var onCamera: () -> Void
    var onFiles: () -> Void

    @StateObject private var recentLibrary = RecentPhotoLibrary()
    @State private var pickingRecentId: String?

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(EATheme.tertiary.opacity(0.55))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 8)

            ZStack {
                Text("添加附件")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(EATheme.label)

                HStack {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(EATheme.label)
                            .frame(width: 32, height: 32)
                            .background(EATheme.surfaceElevated, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")

                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            recentStrip
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                attachRow(systemName: "photo.on.rectangle", title: "相册", action: onPhotos)
                divider
                attachRow(systemName: "camera", title: "拍照", action: onCamera)
                divider
                attachRow(systemName: "folder", title: "文件", action: onFiles)
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 12)
        }
        .background(EATheme.surface.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(22)
        .onAppear {
            recentLibrary.reload()
        }
    }

    private var recentStrip: some View {
        Group {
            if recentLibrary.authorizationDenied {
                Text("未获得相册权限，可点下方「相册」选择，或在系统设置中开启")
                    .font(.system(size: 13))
                    .foregroundStyle(EATheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
            } else if recentLibrary.items.isEmpty && !recentLibrary.isLoading {
                Text("暂无最近照片")
                    .font(.system(size: 13))
                    .foregroundStyle(EATheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(recentLibrary.items) { item in
                            Button {
                                pickRecent(item)
                            } label: {
                                ZStack {
                                    Image(uiImage: item.thumbnail)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 88, height: 88)
                                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                                    if pickingRecentId == item.id {
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .fill(Color.black.opacity(0.28))
                                            .frame(width: 88, height: 88)
                                        ProgressView()
                                            .tint(.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(pickingRecentId != nil)
                            .accessibilityLabel("最近照片")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
                .frame(height: 100)
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(EATheme.surfaceElevated)
            .frame(height: 1)
            .padding(.leading, 52)
    }

    private func attachRow(systemName: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(EATheme.label)
                    .frame(width: 28, alignment: .center)

                Text(title)
                    .font(.system(size: 17))
                    .foregroundStyle(EATheme.label)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pickRecent(_ item: RecentPhotoItem) {
        guard remainingSlots > 0 else { return }
        guard pickingRecentId == nil else { return }
        pickingRecentId = item.id
        Task {
            let image = await recentLibrary.loadFullImage(for: item) ?? item.thumbnail
            onPickRecent(image)
            pickingRecentId = nil
        }
    }
}
