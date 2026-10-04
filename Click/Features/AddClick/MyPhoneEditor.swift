import SwiftUI

/// Your own phone number, so friends who have it in their contacts can find you in Find friends.
/// Shown on Find friends and in Privacy & data; layout-neutral so it sits in a card or a Form row.
struct MyPhoneEditor: View {
    @Environment(AppEnvironment.self) private var env

    /// Called with the saved number (nil once removed), e.g. to collapse the Find friends card.
    var onChange: (String?) -> Void = { _ in }

    @State private var saved: String?
    @State private var draft = ""
    @State private var loaded = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    /// The number another account holds, after a save was refused; offers "That's my number".
    @State private var takenNumber: String?
    @State private var reported = false

    var body: some View {
        VStack(alignment: .leading, spacing: ClickSpacing.xs) {
            if let saved {
                HStack {
                    Text(saved)
                        .font(ClickTypography.bodyEmphasized)
                        .foregroundStyle(ClickColors.textPrimary)
                    Spacer(minLength: 8)
                    Button(isWorking ? "Removing…" : "Remove", role: .destructive) { Task { await remove() } }
                        .font(ClickTypography.supportingEmphasized)
                        .disabled(isWorking)
                }
            } else {
                HStack(spacing: ClickSpacing.sm) {
                    TextField("Your phone number", text: $draft)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .font(ClickTypography.body)
                        .disabled(!loaded)
                    Button(action: { Task { await save() } }) {
                        if isWorking { ProgressView() } else { Text("Save") }
                    }
                    .font(ClickTypography.supportingEmphasized)
                    .disabled(isWorking || draft.filter(\.isNumber).count < 10)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.destructive)
            }
            if reported {
                Text("Thanks. We'll look into it and free up your number if it's yours.")
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.textSecondary)
            } else if takenNumber != nil {
                Button("That's my number") { Task { await report() } }
                    .font(ClickTypography.supportingEmphasized)
                    .foregroundStyle(ClickColors.accentForeground)
                    .disabled(isWorking)
            }
        }
        .animation(ClickMotion.subtleFade, value: saved)
        .task { await load() }
    }

    private func load() async {
        guard !loaded else { return }
        if let phone = try? await ContactDiscoveryService.shared.myPhone(client: env.api) {
            saved = phone
            onChange(phone)
        }
        loaded = true
    }

    private func save() async {
        isWorking = true
        errorMessage = nil
        takenNumber = nil
        reported = false
        defer { isWorking = false }
        do {
            let phone = try await ContactDiscoveryService.shared.saveMyPhone(draft, client: env.api)
            saved = phone
            draft = ""
            onChange(phone)
            ClickHaptics.success()
        } catch {
            errorMessage = switch error as? APIError {
            case .conflict?: "That number is already on another Click account."
            case .validation?: "Enter a full phone number, with area code."
            case .rateLimited?: "You've changed your number a few times today. Try again tomorrow."
            default: "Your number wasn't saved. \(error.userFacingMessage)"
            }
            if case .conflict? = error as? APIError { takenNumber = draft }
            ClickHaptics.error()
        }
    }

    private func report() async {
        guard let takenNumber else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await ContactDiscoveryService.shared.reportPhoneClaim(takenNumber, client: env.api)
            reported = true
            errorMessage = nil
            ClickHaptics.success()
        } catch {
            errorMessage = "Your report wasn't sent. \(error.userFacingMessage)"
        }
    }

    private func remove() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await ContactDiscoveryService.shared.removeMyPhone(client: env.api)
            saved = nil
            onChange(nil)
        } catch {
            errorMessage = "Your number wasn't removed. \(error.userFacingMessage)"
        }
    }
}
