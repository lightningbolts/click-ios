import SwiftUI

/// The moment after a server-confirmed Click (spec §25–§28): avatars join, the peer's name and
/// place, optional context tags, an event suggestion, then Say hi / View profile. Shown for Tap
/// to Connect and QR alike. Cheap by design: no blur or particles; Reduce Motion fades.
struct PostConnectView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State var model: PostConnectModel
    let onSayHi: (ProximityPeer) -> Void
    let onViewProfile: (ProximityPeer) -> Void
    let onOpenGroups: () -> Void
    let onOpenEvent: (String) -> Void
    let onDone: () -> Void

    @State private var joined = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                avatars
                    .padding(.top, 28)
                Text(model.title)
                    .font(ClickTypography.identityTitle)
                    .foregroundStyle(ClickColors.textPrimary)
                    .padding(.top, 18)
                    .accessibilityAddTraits(.isHeader)
                Text(model.subtitle)
                    .font(ClickTypography.body)
                    .foregroundStyle(ClickColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                    .contentTransition(.opacity)
                    .animation(ClickMotion.subtleFade, value: model.subtitle)

                tagging
                    .padding(.top, 28)

                if let recommendation = model.recommendation, !model.recommendationDismissed {
                    recommendationCard(recommendation)
                        .padding(.top, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, ClickSpacing.screenGutter)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) { actions }
        .background(ClickColors.background.ignoresSafeArea())
        .task {
            // The heavy "person detected" haptic already fired; the join lands with success.
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : ClickMotion.reveal) { joined = true }
            await model.load(env)
        }
        .animation(ClickMotion.content, value: model.recommendation)
    }

    // MARK: - Reveal

    private var avatars: some View {
        let peers = Array(model.match.peers.prefix(4))
        let selfID = env.session.currentSession?.userId ?? "me"
        return HStack(spacing: model.isGroup ? -22 : (joined ? -18 : 40)) {
            AvatarView(imageURL: nil, seed: selfID, initials: "You", size: model.isGroup ? 72 : 96)
                .overlay(Circle().stroke(ClickColors.background, lineWidth: 4))
                .offset(x: joined || reduceMotion ? 0 : -30)
            ForEach(peers) { peer in
                AvatarView(imageURL: peer.avatarURL, seed: peer.id, initials: peer.initials, size: model.isGroup ? 72 : 96)
                    .overlay(Circle().stroke(ClickColors.background, lineWidth: 4))
                    .offset(x: joined || reduceMotion ? 0 : 30)
            }
        }
        .opacity(joined ? 1 : 0.4)
        .scaleEffect(joined || reduceMotion ? 1 : 0.9)
        .overlay(alignment: .bottom) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(ClickColors.primaryActionForeground, ClickColors.primaryActionFill)
                .background(Circle().fill(ClickColors.background).padding(2))
                .offset(y: 14)
                .scaleEffect(joined ? 1 : 0.2)
                .opacity(joined ? 1 : 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.title)
    }

    // MARK: - Context tags (§26)

    private var tagging: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.taggingPrompt)
                .font(ClickTypography.sectionTitle)
                .foregroundStyle(ClickColors.textPrimary)
            Text("Optional. Tags go on your shared timeline.")
                .font(ClickTypography.metadata)
                .foregroundStyle(ClickColors.textTertiary)
            ContextTagPicker(selected: $model.selectedTags, custom: $model.customTag, suggestions: model.suggestions)
            switch model.saveState {
            case .saved:
                Label("Saved to your timeline", systemImage: "checkmark")
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.accentForeground)
            case .failed(let message):
                Text(message)
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.destructive)
            case .idle, .saving:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Event recommendation (§27)

    private func recommendationCard(_ recommendation: EventRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Go together?")
                .font(ClickTypography.badge)
                .foregroundStyle(ClickColors.accentForeground)
            Button { onOpenEvent(recommendation.beaconID) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(recommendation.peerName.map { "\($0) is going to \(recommendation.title)" } ?? recommendation.title)
                        .font(ClickTypography.bodyEmphasized)
                        .foregroundStyle(ClickColors.textPrimary)
                        .multilineTextAlignment(.leading)
                    Text([recommendation.startsAt?.formatted(date: .abbreviated, time: .shortened), recommendation.locationName]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(ClickTypography.metadata)
                        .foregroundStyle(ClickColors.textTertiary)
                }
            }
            .buttonStyle(.plain)
            HStack(spacing: 10) {
                Button(model.rsvpPending ? "RSVPing…" : "RSVP") {
                    Task { if await model.rsvp(env) { onOpenEvent(recommendation.beaconID) } }
                }
                .buttonStyle(.borderedProminent)
                .tint(ClickColors.primaryActionFill)
                .disabled(model.rsvpPending)
                Button("Dismiss") { model.dismissRecommendation() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ClickColors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 10) {
            if !model.selectedTags.isEmpty || !model.customTag.trimmingCharacters(in: .whitespaces).isEmpty,
               model.saveState != .saved {
                Button(model.saveState == .saving ? "Saving…" : "Save tags") {
                    Task { await model.save(env) }
                }
                .buttonStyle(.clickSecondary)
                .disabled(model.saveState == .saving)
            }
            if model.isGroup {
                Button("Open Groups") { onOpenGroups() }
                    .buttonStyle(.clickPrimary)
            } else if let peer = model.primaryPeer {
                Button("Say hi") { onSayHi(peer) }
                    .buttonStyle(.clickPrimary)
                Button("View profile") { onViewProfile(peer) }
                    .buttonStyle(.clickSecondary)
            }
            Button("Done", action: onDone)
                .font(ClickTypography.supportingEmphasized)
                .padding(.top, 2)
        }
        .padding(.horizontal, ClickSpacing.screenGutter)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
