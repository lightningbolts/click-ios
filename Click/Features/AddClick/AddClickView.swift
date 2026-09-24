import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import VisionKit

/// The Add Click root: Tap to Connect is the signature action; My QR and Scan stay one tap
/// away (prototype "interaction-first" hierarchy). Only working capabilities are shown.
public struct AddClickView: View {
    @Environment(AppEnvironment.self) private var env

    private enum Sheet: String, Identifiable {
        case newGroup, createHub, joinHub, howItWorks
        var id: String { rawValue }
    }

    @State private var sheet: Sheet?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                tapHero

                HStack(spacing: 0) {
                    quickAction("My QR", systemImage: "qrcode") { env.router.navigate(to: .myQR) }
                    quickAction("Scan", systemImage: "qrcode.viewfinder") { env.router.navigate(to: .scanQR) }
                    quickAction("Group", systemImage: "person.2") { sheet = .newGroup }
                    quickAction("Join hub", systemImage: "house") { sheet = .joinHub }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HomeSectionTitle("Community")
                        .padding(.horizontal, 4)
                    VStack(spacing: 0) {
                        communityRow("Create Community Hub", subtitle: "Host a venue for nearby Clicks", systemImage: "house") {
                            sheet = .createHub
                        }
                        Divider().padding(.leading, 56)
                        communityRow("Join Community Hub", subtitle: "Enter a venue code", systemImage: "plus.circle") {
                            sheet = .joinHub
                        }
                        Divider().padding(.leading, 56)
                        communityRow("How Tap to Connect works", subtitle: nil, systemImage: "waveform") {
                            sheet = .howItWorks
                        }
                    }
                    .groupedSurface()
                }
            }
            .padding(.horizontal, ClickSpacing.screenGutter)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .background(ClickColors.background.ignoresSafeArea())
        .navigationTitle("Add Click")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                RootMenu()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    env.router.navigate(to: .scanQR)
                } label: {
                    Label("Scan QR", systemImage: "qrcode.viewfinder")
                }
            }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .newGroup: NewGroupSheet()
            case .createHub: CreateHubSheet()
            case .joinHub: JoinHubSheet()
            case .howItWorks: howItWorks
            }
        }
    }

    private func communityRow(_ title: String, subtitle: String?, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 20))
                    .foregroundStyle(ClickColors.textPrimary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(ClickTypography.body).foregroundStyle(ClickColors.textPrimary)
                    if let subtitle {
                        Text(subtitle).font(ClickTypography.supporting).foregroundStyle(ClickColors.textSecondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ClickColors.textTertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: ClickMetrics.rowMinHeight)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var howItWorks: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                explainer("dot.radiowaves.left.and.right", "Bluetooth finds the other phone nearby.")
                explainer("waveform", "A short inaudible tone confirms you're in the same room.")
                explainer("location", "Location helps only when Location snap is on.")
                explainer("checkmark.shield", "Click's server confirms the match before anyone is connected.")
                Spacer()
            }
            .padding(24)
            .navigationTitle("How Tap to Connect works")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    private var tapHero: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(ClickColors.primaryActionFill.opacity(0.14))
                    .frame(width: 120, height: 120)
                Circle()
                    .fill(ClickColors.primaryActionFill)
                    .frame(width: 88, height: 88)
                Image(systemName: "wave.3.right")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(ClickColors.primaryActionForeground)
            }
            .accessibilityHidden(true)
            Text("Tap to Connect")
                .font(ClickTypography.identityTitle)
                .foregroundStyle(ClickColors.textPrimary)
                .padding(.top, 16)
            Text("Hold phones together. Bluetooth, a short inaudible tone, and location confirm you're really there.")
                .font(ClickTypography.supporting)
                .foregroundStyle(ClickColors.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            Button("Start") {
                ClickHaptics.impact(.medium)
                env.router.navigate(to: .tapConnect)
            }
            .buttonStyle(.clickPrimary)
        }
        .padding(.horizontal, 22)
        .padding(.top, 30)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity)
        .background(ClickColors.surface, in: RoundedRectangle(cornerRadius: ClickRadius.prominent, style: .continuous))
    }

    private func quickAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            ClickHaptics.selection()
            action()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(ClickColors.textPrimary)
                    .frame(width: ClickMetrics.quickActionSize, height: ClickMetrics.quickActionSize)
                    .background(ClickColors.surface, in: Circle())
                Text(title)
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textTertiary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func explainer(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(ClickColors.accentForeground)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text)
                .font(ClickTypography.supporting)
                .foregroundStyle(ClickColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// My QR (spec §22.2): a 90-second single-use token from `GET /api/qr`. The code is refreshed
/// before it expires and is hidden the moment it expires, so a stale code is never shown.
struct MyClickCodeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var qrPayload: String?
    @State private var expiresAt: Date?
    @State private var errorMessage: String?
    @State private var refreshTask: Task<Void, Never>?
    @State private var identity: SelfProfile?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                AvatarView(
                    imageURL: identity?.avatarURL,
                    seed: env.session.currentSession?.userId ?? "",
                    initials: identity?.initials ?? "",
                    size: 56
                )
                .padding(.top, 12)
                Text(identity?.displayName ?? " ")
                    .font(ClickTypography.sectionTitle)
                    .foregroundStyle(ClickColors.textPrimary)
                    .padding(.top, 10)
                Text("Keep this screen open while the other person scans.")
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textTertiary)
                    .multilineTextAlignment(.center)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = expiresAt.map { max(0, Int($0.timeIntervalSince(context.date))) } ?? 0
                    VStack(spacing: 18) {
                        codeCard(showsCode: remaining > 0)
                        Text(remaining > 0 ? "Refreshes in \(remaining / 60):\(String(format: "%02d", remaining % 60))" : "Getting a new code…")
                            .font(ClickTypography.supportingEmphasized)
                            .foregroundStyle(ClickColors.textPrimary)
                            .monospacedDigit()
                            .accessibilityLabel(remaining > 0 ? "Code refreshes in \(remaining) seconds" : "Getting a new code")
                    }
                }
                .padding(.top, 22)

                if let errorMessage {
                    Text(errorMessage)
                        .font(ClickTypography.metadata)
                        .foregroundStyle(ClickColors.destructive)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }

                Text("Single-use code. It changes every 90 seconds so screenshots can't be reused.")
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                    .padding(.horizontal, 20)

                HStack(spacing: 10) {
                    Button("Scan instead") { env.router.navigate(to: .scanQR) }
                        .buttonStyle(.clickSecondary)
                    if let qrPayload, let url = URL(string: qrPayload) {
                        ShareLink(item: url) { Text("Share") }
                            .buttonStyle(.clickPrimary)
                    } else {
                        Button("Share") {}
                            .buttonStyle(.clickPrimary)
                            .disabled(true)
                    }
                }
                .padding(.top, 24)
            }
            .padding(.horizontal, 28)
        }
        .background(ClickColors.background.ignoresSafeArea())
        .navigationTitle("My QR")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task {
            if let userID = env.session.currentSession?.userId {
                identity = await env.me.cachedSelfProfile(userID: userID)
            }
            startRefreshLoop()
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            refreshTask?.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, (expiresAt ?? .distantPast) <= .now { startRefreshLoop() }
        }
    }

    private func codeCard(showsCode: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: ClickRadius.prominent, style: .continuous)
                .fill(.white)
                .frame(width: 272, height: 272)
            if showsCode, let qrPayload, let image = QRImageRenderer.image(for: qrPayload) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 236, height: 236)
                    .accessibilityLabel("Your Click QR code")
            } else {
                ProgressView().tint(.black)
            }
        }
    }

    /// Fetches a code, then sleeps until shortly before it expires; failures retry quickly.
    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                let succeeded = await refreshCode()
                let wait = succeeded
                    ? max(5, (expiresAt ?? .now).timeIntervalSinceNow - 10)
                    : 5
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private func refreshCode() async -> Bool {
        do {
            let (data, _) = try await env.api.executeRaw(APIRequest(path: "/api/qr", method: .get))
            guard
                let payload = JSONFields.dictionary(try JSONFields.object(data)["data"]),
                let value = JSONFields.string(payload["qrPayload"])
            else { throw APIError.decoding }
            qrPayload = value
            expiresAt = JSONFields.date(payload["expiresAt"]) ?? Date().addingTimeInterval(90)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Couldn't get a fresh code. \(error.userFacingMessage)"
            return false
        }
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

struct ScanClickCodeView: View {
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
                        .font(ClickTypography.bodyEmphasized)
                        .foregroundStyle(.white)
                    if let statusText {
                        Text(statusText)
                            .font(ClickTypography.metadata)
                            .foregroundStyle(.white.opacity(0.82))
                            .multilineTextAlignment(.center)
                    } else {
                        Text("Keep the code inside the frame.")
                            .font(ClickTypography.metadata)
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(.black.opacity(0.58))
                .clipShape(RoundedRectangle(cornerRadius: ClickRadius.surface, style: .continuous))
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
            .buttonStyle(.clickPrimary)
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

struct ConnectionInvocationView: View {
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
                    .foregroundStyle(ClickColors.online)
            } else {
                ProgressView().tint(ClickColors.accentForeground)
            }

            Text(status)
                .font(ClickTypography.body)
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
