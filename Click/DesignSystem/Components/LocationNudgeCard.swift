import SwiftUI

/// A `LocationNudge` as an inline card: what you get, Turn on and Not now side by side. Hides
/// itself when the nudge isn't due, and after either answer.
struct LocationNudgeCard: View {
    @Environment(AppEnvironment.self) private var env
    let nudge: LocationNudge
    let systemImage: String
    let title: String
    let message: String
    var acceptTitle = "Turn on"
    /// Extra condition from the host, e.g. "some encounters have no place".
    var isRelevant = true

    @State private var isDue = false
    @State private var isSaving = false
    @State private var result: Result?

    private enum Result: Equatable { case accepted, failed(String) }

    var body: some View {
        Group {
            if isRelevant, isDue || result != nil {
                card
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(ClickMotion.content, value: isDue)
        .animation(ClickMotion.content, value: result)
        .task(id: isRelevant) {
            guard isRelevant, result == nil else { return }
            isDue = await nudge.isDue(env)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ClickColors.accentForeground)
                    .frame(width: 34, height: 34)
                    .background(ClickColors.selectionTint, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(ClickTypography.bodyEmphasized)
                        .foregroundStyle(ClickColors.textPrimary)
                    Text(message)
                        .font(ClickTypography.metadata)
                        .foregroundStyle(ClickColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            switch result {
            case .accepted:
                Label("Turned on. Change it anytime in Privacy & data.", systemImage: "checkmark")
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.accentForeground)
            case .failed(let message):
                Text(message)
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.destructive)
            case nil:
                HStack(spacing: 10) {
                    Button(isSaving ? "Turning on…" : acceptTitle) {
                        Task { await accept() }
                    }
                    .buttonStyle(.bordered)
                    .tint(ClickColors.accentForeground)
                    .disabled(isSaving)
                    Button("Not now") {
                        nudge.dismiss(env)
                        isDue = false
                    }
                    .buttonStyle(.bordered)
                    .tint(ClickColors.textSecondary)
                    .disabled(isSaving)
                }
                .font(ClickTypography.supportingEmphasized)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ClickColors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func accept() async {
        isSaving = true
        defer { isSaving = false }
        if let message = await nudge.accept(env) {
            ClickHaptics.warning()
            result = .failed(message)
        } else {
            ClickHaptics.success()
            result = .accepted
        }
        isDue = false
    }
}
