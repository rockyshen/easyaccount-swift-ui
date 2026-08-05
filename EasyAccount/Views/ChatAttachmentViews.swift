import CoreTransferable
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
