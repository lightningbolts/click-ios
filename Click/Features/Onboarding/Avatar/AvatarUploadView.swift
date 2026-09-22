import SwiftUI
import PhotosUI
import UIKit

/// Phase 2 Avatar selection & upload screen with live preview and skippable option.
public struct AvatarUploadView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImageData: Data?
    @State private var isUploading: Bool = false
    @State private var errorMessage: String?
    @State private var showCamera: Bool = false

    let onUpload: (Data) async throws -> Void
    let onSkip: () -> Void

    public init(
        onUpload: @escaping (Data) async throws -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.onUpload = onUpload
        self.onSkip = onSkip
    }

    private var hasSelectedImage: Bool {
        selectedImageData != nil
    }

    public var body: some View {
        VStack(spacing: 0) {
            OnboardingHeaderView(
                title: "Add a photo",
                subtitle: "A real face goes a long way — but you can skip and add it later from Settings."
            )

            ScrollView {
                VStack(spacing: ClickSpacing.lg) {
                    // Circular Preview (168pt)
                    ZStack {
                        Circle()
                            .fill(ClickColors.surfaceContainerLow)
                            .frame(width: 168, height: 168)
                            .overlay(
                                Circle()
                                    .stroke(ClickColors.quietBorder, lineWidth: 2)
                            )

                        if let data = selectedImageData, let uiImage = UIImage(data: data) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 168, height: 168)
                                .clipShape(Circle())
                        } else {
                            VStack(spacing: ClickSpacing.xs) {
                                Image(systemName: "person.fill")
                                    .font(.system(size: 64))
                                    .foregroundStyle(ClickColors.outline.opacity(0.6))
                            }
                        }

                        if isUploading {
                            Circle()
                                .fill(Color.black.opacity(0.4))
                                .frame(width: 168, height: 168)
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(1.3)
                        }
                    }
                    .padding(.vertical, ClickSpacing.md)

                    // Source Buttons: Library & Camera
                    HStack(spacing: ClickSpacing.md) {
                        PhotosPicker(
                            selection: $selectedItem,
                            matching: .images,
                            photoLibrary: .shared()
                        ) {
                            HStack(spacing: ClickSpacing.xs) {
                                Image(systemName: "photo.on.rectangle.angled")
                                Text("From library")
                                    .font(ClickTypography.labelMedium)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(ClickColors.surfaceContainerLow)
                            .foregroundStyle(ClickColors.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusButton))
                            .overlay(
                                RoundedRectangle(cornerRadius: ClickSpacing.radiusButton)
                                    .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
                            )
                        }

                        Button(action: {
                            showCamera = true
                        }) {
                            HStack(spacing: ClickSpacing.xs) {
                                Image(systemName: "camera.fill")
                                Text("Take photo")
                                    .font(ClickTypography.labelMedium)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(ClickColors.surfaceContainerLow)
                            .foregroundStyle(ClickColors.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusButton))
                            .overlay(
                                RoundedRectangle(cornerRadius: ClickSpacing.radiusButton)
                                    .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
                            )
                        }
                    }
                    .padding(.horizontal, ClickSpacing.lg)

                    if let error = errorMessage {
                        Text(error)
                            .font(ClickTypography.captionSmall)
                            .foregroundStyle(ClickColors.error)
                            .padding(.horizontal, ClickSpacing.lg)
                    }

                    Spacer(minLength: ClickSpacing.xl)

                    // Action CTAs
                    VStack(spacing: ClickSpacing.sm) {
                        Button(action: uploadAvatar) {
                            HStack(spacing: ClickSpacing.sm) {
                                if isUploading {
                                    ProgressView()
                                        .tint(ClickColors.onPrimary)
                                    Text("Uploading…")
                                        .font(ClickTypography.titleMedium)
                                        .fontWeight(.bold)
                                } else {
                                    Text(hasSelectedImage ? "Use this photo" : "Choose a photo")
                                        .font(ClickTypography.titleMedium)
                                        .fontWeight(.bold)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(hasSelectedImage && !isUploading ? ClickColors.primary : ClickColors.primary.opacity(0.35))
                            .foregroundStyle(ClickColors.onPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusButton))
                        }
                        .disabled(!hasSelectedImage || isUploading)

                        Button(action: {
                            ClickHaptics.selection()
                            onSkip()
                        }) {
                            Text("Skip for now")
                                .font(ClickTypography.labelLarge)
                                .foregroundStyle(ClickColors.textSecondary)
                                .padding(.vertical, ClickSpacing.sm)
                        }
                        .disabled(isUploading)
                    }
                    .padding(.horizontal, ClickSpacing.lg)
                    .padding(.bottom, ClickSpacing.xl)
                }
            }
        }
        .background(ClickColors.background.ignoresSafeArea())
        .onChange(of: selectedItem) { _, newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self) {
                    selectedImageData = data
                    errorMessage = nil
                }
            }
        }
        .sheet(isPresented: $showCamera) {
            NativeCameraPicker(onImageCaptured: { data in
                selectedImageData = data
                errorMessage = nil
            })
        }
    }

    private func uploadAvatar() {
        guard let data = selectedImageData else { return }
        ClickHaptics.impact(.medium)
        isUploading = true
        errorMessage = nil

        Task {
            do {
                try await onUpload(data)
                ClickHaptics.success()
            } catch {
                errorMessage = "Could not upload photo. Try again."
                ClickHaptics.error()
            }
            isUploading = false
        }
    }
}

/// Native UIKit camera capture integration.
public struct NativeCameraPicker: UIViewControllerRepresentable {
    let onImageCaptured: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    public init(onImageCaptured: @escaping (Data) -> Void) {
        self.onImageCaptured = onImageCaptured
    }

    public func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
            picker.cameraCaptureMode = .photo
        } else {
            // Simulator or hardware without camera falls back to photo library
            picker.sourceType = .photoLibrary
        }
        picker.delegate = context.coordinator
        picker.allowsEditing = true
        return picker
    }

    public func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: NativeCameraPicker

        init(_ parent: NativeCameraPicker) {
            self.parent = parent
        }

        public func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            if let img = image, let data = img.jpegData(compressionQuality: 0.85) {
                parent.onImageCaptured(data)
            }
            parent.dismiss()
        }

        public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
