import SwiftUI

/// Home card for spec F6: shown only when location is already allowed (it never asks), at most
/// one a day. "Say hi" opens your chat with a starter; "Not now" can also mute the person or place.
struct ReconnectNearbyCard: View {
    @Environment(AppEnvironment.self) private var env
    let nudge: ReconnectNearbyNudge
    /// The card was dismissed or acted on (Home removes it).
    let onDone: () -> Void

    var body: some View {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        AvatarView(imageURL: nudge.avatarURL, seed: nudge.userID,
                                   initials: Phase3Repository.initials(from: nudge.name), size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(nudge.title).font(ClickTypography.bodyEmphasized).foregroundStyle(ClickColors.textPrimary)
                            Text(nudge.body).font(ClickTypography.supporting).foregroundStyle(ClickColors.textSecondary)
                        }
                        Spacer(minLength: 0)
                        Menu {
                            Button("Not now") { Task { await dismiss(nudge, mute: nil) } }
                            Button("Don't remind me about \(nudge.firstName)") { Task { await dismiss(nudge, mute: .person) } }
                            Button("Not at this place") { Task { await dismiss(nudge, mute: .place) } }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 32, height: 32)
                        }
                        .foregroundStyle(ClickColors.textTertiary)
                        .accessibilityLabel("Dismiss options")
                    }
                    Button {
                        Task { await sayHi(nudge) }
                    } label: {
                        Label("Say hi", systemImage: "hand.wave")
                            .font(ClickTypography.button)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ClickColors.primaryActionFill)
                }
                .padding(14)
                .background(ClickColors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .transition(.opacity)
    }

    /// Home's load: only when location is already allowed (it never asks), at most one a day.
    static func load(_ env: AppEnvironment) async -> ReconnectNearbyNudge? {
        guard env.location.isAuthorized,
              let fix = await env.location.currentLocation(maximumAge: 300, acceptableAccuracy: 200, timeout: .seconds(5)) else { return nil }
        return try? await env.relationships.reconnectNearby(at: fix.coordinate)
    }

    private func dismiss(_ nudge: ReconnectNearbyNudge, mute: ReconnectNearbyMute?) async {
        withAnimation(ClickMotion.subtleFade) { onDone() }
        try? await env.relationships.resolveReconnectNearby(id: nudge.id, acted: false, mute: mute)
    }

    /// Opens the chat with an easy starter already in the composer (never sent for them).
    private func sayHi(_ nudge: ReconnectNearbyNudge) async {
        ClickHaptics.selection()
        let route = DirectChatRoute(connectionID: nudge.connectionID, peerUserID: nudge.userID,
                                    peerDisplayName: nudge.name, peerAvatarURL: nudge.avatarURL)
        let model = env.conversationModel(for: route.conversationIdentity)
        if model.composerText.isEmpty {
            model.composerText = starter(nudge)
        }
        env.router.navigate(to: .chat(route))
        withAnimation(ClickMotion.subtleFade) { onDone() }
        try? await env.relationships.resolveReconnectNearby(id: nudge.id, acted: true)
    }

    private func starter(_ nudge: ReconnectNearbyNudge) -> String {
        if let met = nudge.metAt {
            return "Hey \(nudge.firstName)! I'm back near where we met in \(met.formatted(.dateTime.month(.wide))). How've you been?"
        }
        return "Hey \(nudge.firstName)! I'm back near where we met. How've you been?"
    }
}
