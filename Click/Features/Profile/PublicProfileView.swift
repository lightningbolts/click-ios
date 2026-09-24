import SwiftUI

/// View-only profile for someone the viewer hasn't Clicked with. There is no Message or Nudge:
/// connections on Click only happen in person, so the screen explains how.
struct PublicProfileView: View {
    @Environment(AppEnvironment.self) private var env
    let userID: String
    @State private var profile = ModuleState<PublicProfile>()

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let value = profile.value {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: value.auraColors.map { Color(hex: $0) }.nonEmpty ?? [ClickColors.selectionTint],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 132, height: 132)
                            .opacity(0.55)
                        AvatarView(imageURL: value.avatarURL, seed: value.userID, initials: value.initials, size: 112)
                    }
                    .padding(.top, 24)
                    Text(value.displayName)
                        .font(ClickTypography.identityTitle)
                        .foregroundStyle(ClickColors.textPrimary)
                    Text("You haven't Clicked yet")
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textTertiary)
                    guidance
                        .padding(.top, 16)
                } else if profile.isPending {
                    ProgressView().padding(.top, 80)
                } else {
                    ContentUnavailableView {
                        Label("Couldn't load this profile", systemImage: "person.crop.circle.badge.exclamationmark")
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                    .padding(.top, 40)
                }
            }
            .padding(.horizontal, ClickSpacing.screenGutter)
        }
        .background(ClickColors.background.ignoresSafeArea())
        .navigationTitle(profile.value?.displayName ?? "Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var guidance: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Connect in person", systemImage: "wave.3.right")
                .font(ClickTypography.bodyEmphasized)
                .foregroundStyle(ClickColors.textPrimary)
            Text("Click connects people who've actually met. When you're together, open Add Click and tap phones, or scan each other's QR code.")
                .font(ClickTypography.supporting)
                .foregroundStyle(ClickColors.textSecondary)
            Button("Open Add Click") { env.router.selectTab(.addClick) }
                .buttonStyle(.clickSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ClickColors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func load() async {
        profile.begin()
        do {
            profile.succeed(try await env.profiles.publicProfile(userID: userID))
        } catch {
            profile.fail(error)
        }
    }
}

private extension Array {
    var nonEmpty: Self? { isEmpty ? nil : self }
}
