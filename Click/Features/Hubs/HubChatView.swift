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
                ClickLoadingView("Opening \(fallbackTitle ?? "hub")…")
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
                ChatView(model: model, hub: hub, hubMenu: AnyView(hubMenuItems(hub)), onOpenHubInfo: { showingInfo = true })
                    .sheet(isPresented: $showingInfo) {
                        HubInfoView(hub: hub) { Task { await reload() } }
                    }
                    .confirmation("Leave \(hub.name)?", isPresented: $confirmLeave, keep: "Stay in Hub") {
                        Button("Leave Hub", role: .destructive) { Task { await leave(hub) } }
                    }
                    .confirmation("Delete \(hub.name)?", isPresented: $confirmDelete, keep: "Keep Hub",
                                  message: "Everyone loses access to this hub and its chat.") {
                        Button("Delete Hub", role: .destructive) { Task { await delete(hub) } }
                    }
                    .alert("Rename hub", isPresented: $renaming) {
                        TextField("Name", text: $draftName)
                        Button("Cancel", role: .cancel) {}
                        PreferredButton("Save") { Task { await rename(hub) } }
                    }
            }
        }
        .alert("Hub", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
        // Known hubs paint on the first frame (before the push animates), not after a spinner.
        .onAppear { showKnownHub() }
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

    private static var hubCache: [String: HubInfo] = [:]

    /// Remembers a hub in memory and on disk, so its chat opens without a spinner.
    private static func remember(_ hub: HubInfo, env: AppEnvironment) {
        hubCache[hub.id] = hub
        if let userID = env.session.currentSession?.userId {
            LocalStore.shared.save(hub, key: "hub.info.\(hub.id)", userID: userID)
        }
    }

    /// Fetches a hub ahead of opening it (the event page does this for its chat).
    static func prefetch(hubID: String, env: AppEnvironment) async {
        guard hubCache[hubID] == nil, let hub = try? await env.hubs.hub(id: hubID) else { return }
        remember(hub, env: env)
    }

    private func conversationModel(for hub: HubInfo) -> ConversationModel {
        env.conversationModel(for: ConversationIdentity(chatID: hub.id, peerUserID: "", peerDisplayName: hub.name, kind: .hub(hubID: hub.id)))
    }

    private func showKnownHub() {
        guard case .loading = phase, let known = knownHub() else { return }
        phase = .ready(known, conversationModel(for: known))
    }

    private func reload() async {
        Self.hubCache.removeValue(forKey: hubID)
        phase = .loading
        await load()
    }

    /// Hub info from memory, else from disk (so the chat opens straight away after relaunch;
    /// the server still re-checks access right after).
    private func knownHub() -> HubInfo? {
        if let cached = Self.hubCache[hubID] { return cached }
        guard let userID = env.session.currentSession?.userId,
              let stored = LocalStore.shared.load(HubInfo.self, key: "hub.info.\(hubID)", userID: userID)?.value else { return nil }
        Self.hubCache[hubID] = stored
        return stored
    }

    private func load() async {
        showKnownHub()
        do {
            let hub = try await resolveHub()
            Self.remember(hub, env: env)
            if case .ready(let currentHub, _) = phase, currentHub == hub {
                // Already displaying this hub info
            } else {
                withAnimation(ClickMotion.content) { phase = .ready(hub, conversationModel(for: hub)) }
            }
            await conversations.rememberHub(JoinedHub(
                hubID: hub.id, name: hub.name, category: hub.category, eventBeaconID: hub.eventBeaconID, joinedAt: .now,
                creatorID: hub.creatorID
            ))
        } catch {
            if let hubError = error as? HubChatError, hubError == .ended || hubError == .accessDenied {
                Self.hubCache.removeValue(forKey: hubID)
                if let userID = env.session.currentSession?.userId {
                    LocalStore.shared.remove(key: "hub.info.\(hubID)", userID: userID)
                }
                await conversations.forgetHub(id: hubID)
                phase = .failed(message(for: error), canRetry: false)
            } else if case .ready = phase {
                // Retain cached HubInfo if background network error occurs
            } else {
                phase = .failed(message(for: error), canRetry: error as? HubChatError != .ended)
            }
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
            Self.hubCache.removeValue(forKey: hub.id)
            try await conversations.leaveHub(id: hub.id)
            dismiss()
        } catch {
            notice = "Couldn't leave the hub. \(error.userFacingMessage)"
        }
    }

    private func delete(_ hub: HubInfo) async {
        do {
            Self.hubCache.removeValue(forKey: hub.id)
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

    /// Resolutions this session (the server re-checks on every open), so the chat paints at once.
    private static var resolved: [String: EventChatResolution] = [:]

    /// Resolves the event's chat (and fetches its hub) while the event page is open, so opening
    /// the chat pushes straight into it.
    static func prefetch(beaconID: String, env: AppEnvironment) async {
        let result = await env.hubs.resolveEventChat(beaconID: beaconID)
        guard case .ready(let hubID, _, _) = result else { return }
        resolved[beaconID] = result
        await HubChatView.prefetch(hubID: hubID, env: env)
    }

    private func resolve() async {
        let fresh = await env.hubs.resolveEventChat(beaconID: beaconID)
        if case .ready = fresh { Self.resolved[beaconID] = fresh } else { Self.resolved[beaconID] = nil }
        guard fresh != resolution else { return }
        withAnimation(ClickMotion.content) { resolution = fresh }
    }

    var body: some View {
        Group {
            switch resolution {
            case nil:
                ClickLoadingView("Opening event chat…")
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
        .onAppear { if resolution == nil { resolution = Self.resolved[beaconID] } }
        .task { await resolve() }
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
                    Task { await resolve() }
                }
                .buttonStyle(.borderedProminent)
                .tint(ClickColors.primaryActionFill)
            }
        }
    }
}
