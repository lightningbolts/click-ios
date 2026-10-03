import SwiftUI

/// The optional steps onboarding no longer asks for, offered on Home until done or hidden.
enum HomeSetupStep: String, CaseIterable, Codable {
    case findFriends
    case personality

    /// A step stays offered until it's done (or opened, for Find friends) or the card is hidden.
    /// Unknown inputs (nil) never offer it, so nothing flashes in while data loads.
    static func pending(hidden: Set<HomeSetupStep>, connectionCount: Int?, personalityCount: Int?) -> [HomeSetupStep] {
        allCases.filter { step in
            guard !hidden.contains(step) else { return false }
            switch step {
            case .findFriends: return connectionCount.map { $0 < fewConnections } ?? false
            case .personality: return personalityCount.map { $0 < kPersonalityRequiredTagCount } ?? false
            }
        }
    }

    /// Below this many Clicks, finding friends from contacts is worth a nudge.
    static let fewConnections = 3

    private static func key(_ userID: String) -> String { "home.setup.hidden.\(userID)" }

    static func hidden(for userID: String) -> Set<HomeSetupStep> {
        let raw = UserDefaults.standard.stringArray(forKey: key(userID)) ?? []
        return Set(raw.compactMap(HomeSetupStep.init(rawValue:)))
    }

    static func hide(_ steps: Set<HomeSetupStep>, for userID: String) {
        let all = hidden(for: userID).union(steps)
        UserDefaults.standard.set(all.map(\.rawValue).sorted(), forKey: key(userID))
    }
}

/// "Get started" on Home: Find friends and Personality, each one tap away and dismissible.
struct HomeSetupCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ConversationListModel.self) private var conversations
    /// Nil until read for the signed-in user (the card stays out until then).
    @State private var hidden: Set<HomeSetupStep>?

    private var userID: String? { env.session.currentSession?.userId }

    private var steps: [HomeSetupStep] {
        guard let hidden else { return [] }
        return HomeSetupStep.pending(
            hidden: hidden,
            connectionCount: conversations.snapshot.map { _ in conversations.active.count + conversations.archived.count },
            personalityCount: env.selfData.profile.value?.personality.count
        )
    }

    var body: some View {
        let steps = steps
        Group {
            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        HomeSectionTitle("Get started")
                        Spacer()
                        Button("Hide") { hide(Set(HomeSetupStep.allCases)) }
                            .font(ClickTypography.supporting)
                            .foregroundStyle(ClickColors.textSecondary)
                    }
                    .padding(.horizontal, 4)
                    VStack(spacing: 0) {
                        ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                            if index > 0 { HomeDivider(inset: 68) }
                            row(step)
                        }
                    }
                    .padding(.vertical, 4)
                    .groupedSurface()
                }
                .transition(.opacity)
            }
        }
        .animation(ClickMotion.subtleFade, value: steps)
        .task(id: userID) {
            guard let userID else { return hidden = nil }
            hidden = HomeSetupStep.hidden(for: userID)
            // New accounts have no cached profile yet; the personality step needs it.
            await env.selfData.loadProfile()
        }
    }

    @ViewBuilder
    private func row(_ step: HomeSetupStep) -> some View {
        switch step {
        case .findFriends:
            Button {
                // Opening it is enough: the screen is always reachable from Add Click.
                hide([.findFriends])
                env.router.navigate(to: .findFriends)
            } label: {
                IconTileRow(systemImage: "person.2.fill", tint: ClickColors.primaryActionFill,
                            title: "Find friends on Click",
                            detail: "See who from your contacts is already here.", showsChevron: true)
            }
            .buttonStyle(.plain)
        case .personality:
            Button {
                env.router.navigate(to: .settings(.personality))
            } label: {
                IconTileRow(systemImage: "sparkles", tint: ClickColors.warning,
                            title: "Add your personality",
                            detail: "Five traits that help people you meet get you.", showsChevron: true)
            }
            .buttonStyle(.plain)
        }
    }

    private func hide(_ steps: Set<HomeSetupStep>) {
        guard let userID else { return }
        ClickHaptics.selection()
        HomeSetupStep.hide(steps, for: userID)
        withAnimation(ClickMotion.subtleFade) { hidden = HomeSetupStep.hidden(for: userID) }
    }
}
