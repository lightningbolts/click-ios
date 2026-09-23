import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import VisionKit

public struct AddClickView: View {
    @Environment(AppEnvironment.self) private var env

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add Click")
                        .font(ClickTypography.headlineLarge)
                        .foregroundStyle(ClickColors.textPrimary)
                    Text("Connect in person or join a nearby community")
                        .font(ClickTypography.bodyMedium)
                        .foregroundStyle(ClickColors.textSecondary)
                }

                Button {
                    ClickHaptics.impact(.medium)
                    env.router.addClickPath.append(.tapConnect)
                } label: {
                    HStack(spacing: 18) {
                        ZStack {
                            Circle()
                                .fill(ClickColors.primary.opacity(0.18))
                                .frame(width: 58, height: 58)
                            Image(systemName: "wave.3.right.circle.fill")
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundStyle(ClickColors.primary)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tap to Connect")
                                .font(ClickTypography.headlineSmall)
                                .foregroundStyle(ClickColors.textPrimary)
                            Text("Nearby handshake with Bluetooth and audio")
                                .font(ClickTypography.bodyMedium)
                                .foregroundStyle(ClickColors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(ClickColors.textSecondary)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity)
                    .background(ClickColors.surfaceContainerLow)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .buttonStyle(.plain)

                VStack(spacing: 0) {
                    addClickRow(title: "My QR", subtitle: "Share your code", systemImage: "qrcode") {
                        env.router.addClickPath.append(.myQR)
                    }
                    Divider().padding(.leading, 62)
                    addClickRow(title: "Scan QR", subtitle: "Friend or hub code", systemImage: "viewfinder") {
                        env.router.addClickPath.append(.scanQR)
                    }
                    Divider().padding(.leading, 62)
                    addClickUnavailableRow(
                        title: "Create Group Chat",
                        subtitle: "Start a verified group with your Clicks",
                        systemImage: "person.3.fill"
                    )
                    Divider().padding(.leading, 62)
                    addClickUnavailableRow(
                        title: "Create Community Hub",
                        subtitle: "Host a venue for nearby Clicks",
                        systemImage: "megaphone.fill"
                    )
                    Divider().padding(.leading, 62)
                    addClickUnavailableRow(
                        title: "Join Community Hub",
                        subtitle: "Enter a venue code",
                        systemImage: "person.badge.plus"
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 28)
        }
        .background(ClickColors.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("My QR", systemImage: "qrcode") {
                        env.router.addClickPath.append(.myQR)
                    }
                    Button("Scan QR", systemImage: "viewfinder") {
                        env.router.addClickPath.append(.scanQR)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 36, height: 36)
                        .background(.regularMaterial)
                        .clipShape(Circle())
                }
            }
        }
        .navigationDestination(for: AppRoute.self) { route in
            switch route {
            case .myQR:
                MyClickCodeView()
            case .scanQR:
                ScanClickCodeView()
            case .tapConnect:
                TapConnectCapabilityView()
            case .connectionInvocation(let invocation):
                ConnectionInvocationView(invocation: invocation)
            default:
                EmptyView()
            }
        }
    }

    private func addClickRow(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            ClickHaptics.selection()
            action()
        } label: {
            addClickRowContent(title: title, subtitle: subtitle, systemImage: systemImage, trailing: "chevron.right")
        }
        .buttonStyle(.plain)
    }

    private func addClickUnavailableRow(
        title: String,
        subtitle: String,
        systemImage: String
    ) -> some View {
        addClickRowContent(title: title, subtitle: subtitle, systemImage: systemImage, trailing: nil)
            .opacity(0.72)
            .accessibilityHint("Not yet available in the native rebuild")
    }

    private func addClickRowContent(
        title: String,
        subtitle: String,
        systemImage: String,
        trailing: String?
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(ClickColors.textSecondary)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ClickTypography.titleMedium)
                    .foregroundStyle(ClickColors.textPrimary)
                Text(subtitle)
                    .font(ClickTypography.bodySmall)
                    .foregroundStyle(ClickColors.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if let trailing {
                Image(systemName: trailing)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ClickColors.textSecondary)
            }
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

}

