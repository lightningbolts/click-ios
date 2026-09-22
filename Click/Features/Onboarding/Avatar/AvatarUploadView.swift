import SwiftUI
import PhotosUI

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
                        .font(ClickTypography.labelSmall)
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
            CameraMockPicker(onImageCaptured: { data in
                selectedImageData = data
                errorMessage = nil
                showCamera = false
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

/// Fallback camera capture helper for testing & device support.
private struct CameraMockPicker: View {
    let onImageCaptured: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: ClickSpacing.lg) {
                Spacer()
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 72))
                    .foregroundStyle(ClickColors.primary)

                Text("Camera Preview")
                    .font(ClickTypography.headlineMedium)

                Text("In the simulator, click below to take a sample profile photo.")
                    .font(ClickTypography.bodyMedium)
                    .foregroundStyle(ClickColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, ClickSpacing.lg)

                Spacer()

                Button("Capture Photo") {
                    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200))
                    let image = renderer.image { ctx in
                        UIColor(hex: "#630ED4").setFill()
                        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
                        UIColor.white.setFill()
                        let font = UIFont(name: "Manrope-Bold", size: 64) ?? UIFont.boldSystemFont(ofSize: 64)
                        let text = "C"
                        let attrs: [NSAttributedString.Key: Any] = [
                            .font: font,
                            .foregroundColor: UIColor.white
                        ]
                        let size = (text as NSString).size(withAttributes: attrs)
                        (text as NSString).draw(at: CGPoint(x: (200 - size.width) / 2, y: (200 - size.height) / 2), withAttributes: attrs)
                    }
                    if let png = image.pngData() {
                        onImageCaptured(png)
                    }
                }
                .font(ClickTypography.titleMedium)
                .fontWeight(.bold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(ClickColors.primary)
                .foregroundStyle(ClickColors.onPrimary)
                .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusButton))
                .padding(.horizontal, ClickSpacing.lg)
                .padding(.bottom, ClickSpacing.xl)
            }
            .navigationTitle("Camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
