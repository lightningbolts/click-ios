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
/// dim screen is the usual reason a scan fails) and returns to where it was the moment the code
/// stops being shown: it leaves, its sheet is swiped down to half height, or the app leaves the
/// foreground.
struct BoostsScreenBrightness: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isSheetCollapsed) private var isSheetCollapsed
    @State private var isOnScreen = false
    @State private var isHolding = false

    private var wantsHold: Bool { isOnScreen && scenePhase == .active && !isSheetCollapsed }

    func body(content: Content) -> some View {
        content
            .onAppear { isOnScreen = true; sync() }
            .onDisappear { isOnScreen = false; sync() }
            .onChange(of: wantsHold) { sync() }
    }

    private func sync() {
        let on = wantsHold
        guard on != isHolding else { return }
        isHolding = on
        if on { ScreenBrightness.shared.boost() } else { ScreenBrightness.shared.restore() }
    }
}

extension View {
    func boostsScreenBrightness() -> some View { modifier(BoostsScreenBrightness()) }

    /// Keeps the screen from sleeping while this is on screen (a code being scanned, a scanner).
    /// Counted, so one screen leaving never lets another's screen sleep.
    func keepsScreenAwake() -> some View {
        onAppear { ScreenAwake.hold() }.onDisappear { ScreenAwake.release() }
    }
}

@MainActor
enum ScreenAwake {
    private static var holders = 0

    static func hold() {
        holders += 1
        UIApplication.shared.isIdleTimerDisabled = true
    }

    static func release() {
        guard holders > 0 else { return }
        holders -= 1
        if holders == 0 { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

/// One owner of the screen's brightness, so overlapping code screens (a pass pushed over My QR)
/// restore the user's own level exactly once, after the last one leaves.
@MainActor
final class ScreenBrightness {
    static let shared = ScreenBrightness()

    private var holders = 0
    private var original: CGFloat?
    private var ramp: Task<Void, Never>?
    /// The level a restore is easing back to, until it gets there.
    private var restoring: CGFloat?

    private var screen: UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first { $0.activationState == .foregroundInactive })?.screen
    }

    func boost() {
        holders += 1
        guard holders == 1, let screen else { return }
        // Back on screen while still easing down: the user's level is where that ease was headed.
        original = restoring ?? screen.brightness
        restoring = nil
        animate(screen, to: 1)
    }

    func restore() {
        guard holders > 0 else { return }
        holders -= 1
        guard holders == 0, let screen, let original else { return }
        self.original = nil
        restoring = original
        animate(screen, to: original) { [weak self] in self?.restoring = nil }
    }

    /// A quick ease rather than a jump: the change reads as intentional, not a flicker.
    private func animate(_ screen: UIScreen, to target: CGFloat, completion: @escaping @MainActor () -> Void = {}) {
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
            completion()
        }
    }
}
