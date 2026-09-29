import SwiftUI

/// Who's listening to a soundtrack here right now (spec F5): a count, your connections by name,
/// and a toggle to add yourself while you're near the pin. It lapses on its own when you leave.
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
                Text(state.value?.summary ?? "Nobody's listening here right now")
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
            }

            Button {
                Task { await toggle() }
            } label: {
                HStack(spacing: 8) {
                    if toggling { ProgressView().controlSize(.small) } else {
                        Image(systemName: state.value?.isListening == true ? "headphones.circle.fill" : "headphones")
                    }
                    Text(state.value?.isListening == true ? "Listening here" : "I'm listening here")
                        .font(ClickTypography.supportingEmphasized)
                }
                .foregroundStyle(state.value?.isListening == true ? ClickColors.accentForeground : ClickColors.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 48)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(state.value?.isListening == true ? ClickColors.accentForeground.opacity(0.6) : ClickColors.separator,
                                      lineWidth: 1.5)
                }
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(toggling || state.value == nil)
            .accessibilityHint("Adds you to the count while you're near this pin.")

            if let message {
                Text(message).font(ClickTypography.supporting).foregroundStyle(ClickColors.textSecondary)
            }
        }
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

    private var heartbeatKey: String {
        "\(state.value?.isListening == true)-\(scenePhase == .active)"
    }

    private func load() async {
        state.begin()
        do {
            state.succeed(try await env.beacons.listening(beaconID: beacon.id))
        } catch {
            if !error.isCancellation { state.fail(error.userFacingMessage) }
        }
    }

    private func toggle() async {
        toggling = true
        defer { toggling = false }
        if state.value?.isListening == true {
            do {
                state.succeed(try await env.beacons.stopListening(beaconID: beacon.id))
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
        guard env.location.isAuthorized,
              let fix = await env.location.currentLocation(maximumAge: 120, acceptableAccuracy: 100, timeout: .seconds(6)) else {
            message = "Your location is needed to listen here."
            return
        }
        do {
            state.succeed(try await env.beacons.heartbeat(beaconID: beacon.id, at: fix.coordinate))
            message = nil
        } catch {
            if !error.isCancellation {
                message = (error as? ListeningOutOfRange)?.errorDescription ?? error.userFacingMessage
                // Out of range while listening: the server keeps the old heartbeat until it lapses.
            }
        }
    }
}