private struct MyClickCodeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var qrPayload: String?
    @State private var expiresAt: Date?
    @State private var errorMessage: String?
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 20)

            VStack(spacing: 7) {
                Text("My Code")
                    .font(ClickTypography.headlineMedium)
                Text("Keep this screen open while the other person scans.")
                    .font(ClickTypography.bodySmall)
                    .foregroundStyle(ClickColors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.white)
                    .frame(width: 278, height: 278)

                if let qrPayload, let image = QRImageRenderer.image(for: qrPayload) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 238, height: 238)
                } else {
                    ProgressView()
                        .tint(ClickColors.primary)
                }
            }
            .shadow(color: .black.opacity(0.08), radius: 18, y: 8)

            if let expiresAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(countdown(to: expiresAt, now: context.date))
                        .font(ClickTypography.captionSmall)
                        .foregroundStyle(ClickColors.textSecondary)
                        .monospacedDigit()
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(ClickTypography.captionSmall)
                    .foregroundStyle(ClickColors.error)
                    .multilineTextAlignment(.center)
            }

            if let qrPayload {
                ShareLink(item: qrPayload) {
                    Label("Share QR Code", systemImage: "square.and.arrow.up")
                        .font(ClickTypography.labelLarge)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(ClickColors.primary)
            }

            Spacer()
        }
        .padding(.horizontal, 22)
        .background(ClickColors.background.ignoresSafeArea())
        .navigationTitle("My Code")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task {
            await refreshCode()
            startRefreshLoop()
        }
        .onDisappear {
            refreshTask?.cancel()
        }
    }

    @MainActor
    private func refreshCode() async {
        do {
            let request = APIRequest(path: "/api/qr", method: .get, requiresAuth: true)
            let (data, _) = try await env.api.executeRaw(request)
            guard
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let payload = root["data"] as? [String: Any],
                let value = payload["qrPayload"] as? String,
                !value.isEmpty
            else {
                throw APIError.decoding
            }

            qrPayload = value
            if let raw = payload["expiresAt"] as? NSNumber {
                expiresAt = Date(timeIntervalSince1970: raw.doubleValue / 1000.0)
            } else {
                expiresAt = Date().addingTimeInterval(90)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(75))
                guard !Task.isCancelled else { return }
                await refreshCode()
            }
        }
    }

    private func countdown(to expiry: Date, now: Date) -> String {
        let seconds = max(0, Int(expiry.timeIntervalSince(now)))
        return "Scan to connect · \(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

private enum QRImageRenderer {
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

private struct ScanClickCodeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var permission: PermissionStatus = .notDetermined
    @State private var scannedValue: String?
    @State private var isProcessing = false
    @State private var statusText: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if permission == .authorized {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    ClickDataScannerView { value in
                        guard scannedValue == nil, !isProcessing else { return }
                        scannedValue = value
                        isProcessing = true
                        Task { await handleScan(value) }
                    }
                    .ignoresSafeArea()
                } else {
                    scannerUnavailable
                }
            } else if permission == .denied || permission == .restricted {
                scannerDenied
            } else {
                ProgressView().tint(.white)
            }

            VStack {
                Spacer()
                VStack(spacing: 8) {
                    Text(isProcessing ? "Connecting…" : "Scan a Click code")
                        .font(ClickTypography.titleMedium)
                        .foregroundStyle(.white)
                    if let statusText {
                        Text(statusText)
                            .font(ClickTypography.captionSmall)
                            .foregroundStyle(.white.opacity(0.82))
                            .multilineTextAlignment(.center)
                    } else {
                        Text("Keep the code inside the frame.")
                            .font(ClickTypography.captionSmall)
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(.black.opacity(0.58))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.bottom, 30)
            }
        }
        .navigationTitle("Scan Code")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task {
            let current = env.permissions.status(for: .camera)
            permission = current == .notDetermined
                ? await env.permissions.requestPermission(for: .camera)
                : current
        }
    }

    private var scannerUnavailable: some View {
        ContentUnavailableView(
            "Camera scanner unavailable",
            systemImage: "viewfinder.circle",
            description: Text("QR scanning requires a supported physical iPhone camera.")
        )
        .foregroundStyle(.white)
    }

    private var scannerDenied: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.system(size: 36))
            Text("Camera access is required to scan Click codes.")
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                env.permissions.openSystemSettings()
            }
            .buttonStyle(.borderedProminent)
            .tint(ClickColors.primary)
        }
        .foregroundStyle(.white)
        .padding(30)
    }

    @MainActor
    private func handleScan(_ raw: String) async {
        guard let invocation = parseInvocation(raw) else {
            statusText = "That isn't a Click connection code."
            scannedValue = nil
            isProcessing = false
            return
        }

        do {
            let result = try await ClickConnectionRedeemer.redeem(invocation, environment: env)
            statusText = "Connected with \(result.name)"
            ClickHaptics.notification(.success)
            try? await Task.sleep(for: .milliseconds(500))
            env.router.selectedTab = .connections
            env.router.addClickPath.removeAll()
            env.router.connectionsPath.removeAll()
        } catch {
            statusText = error.localizedDescription
            ClickHaptics.notification(.error)
            scannedValue = nil
            isProcessing = false
        }
    }

    private func parseInvocation(_ raw: String) -> ConnectionInvocation? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: clean),
           let route = env.router.parseIncomingURL(url),
           case .connectionInvocation(let invocation) = route {
            return invocation
        }

        guard
            let data = clean.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let userID = json["userId"] as? String
        else {
            return nil
        }

        let token = json["token"] as? String
        let expiry = (json["exp"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue > 10_000_000_000 ? $0.doubleValue / 1000 : $0.doubleValue)
        }
        return ConnectionInvocation(userID: userID, token: token, expiresAt: expiry)
    }


}

