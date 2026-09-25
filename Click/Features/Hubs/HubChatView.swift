import SwiftUI

/// Community/event hub chat (spec §61–62). Resolves the hub and the viewer's access through the
/// server before painting any timeline, so a stale hub conversation never flashes and then
/// disappears. Access failures keep their real reason (not near / RSVP / ended).
struct HubChatView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(ConversationListModel.self) private var conversations

    let hubID: String
    var fallbackTitle: String?

    private enum Phase {
        case loading
        case ready(HubInfo, ConversationModel)
        case failed(String, canRetry: Bool)
    }

    @State private var phase: Phase = .loading
    @State private var confirmLeave = false
    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var draftName = ""
    @State private var notice: String?
    @State private var showingInfo = false

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView("Opening \(fallbackTitle ?? "hub")…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(fallbackTitle ?? "Hub")
                    .navigationBarTitleDisplayMode(.inline)
            case .failed(let message, let canRetry):
                ContentUnavailableView {
                    Label("Can't open this chat", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                } description: {
                    Text(message)
                } actions: {
                    if canRetry {
                        Button("Try Again") { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                            .tint(ClickColors.primaryActionFill)
                    }
                }
                .navigationTitle(fallbackTitle ?? "Hub")
                .navigationBarTitleDisplayMode(.inline)
            case .ready(let hub, let model):
                ChatView(model: model, hubMenu: AnyView(hubMenuItems(hub)), onOpenHubInfo: { showingInfo = true })
                    .sheet(isPresented: $showingInfo) {
                        HubInfoView(hub: hub) { Task { await reload() } }
                    }
                    .confirmationDialog("Leave \(hub.name)?", isPresented: $confirmLeave, titleVisibility: .visible) {
                        Button("Leave Hub", role: .destructive) { Task { await leave(hub) } }
                    }
                    .confirmationDialog("Delete \(hub.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete Hub", role: .destructive) { Task { await delete(hub) } }
                    } message: {
                        Text("Everyone loses access to this hub and its chat.")
                    }
                    .alert("Rename hub", isPresented: $renaming) {
                        TextField("Name", text: $draftName)
                        Button("Save") { Task { await rename(hub) } }
                        Button("Cancel", role: .cancel) {}
                    }
            }
        }
        .alert("Hub", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
        .task { await load() }
    }

    /// Hub items inside the chat's one options menu (after Search).
    @ViewBuilder
    private func hubMenuItems(_ hub: HubInfo) -> some View {
        Button("Hub Info", systemImage: "info.circle") { showingInfo = true }
        Section {
            if hub.creatorID == env.session.currentSession?.userId {
                Button("Rename", systemImage: "pencil") {
                    draftName = hub.name
                    renaming = true
                }
                Button("Delete Hub", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } else if !hub.isEventHub {
                // Event hub membership follows the RSVP; the server manages it.
                Button("Leave Hub", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmLeave = true }
            }
        }
    }

    private func reload() async {
        phase = .loading
        await load()
    }

    private func load() async {
        if case .ready = phase { return }
        phase = .loading
        do {
            let hub = try await resolveHub()
            let identity = ConversationIdentity(
                chatID: hub.id,
                peerUserID: "",
                peerDisplayName: hub.name,
                kind: .hub(hubID: hub.id)
            )
            let model = env.conversationModel(for: identity)
            phase = .ready(hub, model)
            await conversations.rememberHub(JoinedHub(
                hubID: hub.id, name: hub.name, category: hub.category, eventBeaconID: hub.eventBeaconID, joinedAt: .now,
                creatorID: hub.creatorID
            ))
        } catch {
            if let hubError = error as? HubChatError, hubError == .ended || hubError == .accessDenied {
                await conversations.forgetHub(id: hubID)
            }
            phase = .failed(message(for: error), canRetry: error as? HubChatError != .ended)
        }
    }

    /// Reads the hub; if the viewer isn't a participant yet, joins with the server's evidence
    /// (event RSVP via click-web, or a fresh location fix for standalone hubs) and reads again.
    private func resolveHub() async throws -> HubInfo {
        do {
            return try await env.hubs.hub(id: hubID)
        } catch APIError.forbidden {
            // click-web's join authorizes event hubs (RSVP/check-in/host) and answers
            // "coordinates required" for standalone hubs, which join through the geofence check.
            do {
                try await env.hubs.join(hubID: hubID, isEventHub: true, coordinates: nil)
            } catch HubChatError.locationRequired {
                let fix = await env.location.currentLocation(maximumAge: 60, acceptableAccuracy: 150, timeout: .seconds(6))
                try await env.hubs.join(
                    hubID: hubID,
                    isEventHub: false,
                    coordinates: fix.map { ($0.coordinate.latitude, $0.coordinate.longitude) }
                )
            }
            return try await env.hubs.hub(id: hubID)
        }
    }

    private func message(for error: Error) -> String {
        if let hubError = error as? HubChatError { return hubError.localizedDescription }
        if case APIError.forbidden = error { return HubChatError.accessDenied.localizedDescription }
        return error.userFacingMessage
    }

    private func leave(_ hub: HubInfo) async {
        do {
            try await conversations.leaveHub(id: hub.id)
            dismiss()
        } catch {
            notice = "Couldn't leave the hub. \(error.userFacingMessage)"
        }
    }

    private func delete(_ hub: HubInfo) async {
        do {
            try await conversations.deleteHub(id: hub.id)
            dismiss()
        } catch {
            notice = "Couldn't delete the hub. \(error.userFacingMessage)"
        }
    }

    private func rename(_ hub: HubInfo) async {
        guard let name = draftName.nonEmptyTrimmed, name != hub.name else { return }
        do {
            try await env.hubs.update(hubID: hub.id, name: name)
            await reload()
        } catch {
            notice = "Couldn't rename the hub. \(error.userFacingMessage)"
        }
    }
}

/// Event chat entry: always resolves the canonical hub through the server (spec §56.2.1).
struct EventChatView: View {
    @Environment(AppEnvironment.self) private var env
    let beaconID: String

    @State private var resolution: EventChatResolution?

    var body: some View {
        Group {
            switch resolution {
            case nil:
                ProgressView("Opening event chat…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready(let hubID, let title, _):
                HubChatView(hubID: hubID, fallbackTitle: title)
            case .requiresRSVP:
                unavailable("RSVP to join the chat", "The event chat opens once you've RSVP'd.", retry: false)
            case .unavailable:
                unavailable("Event chat unavailable", "This event or its chat is no longer available.", retry: false)
            case .notReady:
                unavailable("Chat isn't ready yet", "This event's chat is still being set up.", retry: true)
            case .ended:
                unavailable("Event chat ended", "This event's chat is no longer active.", retry: false)
            case .failed(let message):
                unavailable("Couldn't open event chat", message, retry: true)
            }
        }
        .navigationTitle("Event chat")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if resolution == nil { resolution = await env.hubs.resolveEventChat(beaconID: beaconID) }
        }
    }

    private func unavailable(_ title: String, _ message: String, retry: Bool) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text(message)
        } actions: {
            if retry {
                Button("Try Again") {
                    resolution = nil
                    Task { resolution = await env.hubs.resolveEventChat(beaconID: beaconID) }
                }
                .buttonStyle(.borderedProminent)
                .tint(ClickColors.primaryActionFill)
            }
        }
    }
}
