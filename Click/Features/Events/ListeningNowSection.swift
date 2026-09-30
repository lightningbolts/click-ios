import SwiftUI

/// Who's listening to a soundtrack right now (spec F5): a count, your connections by name, a
/// toggle to add yourself (from anywhere), and reactions. Listening lapses on its own.
struct ListeningNowSection: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase

    let beacon: MapBeacon

    @State private var state = ModuleState<ListeningNow>()
    @State private var toggling = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let people = state.value?.connections.prefix(3), !people.isEmpty {
                    HStack(spacing: -8) {
                        ForEach(Array(people)) { person in
                            AvatarView(imageURL: person.avatarURL, seed: person.id,
                                       initials: Phase3Repository.initials(from: person.name), size: 28)
                                .overlay(Circle().strokeBorder(ClickColors.background, lineWidth: 2))
                        }
                    }
                    .accessibilityHidden(true)
                }
                Text(state.value?.summary ?? "Nobody's listening right now")
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
                    .contentTransition(.opacity)
                Spacer(minLength: 8)
                let listening = state.value?.isListening == true
                Button {
                    Task { await toggle() }
                } label: {
                    HStack(spacing: 6) {
                        if toggling { ProgressView().controlSize(.mini) } else { Image(systemName: listening ? "headphones.circle.fill" : "headphones") }
                        Text(listening ? "Listening" : "Listen")
                    }
                    .font(ClickTypography.supportingEmphasized)
                    .foregroundStyle(listening ? .white : ClickColors.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(listening ? ClickColors.primaryActionFill : ClickColors.fillSubtle, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(toggling || state.value == nil)
                .accessibilityLabel(listening ? "Listening. Double tap to stop." : "Listen")
                .accessibilityHint("Adds you to the count while you listen.")
            }

            ReactionBar(target: .soundtrack, id: beacon.id, isOwner: beacon.creatorID == env.session.currentSession?.userId)

            if let message {
                Text(message).font(ClickTypography.supporting).foregroundStyle(ClickColors.textSecondary)
            }
        }
        .onAppear { state.seed(env.beaconExtras.cached(cacheKey)) }
        .task(id: beacon.id) { await load() }
        // While listening, re-confirm on the server's cadence (only while this screen is open and active).
        .task(id: heartbeatKey) {
            guard let current = state.value, current.isListening, scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(current.heartbeatSeconds))
                guard !Task.isCancelled else { return }
                await beat()
            }
        }
    }

    private var cacheKey: String { BeaconExtrasCache.listening(beacon.id) }

    private func apply(_ value: ListeningNow) {
        state.succeed(value)
        env.beaconExtras.store(value, for: cacheKey)
    }

    private var heartbeatKey: String {
        "\(state.value?.isListening == true)-\(scenePhase == .active)"
    }

    private func load() async {
        state.begin()
        do {
            state.succeed(try await env.beaconExtras.load(cacheKey) { try await env.beacons.listening(beaconID: beacon.id) })
        } catch {
            if !error.isCancellation { state.fail(error.userFacingMessage) }
        }
    }

    private func toggle() async {
        toggling = true
        defer { toggling = false }
        if state.value?.isListening == true {
            do {
                apply(try await env.beacons.stopListening(beaconID: beacon.id))
                message = nil
            } catch {
                if !error.isCancellation { message = error.userFacingMessage }
            }
        } else {
            await beat()
            if state.value?.isListening == true { ClickHaptics.selection() }
        }
    }

    private func beat() async {
        do {
            apply(try await env.beacons.heartbeat(beaconID: beacon.id))
            message = nil
        } catch {
            if !error.isCancellation { message = error.userFacingMessage }
        }
    }
}
