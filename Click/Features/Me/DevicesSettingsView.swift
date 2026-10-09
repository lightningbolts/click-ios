import SwiftUI

/// Devices (spec §7.8): the devices holding their own key to this account's chats, with "This
/// device", removal, and new sign-ins waiting for your chat history, decided here the same way as
/// the approval prompt (Face ID or the passcode, and this device proving it holds its key).
///
/// Removing a device here is about chats, not sign-in: the server stops sharing chat keys with
/// it, and it stays signed in until it signs out.
struct DevicesSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var devices = ModuleState<[ChatRepository.ChatDevice]>()
    @State private var incoming: [ChatRepository.DeviceApproval] = []
    @State private var thisDevice: String?
    @State private var reviewing: ChatRepository.DeviceApproval?
    @State private var removing: ChatRepository.ChatDevice?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if !incoming.isEmpty { requests }
            if let list = devices.value {
                deviceList(list)
            } else if devices.isPending {
                ClickLoadingView(size: 26, fillsSpace: false)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } else {
                ContentUnavailableView {
                    Label(env.network.isOnline ? "Couldn't load your devices" : "You're offline", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(env.network.isOnline ? "Check your connection and try again." : "Your devices show up here once you're back online.")
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: env.network.isOnline) { _, online in
            if online, devices.value == nil { Task { await load() } }
        }
        .sheet(item: $reviewing, onDismiss: { Task { await load() } }) { approval in
            DeviceApprovalSheet(approval: approval) { _ in
                incoming.removeAll { $0.id == approval.id }
            }
        }
        .confirmation(removing.map { "Remove \($0.label ?? "this device")?" } ?? "",
                      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                      keep: "Keep Device",
                      message: "It stops getting new messages until it's approved again. It stays signed in until it signs out.") {
            Button("Remove", role: .destructive) { if let device = removing { Task { await remove(device) } } }
        }
    }

    // MARK: - Sections

    private var requests: some View {
        Section {
            ForEach(incoming) { approval in
                Button { review(approval) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "questionmark.shield")
                            .foregroundStyle(ClickColors.accentForeground)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(DeviceApprovalSheet.withArticle(approval.deviceLabel)) wants your chat history")
                                .font(ClickTypography.body)
                                .foregroundStyle(ClickColors.textPrimary)
                            Text(signedIn(approval))
                                .font(ClickTypography.metadata)
                                .foregroundStyle(ClickColors.textTertiary)
                        }
                        Spacer(minLength: 0)
                        Text("Review")
                            .font(ClickTypography.supportingEmphasized)
                            .foregroundStyle(ClickColors.accentForeground)
                    }
                }
                .disabled(!env.network.isOnline)
                .accessibilityHint("Approve or decline sharing your chat history with it.")
            }
        } header: {
            Text("Waiting for approval")
        } footer: {
            Text("Only approve a sign-in if it's you.")
        }
    }

    private func deviceList(_ list: [ChatRepository.ChatDevice]) -> some View {
        Section {
            if list.isEmpty {
                ContentUnavailableView("No chat devices yet", systemImage: "laptopcomputer.and.iphone",
                                       description: Text("Devices show up here once you open a chat on them."))
                    .listRowBackground(Color.clear)
            }
            ForEach(ordered(list)) { device in
                row(device)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let errorMessage { Text(errorMessage).foregroundStyle(ClickColors.destructive) }
                if !env.network.isOnline { Text("You're offline. Changes wait until you're back.") }
                Text("Messages are end-to-end encrypted, and each device holds its own key. Removing a device stops it reading new messages; it doesn't sign it out.")
            }
        }
    }

    private func row(_ device: ChatRepository.ChatDevice) -> some View {
        let mine = device.id == thisDevice
        let name = device.label ?? (mine ? UIDevice.current.model : "Unnamed device")
        // Accessibility text sizes stack the action under the name instead of squeezing it.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 14))
        return layout {
            HStack(spacing: 14) {
                Image(systemName: DeviceApprovalSheet.symbol(for: device.label))
                    .foregroundStyle(ClickColors.textSecondary)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(ClickTypography.body).lineLimit(1)
                    Text(activity(device))
                        .font(ClickTypography.metadata)
                        .foregroundStyle(ClickColors.textTertiary)
                }
            }
            Spacer(minLength: 0)
            if mine {
                Text("This device")
                    .font(ClickTypography.badge)
                    .foregroundStyle(ClickColors.accentForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(ClickColors.accentForeground.opacity(0.12), in: Capsule())
            } else {
                Button("Remove", role: .destructive) { removing = device }
                    .buttonStyle(.borderless)
                    .disabled(!env.network.isOnline)
                    .accessibilityLabel("Remove \(name)")
            }
        }
        .swipeActions {
            if !mine {
                Button("Remove", role: .destructive) { removing = device }
                    .disabled(!env.network.isOnline)
            }
        }
    }

    /// This device first, then the rest by last activity (the server's order).
    private func ordered(_ list: [ChatRepository.ChatDevice]) -> [ChatRepository.ChatDevice] {
        list.filter { $0.id == thisDevice } + list.filter { $0.id != thisDevice }
    }

    private func activity(_ device: ChatRepository.ChatDevice) -> String {
        if let seen = device.lastSeenAt { return "Active \(seen.formatted(.relative(presentation: .named)))" }
        if let added = device.createdAt { return "Added \(added.formatted(.relative(presentation: .named)))" }
        return ""
    }

    private func signedIn(_ approval: ChatRepository.DeviceApproval) -> String {
        approval.createdAt.map { "Signed in \($0.formatted(.relative(presentation: .named)))" } ?? "Signed in recently"
    }

    // MARK: - Actions

    private func load() async {
        devices.begin()
        thisDevice = await env.chat.currentDeviceID
        // Requests are extra: without them, the devices still show.
        async let approvals = try? env.chat.deviceApprovals()
        do {
            devices.succeed(try await env.chat.chatDevices())
            if let decided = await approvals { incoming = decided.incoming }
        } catch {
            if !error.isCancellation { devices.fail(error.userFacingMessage) }
        }
    }

    /// The approval prompt, here instead of on its own: it won't also pop up while this is open.
    private func review(_ approval: ChatRepository.DeviceApproval) {
        env.deferDeviceApproval(approval.id)
        reviewing = approval
    }

    /// Gone from the list at once; back, with the reason, if the server says no.
    private func remove(_ device: ChatRepository.ChatDevice) async {
        guard let list = devices.value else { return }
        errorMessage = nil
        withAnimation(ClickMotion.content) { devices.succeed(list.filter { $0.id != device.id }) }
        do {
            try await env.chat.removeChatDevice(device.id)
            ClickHaptics.success()
        } catch {
            withAnimation(ClickMotion.content) { devices.succeed(list) }
            errorMessage = "Couldn't remove \(device.label ?? "that device"). \(error.userFacingMessage)"
        }
    }
}
