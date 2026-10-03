import SwiftUI
import PhotosUI
import UIKit

/// Profile photo picker (onboarding's last step, and Me): live preview, library or camera, skippable.
public struct AvatarUploadView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImageData: Data?
    @State private var isUploading: Bool = false
    @State private var errorMessage: String?
    @State private var showCamera: Bool = false
    @State private var cameraPermissionDenied: Bool = false

    let title: String
    let subtitle: String
    let skipTitle: String
    let onUpload: (Data) async throws -> Void
    let onSkip: () -> Void

    /// The Me root reuses this editor with its own copy; onboarding keeps the defaults.
    public init(
        title: String = "Add a photo",
        subtitle: String = "A real face helps people you meet recognize you. You can skip and add one later from your profile.",
        skipTitle: String = "Skip for now",
        onUpload: @escaping (Data) async throws -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.skipTitle = skipTitle
        self.onUpload = onUpload
        self.onSkip = onSkip
    }

    private var hasSelectedImage: Bool {
        selectedImageData != nil
    }

    public var body: some View {
        OnboardingPage(title: title, subtitle: subtitle) {
            VStack(spacing: ClickSpacing.md) {
                // Tapping the preview opens the library too.
                PhotosPicker(selection: $selectedItem, matching: .images, photoLibrary: .shared()) {
                    preview
                }
                .buttonStyle(.plain)
                .disabled(isUploading)
                .accessibilityLabel(hasSelectedImage ? "Change photo" : "Choose a photo")

                Button(action: requestCamera) {
                    Label("Take a photo", systemImage: "camera")
                        .font(ClickTypography.supportingEmphasized)
                        .padding(.horizontal, ClickSpacing.md)
                        .frame(minHeight: ClickMetrics.chipHeight)
                        .background(ClickColors.fillSubtle, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(ClickColors.textPrimary)
                .disabled(isUploading)

                if let errorMessage {
                    VStack(spacing: ClickSpacing.xs) {
                        FormNotice(text: errorMessage)
                        if cameraPermissionDenied {
                            Button("Open Settings") { env.permissions.openSystemSettings() }
                                .font(ClickTypography.supportingEmphasized)
                                .foregroundStyle(ClickColors.accentForeground)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, ClickSpacing.md)
        } actions: {
            if hasSelectedImage {
                Button(action: uploadAvatar) {
                    if isUploading { ProgressView() } else { Text("Use this photo") }
                }
                .buttonStyle(.clickPrimary)
                .disabled(isUploading)
            } else {
                // Never a disabled "Choose a photo": the primary action opens the picker.
                PhotosPicker(selection: $selectedItem, matching: .images, photoLibrary: .shared()) {
                    Text("Choose a photo")
                }
                .buttonStyle(.clickPrimary)
            }
            Button(skipTitle) {
                ClickHaptics.selection()
                onSkip()
            }
            .buttonStyle(.onboardingText)
            .disabled(isUploading)
        }
        .animation(ClickMotion.subtleFade, value: errorMessage)
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

    private static let previewSize: CGFloat = 176

    private var preview: some View {
        ZStack {
            Circle().fill(ClickColors.surface)
            if let data = selectedImageData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(ClickColors.fillStrong)
            }
            if isUploading {
                Circle().fill(.black.opacity(0.4))
                ProgressView().tint(.white).controlSize(.large)
            }
        }
        .frame(width: Self.previewSize, height: Self.previewSize)
        .overlay(alignment: .bottomTrailing) {
            if !isUploading {
                Image(systemName: hasSelectedImage ? "pencil" : "plus")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(ClickColors.primaryActionForeground)
                    .frame(width: 44, height: 44)
                    .background(ClickColors.primaryActionFill, in: Circle())
                    .overlay(Circle().stroke(ClickColors.background, lineWidth: 4))
                    .offset(x: -4, y: -4)
            }
        }
    }

    private func requestCamera() {
        errorMessage = nil
        cameraPermissionDenied = false

        // Simulator/no-camera environments may use the picker's photo-library fallback without
        // asking for a camera permission the device cannot grant.
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            showCamera = true
            return
        }

        Task {
            let status = await env.permissions.requestPermission(for: .camera)
            if status.isAuthorized {
                showCamera = true
            } else {
                cameraPermissionDenied = true
                errorMessage = "Camera access is required to take a profile photo."
            }
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
