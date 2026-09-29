import CoreLocation
import SwiftUI

/// "Is it still there?" on an alert beacon (spec F4). People nearby keep the map accurate: "Still
/// here" keeps it up, "Cleared" takes it down once enough people agree; the creator can take it
/// down anytime. No counts — only when someone last saw it.
struct AlertConfirmationSection: View {
    @Environment(AppEnvironment.self) private var env

    let beacon: MapBeacon
    /// The server cleared or ended it: the detail screen shows it as ended.
    let onEnded: () -> Void

    @State private var state = ModuleState<AlertConfirmationState>()
    @State private var pending: AlertVote?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Is it still there?")
                .font(ClickTypography.sectionTitle)
                .foregroundStyle(ClickColors.textPrimary)

            if let current = state.value {
                if current.phase == .active {
                    buttons(current)
                    Text(caption(current))
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textSecondary)
                        .contentTransition(.opacity)
                }
            } else if state.errorMessage != nil {
                Button("Couldn't load. Try again") { Task { await load() } }
                    .font(ClickTypography.supporting)
            } else {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            }

            if let message {
                Text(message)
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
                    .transition(.opacity)
            }
        }
        .task(id: beacon.id) { await load() }
    }

    private func buttons(_ current: AlertConfirmationState) -> some View {
        HStack(spacing: 10) {
            voteButton(.stillHere, title: "Still here", systemImage: "exclamationmark.triangle", current: current)
            voteButton(.cleared, title: current.isCreator ? "Take it down" : "Cleared",
                       systemImage: "checkmark.circle", current: current)
        }
    }

    private func voteButton(_ vote: AlertVote, title: String, systemImage: String, current: AlertConfirmationState) -> some View {
        let chosen = current.myVote == vote
        return Button {
            Task { await cast(vote, current: current) }
        } label: {
            HStack(spacing: 8) {
                if pending == vote { ProgressView().controlSize(.small) } else { Image(systemName: chosen ? "checkmark" : systemImage) }
                Text(title).font(ClickTypography.supportingEmphasized)
            }
            .foregroundStyle(chosen ? ClickColors.accentForeground : ClickColors.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(chosen ? ClickColors.accentForeground.opacity(0.6) : ClickColors.separator, lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        // One vote per window (the creator can still take it down after saying "still here").
        .disabled(pending != nil || (current.myVote != nil && !(current.isCreator && vote == .cleared)))
        .accessibilityHint(vote == .stillHere ? "Keeps this alert on the map." : "Says the alert is gone.")
    }

    private func caption(_ current: AlertConfirmationState) -> String {
        if current.myVote == .stillHere { return "Thanks — you kept this up to date." }
        if current.myVote == .cleared { return "Thanks — it comes down once others agree." }
        if let seen = current.lastStillHereAt {
            return "Last seen \(seen.formatted(.relative(presentation: .named)))."
        }
        return current.isCreator ? "People nearby can confirm it's still there." : "Only people nearby can confirm."
    }

    private func load() async {
        state.begin()
        do {
            let loaded = try await env.beacons.alertState(beaconID: beacon.id)
            state.succeed(loaded)
            if loaded.phase != .active { onEnded() }
        } catch {
            if !error.isCancellation { state.fail(error.userFacingMessage) }
        }
    }

    private func cast(_ vote: AlertVote, current: AlertConfirmationState) async {
        pending = vote
        defer { pending = nil }
        // The creator clears from anywhere; everyone else is checked against the pin, server-side.
        var coordinate: CLLocationCoordinate2D?
        if !(current.isCreator && vote == .cleared) {
            guard env.location.isAuthorized,
                  let fix = await env.location.currentLocation(maximumAge: 120, acceptableAccuracy: 100, timeout: .seconds(6)) else {
                withAnimation(ClickMotion.subtleFade) { message = AlertVoteRejection.needsLocation.errorDescription }
                return
            }
            coordinate = fix.coordinate
        }
        do {
            let expiresAt = try await env.beacons.confirmAlert(beaconID: beacon.id, vote: vote, at: coordinate)
            ClickHaptics.success()
            withAnimation(ClickMotion.subtleFade) { message = nil }
            if let expiresAt, expiresAt <= .now {
                onEnded()
            }
            await load()
        } catch let rejection as AlertVoteRejection {
            withAnimation(ClickMotion.subtleFade) { message = rejection.errorDescription }
            if rejection == .ended { onEnded() }
        } catch {
            if !error.isCancellation { withAnimation(ClickMotion.subtleFade) { message = error.userFacingMessage } }
        }
    }
}
