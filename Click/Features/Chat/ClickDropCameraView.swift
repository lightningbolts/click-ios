import AVFoundation
import SwiftUI
import UIKit

/// Full-screen Click Drop camera (port of KMP `DisposableCameraShared`): live preview, flash,
/// flip, shutter flash, then a filtered preview with the ten roll looks, Retake and Send.
/// `endsAt` closes the camera when a post-connect collaboration window expires (spec §44).
struct ClickDropCameraView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var endsAt: Date?
    let onSend: (MediaDraft) -> Void

    @State private var camera = ClickDropCamera()
    @State private var state: CameraState = .preparing
    @State private var captured: Data?
    @State private var preview: UIImage?
    @State private var filter: ClickDropFilter = .natural
    @State private var flashOn = false
    @State private var shutterFlash = 0.0
    @State private var isSending = false

    enum CameraState: Equatable { case preparing, ready, capturing, flipping, denied }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Captured photo, \(filter.name) look")
            } else if state == .denied {
                ContentUnavailableView("Camera access is off", systemImage: "camera.fill",
                                       description: Text("Allow camera access in Settings to take a Click Drop."))
                    .foregroundStyle(.white)
            } else {
                CameraPreviewLayer(session: camera.session).ignoresSafeArea()
            }
            Color.white.opacity(shutterFlash).ignoresSafeArea().allowsHitTesting(false)
            chrome
        }
        .statusBarHidden()
        .task { state = await camera.start() ? .ready : .denied }
        .task(id: endsAt) {
            guard let endsAt else { return }
            try? await Task.sleep(for: .seconds(max(0, endsAt.timeIntervalSinceNow)))
            if !Task.isCancelled { dismiss() }
        }
        .onDisappear { camera.stop() }
        .task(id: filter) { await renderPreview() }
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack(spacing: 14) {
            HStack {
                roundButton(captured == nil ? "xmark" : "arrow.uturn.backward", label: captured == nil ? "Close camera" : "Retake photo") {
                    if captured == nil { dismiss() } else { retake() }
                }
                Spacer()
                VStack(spacing: 2) {
                    Text("Click Drops").font(ClickTypography.bodyEmphasized)
                    Text("Develops in 24 hours").font(ClickTypography.caption).opacity(0.75)
                }
                .foregroundStyle(.white)
                Spacer()
                if captured == nil {
                    roundButton(flashOn ? "bolt.fill" : "bolt.slash", label: flashOn ? "Flash on" : "Flash off") { flashOn.toggle() }
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .background(.black.opacity(0.65))

            Spacer()

            VStack(spacing: 14) {
                if captured != nil { filterStrip }
                Text(statusText)
                    .font(ClickTypography.metadataEmphasized)
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.black, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.16)))
                    .accessibilityAddTraits(.updatesFrequently)
                controls
            }
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.72))
        }
    }

    private var statusText: String {
        if captured != nil { return isSending ? "Sending…" : "Ready for the roll" }
        switch state {
        case .capturing: return "Capturing…"
        case .flipping: return "Flipping…"
        case .ready: return "Snap once"
        case .preparing, .denied: return "Preparing…"
        }
    }

    private var controls: some View {
        HStack {
            if captured == nil {
                roundButton("arrow.triangle.2.circlepath.camera", label: "Flip camera") {
                    Task {
                        state = .flipping
                        await camera.flip()
                        state = .ready
                    }
                }
                .disabled(state != .ready)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
            Spacer()
            if captured == nil {
                Button(action: shoot) {
                    Circle().fill(.white).frame(width: 64, height: 64)
                        .padding(5)
                        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 3))
                }
                .buttonStyle(.plain)
                .disabled(state != .ready)
                .accessibilityLabel("Take Click Drop photo")
            } else {
                Button(action: send) {
                    Label("Send", systemImage: "paperplane.fill")
                        .font(ClickTypography.bodyEmphasized)
                        .padding(.horizontal, 26)
                        .frame(height: 56)
                        .background(ClickColors.primaryActionFill, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(isSending)
                .accessibilityLabel("Send to Click Drops")
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 32)
    }

    /// Horizontal roll of looks with a frame counter ("3/10").
    private var filterStrip: some View {
        VStack(spacing: 8) {
            Text("\(filter.name) · \(filter.rawValue + 1)/\(ClickDropFilter.allCases.count)")
                .font(ClickTypography.metadataEmphasized)
                .foregroundStyle(.white)
                .monospacedDigit()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ClickDropFilter.allCases) { look in
                        Button {
                            ClickHaptics.selection()
                            filter = look
                        } label: {
                            Text(look.name)
                                .font(ClickTypography.supportingEmphasized)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .foregroundStyle(look == filter ? .black : .white)
                                .background(look == filter ? Color.white : Color.white.opacity(0.14), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(look == filter ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private func roundButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.16), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Actions

    private func shoot() {
        ClickHaptics.impact(.light)
        state = .capturing
        if !reduceMotion {
            shutterFlash = 0.82
            withAnimation(.easeOut(duration: 0.23)) { shutterFlash = 0 }
        }
        Task {
            let data = await camera.capture(flash: flashOn)
            state = .ready
            guard let data else { return }
            captured = data
            await renderPreview()
        }
    }

    private func retake() {
        captured = nil
        preview = nil
        filter = .natural
    }

    private func renderPreview() async {
        guard let captured else { return }
        let look = filter
        let rendered = await Task.detached(priority: .userInitiated) {
            look.render(jpeg: captured, maxDimension: ClickDropFilter.previewMaxDimension).flatMap(UIImage.init(data:))
        }.value
        if look == filter { preview = rendered }
    }

    private func send() {
        guard let captured else { return }
        isSending = true
        let look = filter
        Task {
            let jpeg = await Task.detached(priority: .userInitiated) {
                look.render(jpeg: captured, maxDimension: ClickDropFilter.sendMaxDimension)
            }.value
            isSending = false
            guard let jpeg else { return }
            var draft = MediaDraft(kind: .image, data: jpeg, mimeType: "image/jpeg")
            draft.isClickDrop = true
            ClickHaptics.success()
            onSend(draft)
            dismiss()
        }
    }
}

/// Owns the capture session on its own queue; the UI only awaits results.
final class ClickDropCamera: NSObject, @unchecked Sendable, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "click.drop.camera")
    private let output = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    private var pending: CheckedContinuation<Data?, Never>?

    /// Asks for access, configures the back camera and starts running. False when denied.
    func start() async -> Bool {
        guard await AVCaptureDevice.requestAccess(for: .video) else { return false }
        return await withCheckedContinuation { continuation in
            queue.async {
                if self.input == nil {
                    self.session.beginConfiguration()
                    self.session.sessionPreset = .photo
                    self.use(position: .back)
                    if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
                    self.session.commitConfiguration()
                }
                if !self.session.isRunning { self.session.startRunning() }
                continuation.resume(returning: self.input != nil)
            }
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    func flip() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.session.beginConfiguration()
                self.use(position: self.input?.device.position == .back ? .front : .back)
                self.session.commitConfiguration()
                continuation.resume()
            }
        }
    }

    func capture(flash: Bool) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.pending == nil, self.session.isRunning else {
                    continuation.resume(returning: nil)
                    return
                }
                self.pending = continuation
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                if self.output.supportedFlashModes.contains(.on) { settings.flashMode = flash ? .on : .off }
                self.output.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        queue.async {
            self.pending?.resume(returning: data)
            self.pending = nil
        }
    }

    /// Must run on `queue` inside a configuration block.
    private func use(position: AVCaptureDevice.Position) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let newInput = try? AVCaptureDeviceInput(device: device) else { return }
        if let input { session.removeInput(input) }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            input = newInput
        } else if let input {
            session.addInput(input)
        }
    }
}

/// `AVCaptureVideoPreviewLayer` host.
private struct CameraPreviewLayer: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}
