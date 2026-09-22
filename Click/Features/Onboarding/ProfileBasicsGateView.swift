import SwiftUI

/// Blocking gate view required for accounts missing essential profile fields (first name, last name, birthday).
/// Aligned with Click's Functional Clarity design system (Manrope, Click purple CTA, quiet borders).
public struct ProfileBasicsGateView: View {
    @Environment(AppEnvironment.self) private var env

    public let userId: String

    @State private var firstName: String = ""
    @State private var lastName: String = ""
    @State private var birthday: Date = Calendar.current.date(byAdding: .year, value: -18, to: Date()) ?? Date()
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    public init(userId: String, initialFirstName: String = "", initialLastName: String = "") {
        self.userId = userId
        self._firstName = State(initialValue: initialFirstName)
        self._lastName = State(initialValue: initialLastName)
    }

    private var isAgeValid: Bool {
        let age = Calendar.current.dateComponents([.year], from: birthday, to: Date()).year ?? 0
        return age >= 13
    }

    private var canSave: Bool {
        !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !lastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        isAgeValid &&
        !isLoading
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ClickSpacing.lg) {
                    // Header
                    VStack(alignment: .leading, spacing: ClickSpacing.sm) {
                        Text("Complete your profile")
                            .font(ClickTypography.headlineLarge)
                            .tracking(-0.5)
                            .foregroundStyle(ClickColors.textPrimary)

                        Text("We need your name and date of birth to continue. This keeps Click safe, authenticated, and age-appropriate.")
                            .font(ClickTypography.bodyMedium)
                            .foregroundStyle(ClickColors.textSecondary)
                    }
                    .padding(.top, ClickSpacing.lg)

                    // Error Banner
                    if let error = errorMessage {
                        HStack(spacing: ClickSpacing.sm) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(ClickColors.error)
                            Text(error)
                                .font(ClickTypography.labelMedium)
                                .foregroundStyle(ClickColors.error)
                            Spacer()
                        }
                        .padding(ClickSpacing.sm)
                        .background(ClickColors.error.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusInput))
                    }

                    // Fields
                    VStack(spacing: ClickSpacing.md) {
                        VStack(alignment: .leading, spacing: ClickSpacing.xs) {
                            Text("FIRST NAME")
                                .font(ClickTypography.labelSmall)
                                .foregroundStyle(ClickColors.textSecondary)
                            TextField("First name", text: $firstName)
                                .font(ClickTypography.bodyMedium)
                                .textContentType(.givenName)
                                .padding(.horizontal, ClickSpacing.md)
                                .padding(.vertical, 14)
                                .background(ClickColors.surfaceContainerLow)
                                .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusInput))
                                .overlay(
                                    RoundedRectangle(cornerRadius: ClickSpacing.radiusInput)
                                        .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
                                )
                        }

                        VStack(alignment: .leading, spacing: ClickSpacing.xs) {
                            Text("LAST NAME")
                                .font(ClickTypography.labelSmall)
                                .foregroundStyle(ClickColors.textSecondary)
                            TextField("Last name", text: $lastName)
                                .font(ClickTypography.bodyMedium)
                                .textContentType(.familyName)
                                .padding(.horizontal, ClickSpacing.md)
                                .padding(.vertical, 14)
                                .background(ClickColors.surfaceContainerLow)
                                .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusInput))
                                .overlay(
                                    RoundedRectangle(cornerRadius: ClickSpacing.radiusInput)
                                        .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
                                )
                        }

                        VStack(alignment: .leading, spacing: ClickSpacing.xs) {
                            Text("DATE OF BIRTH")
                                .font(ClickTypography.labelSmall)
                                .foregroundStyle(ClickColors.textSecondary)

                            DatePicker(
                                "Date of Birth",
                                selection: $birthday,
                                in: ...Date(),
                                displayedComponents: .date
                            )
                            .font(ClickTypography.bodyMedium)
                            .padding(.horizontal, ClickSpacing.md)
                            .padding(.vertical, 10)
                            .background(ClickColors.surfaceContainerLow)
                            .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusInput))
                            .overlay(
                                RoundedRectangle(cornerRadius: ClickSpacing.radiusInput)
                                    .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
                            )

                            if !isAgeValid {
                                Text("You must be at least 13 years old to use Click.")
                                    .font(ClickTypography.labelSmall)
                                    .foregroundStyle(ClickColors.error)
                                    .padding(.top, ClickSpacing.xxxSmall)
                            }
                        }
                    }

                    Spacer(minLength: 40)

                    // Save Button
                    Button {
                        saveProfileBasics()
                    } label: {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .tint(ClickColors.onPrimary)
                            } else {
                                Text("Save and Continue")
                                    .font(ClickTypography.labelBold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(canSave ? ClickColors.primary : ClickColors.primary.opacity(0.4))
                        .foregroundStyle(ClickColors.onPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusButton))
                    }
                    .disabled(!canSave)
                }
                .padding(.horizontal, ClickSpacing.lg)
            }
            .background(ClickColors.background.ignoresSafeArea())
        }
    }

    private func saveProfileBasics() {
        ClickHaptics.impact(.medium)
        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await env.session.completeProfileBasics(
                    firstName: firstName,
                    lastName: lastName,
                    birthday: birthday
                )
                ClickHaptics.success()
            } catch {
                errorMessage = error.localizedDescription
                ClickHaptics.error()
            }
            isLoading = false
        }
    }
}