private enum ClickConnectionRedeemer {
    @MainActor
    static func redeem(
        _ invocation: ConnectionInvocation,
        environment env: AppEnvironment
    ) async throws -> (name: String, connectionID: String?) {
        guard let currentUserID = env.session.currentSession?.userId else {
            throw APIError.unauthorized
        }

        var redeemBody: [String: Any] = [:]
        if let token = invocation.token, !token.isEmpty {
            redeemBody["token"] = token
        } else {
            redeemBody["targetUserId"] = invocation.userID
        }

        let redeemData = try JSONSerialization.data(withJSONObject: redeemBody)
        let request = APIRequest(path: "/api/qr", method: .post, body: redeemData, requiresAuth: true)
        let (data, _) = try await env.api.executeRaw(request)
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = root["data"] as? [String: Any],
            let targetUserID = result["targetUserId"] as? String
        else {
            throw APIError.decoding
        }

        let targetName = (result["targetUserName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingConnectionID = result["connectionId"] as? String

        if existingConnectionID == nil {
            var createBody: [String: Any] = [
                "userId1": currentUserID,
                "userId2": targetUserID,
                "connectionMethod": "qr"
            ]
            if let tokenAgeMs = result["tokenAgeMs"] as? NSNumber {
                createBody["tokenAgeMs"] = tokenAgeMs.doubleValue
            }

            let body = try JSONSerialization.data(withJSONObject: createBody)
            let createRequest = APIRequest(
                path: "/api/connections",
                method: .post,
                body: body,
                requiresAuth: true
            )
            let (created, _) = try await env.api.executeRaw(createRequest)
            let createdRoot = try JSONSerialization.jsonObject(with: created) as? [String: Any]
            let connection = createdRoot?["connection"] as? [String: Any]
            return (
                targetName?.isEmpty == false ? targetName! : "Click user",
                connection?["id"] as? String
            )
        }

        return (
            targetName?.isEmpty == false ? targetName! : "Click user",
            existingConnectionID
        )
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

private struct TapConnectCapabilityView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var microphone: PermissionStatus = .notDetermined
    @State private var location: PermissionStatus = .notDetermined

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(ClickColors.primary.opacity(0.14))
                    .frame(width: 144, height: 144)
                Circle()
                    .fill(ClickColors.primary.opacity(0.22))
                    .frame(width: 104, height: 104)
                Image(systemName: "bolt.horizontal.fill")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(ClickColors.primary)
            }

            VStack(spacing: 7) {
                Text("Ready to Connect")
                    .font(ClickTypography.headlineMedium)
                Text("Tap to Connect verifies that both people are physically together before creating the Click.")
                    .font(ClickTypography.bodySmall)
                    .foregroundStyle(ClickColors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if microphone != .authorized || location != .authorized {
                Button("Enable required access") {
                    Task {
                        microphone = await env.permissions.requestPermission(for: .microphone)
                        location = await env.permissions.requestPermission(for: .locationWhenInUse)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(ClickColors.primary)
            }

            Text("The existing tri-factor BLE/ultrasonic handshake engine is not yet ported to the native target. QR connection is fully functional in this build.")
                .font(ClickTypography.captionSmall)
                .foregroundStyle(ClickColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            Spacer()
        }
        .padding(24)
        .background(ClickColors.background.ignoresSafeArea())
        .navigationTitle("Tap to Connect")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task {
            microphone = env.permissions.status(for: .microphone)
            location = env.permissions.status(for: .locationWhenInUse)
        }
    }
}

private struct ConnectionInvocationView: View {
    @Environment(AppEnvironment.self) private var env
    let invocation: ConnectionInvocation

    @State private var status = "Preparing connection…"
    @State private var completed = false
    @State private var didRun = false

    var body: some View {
        VStack(spacing: 16) {
            if completed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(ClickColors.statusOnline)
            } else {
                ProgressView().tint(ClickColors.primary)
            }

            Text(status)
                .font(ClickTypography.bodyMedium)
                .foregroundStyle(completed ? ClickColors.textPrimary : ClickColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ClickColors.background.ignoresSafeArea())
        .navigationTitle("Add Click")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task {
            guard !didRun else { return }
            didRun = true

            do {
                let result = try await ClickConnectionRedeemer.redeem(invocation, environment: env)
                status = "Connected with \(result.name)"
                completed = true
                ClickHaptics.success()
                try? await Task.sleep(for: .milliseconds(650))
                env.router.selectedTab = .connections
                env.router.addClickPath.removeAll()
                env.router.connectionsPath.removeAll()
            } catch {
                status = error.localizedDescription
                completed = false
                ClickHaptics.error()
            }
        }
    }
}
