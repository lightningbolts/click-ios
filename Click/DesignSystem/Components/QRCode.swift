import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import VisionKit

/// Renders a QR code once per value (never per frame): crisp black modules, quiet zone left to
/// the white card around it.
enum QRCodeRenderer {
    static func image(for value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// The camera QR scanner with its permission states: asks once, explains a denial with a way to
/// Settings, and says so on devices without a supported camera. Every newly recognized code goes
/// to `onCode` (a code that stays in frame isn't reported again).
struct QRCameraView: View {
    @Environment(AppEnvironment.self) private var env
    /// "Camera access is required to scan …"
    let deniedMessage: String
    /// Runs once the camera is authorized (warm-ups that only make sense while scanning).
    var onAuthorized: @MainActor () async -> Void = {}
    let onCode: (String) -> Void

    @State private var permission: PermissionStatus = .notDetermined

    var body: some View {
        Group {
            if permission == .authorized {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    ClickDataScannerView(onCode: onCode)
                        .ignoresSafeArea()
                } else {
                    ContentUnavailableView(
                        "Camera scanner unavailable",
                        systemImage: "viewfinder.circle",
                        description: Text("QR scanning requires a supported physical iPhone camera.")
                    )
                    .foregroundStyle(.white)
                }
            } else if permission == .denied || permission == .restricted {
                VStack(spacing: 14) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 36))
                    Text(deniedMessage)
                        .multilineTextAlignment(.center)
                    Button("Open Settings") {
                        env.permissions.openSystemSettings()
                    }
                    .buttonStyle(.clickPrimary)
                }
                .foregroundStyle(.white)
                .padding(30)
            } else {
                ClickLoadingView(size: 34, fillsSpace: false)
            }
        }
        .task {
            let current = env.permissions.status(for: .camera)
            permission = current == .notDetermined
                ? await env.permissions.requestPermission(for: .camera)
                : current
            if permission == .authorized { await onAuthorized() }
        }
    }
}

@MainActor
private struct ClickDataScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for item in addedItems {
                if case .barcode(let barcode) = item,
                   let payload = barcode.payloadStringValue,
                   !payload.isEmpty {
                    onCode(payload)
                    return
                }
            }
        }
    }
}

/// While a code is on screen for someone else's camera, the display goes to full brightness (a
/// dim screen is the usual reason a scan fails) and returns to where it was when the code goes
/// away or the app leaves the foreground.
struct BoostsScreenBrightness: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isHolding = false

    func body(content: Content) -> some View {
        content
            .onAppear { hold(true) }
            .onDisappear { hold(false) }
            .onChange(of: scenePhase) { _, phase in hold(phase == .active) }
    }

    private func hold(_ on: Bool) {
        guard on != isHolding else { return }
        isHolding = on
        if on { ScreenBrightness.shared.boost() } else { ScreenBrightness.shared.restore() }
    }
}

extension View {
    func boostsScreenBrightness() -> some View { modifier(BoostsScreenBrightness()) }
}

/// One owner of the screen's brightness, so overlapping code screens (a pass pushed over My QR)
/// restore the user's own level exactly once, after the last one leaves.
@MainActor
final class ScreenBrightness {
    static let shared = ScreenBrightness()

    private var holders = 0
    private var original: CGFloat?
    private var ramp: Task<Void, Never>?

    private var screen: UIScreen? {
        (UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene)?.screen
    }

    func boost() {
        holders += 1
        guard holders == 1, let screen else { return }
        original = screen.brightness
        animate(screen, to: 1)
    }

    func restore() {
        guard holders > 0 else { return }
        holders -= 1
        guard holders == 0, let screen, let original else { return }
        self.original = nil
        animate(screen, to: original)
    }

    /// A quick ease rather than a jump: the change reads as intentional, not a flicker.
    private func animate(_ screen: UIScreen, to target: CGFloat) {
        ramp?.cancel()
        let start = screen.brightness
        ramp = Task { @MainActor in
            let steps = 14
            for step in 1...steps {
                guard !Task.isCancelled else { return }
                let t = Double(step) / Double(steps)
                let eased = 1 - pow(1 - t, 3)
                screen.brightness = start + (target - start) * CGFloat(eased)
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }
}
