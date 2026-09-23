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
                            .font(ClickTypography.largeTitle)
                            .tracking(-0.5)
                            .foregroundStyle(ClickColors.textPrimary)

                        Text("We need your name and date of birth to continue. This keeps Click safe, authenticated, and age-appropriate.")
                            .font(ClickTypography.body)
                            .foregroundStyle(ClickColors.textSecondary)
                    }
                    .padding(.top, ClickSpacing.lg)

                    // Error Banner
                    if let error = errorMessage {
                        HStack(spacing: ClickSpacing.sm) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(ClickColors.destructive)
                            Text(error)
                                .font(ClickTypography.supportingEmphasized)
                                .foregroundStyle(ClickColors.destructive)
                            Spacer()
                        }
                        .padding(ClickSpacing.sm)
                        .background(ClickColors.destructive.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: ClickRadius.field))
                    }

                    // Fields
                    VStack(spacing: ClickSpacing.md) {
                        VStack(alignment: .leading, spacing: ClickSpacing.xs) {
                            Text("FIRST NAME")
                                .font(ClickTypography.metadata)
                                .foregroundStyle(ClickColors.textSecondary)
                            TextField("First name", text: $firstName)
                                .font(ClickTypography.body)
                                .textContentType(.givenName)
                                .padding(.horizontal, ClickSpacing.md)
                                .padding(.vertical, 14)
                                .background(ClickColors.surface)
                                .clipShape(RoundedRectangle(cornerRadius: ClickRadius.field))
                                .overlay(
                                    RoundedRectangle(cornerRadius: ClickRadius.field)
                                        .stroke(ClickColors.separator, lineWidth: ClickMetrics.strokeWidth)
                                )
                        }

                        VStack(alignment: .leading, spacing: ClickSpacing.xs) {
                            Text("LAST NAME")
                                .font(ClickTypography.metadata)
                                .foregroundStyle(ClickColors.textSecondary)
                            TextField("Last name", text: $lastName)
                                .font(ClickTypography.body)
                                .textContentType(.familyName)
                                .padding(.horizontal, ClickSpacing.md)
                                .padding(.vertical, 14)
                                .background(ClickColors.surface)
                                .clipShape(RoundedRectangle(cornerRadius: ClickRadius.field))
                                .overlay(
                                    RoundedRectangle(cornerRadius: ClickRadius.field)
                                        .stroke(ClickColors.separator, lineWidth: ClickMetrics.strokeWidth)
                                )
                        }

                        VStack(alignment: .leading, spacing: ClickSpacing.xs) {
                            Text("DATE OF BIRTH")
                                .font(ClickTypography.metadata)
                                .foregroundStyle(ClickColors.textSecondary)

                            HStack {
                                DatePicker(
                                    "Date of Birth",
                                    selection: $birthday,
                                    in: ...Date(),
                                    displayedComponents: .date
                                )
                                .labelsHidden()

                                Spacer()
                            }
                            .padding(.horizontal, ClickSpacing.md)
                            .padding(.vertical, 8)
                            .background(ClickColors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: ClickRadius.field))
                            .overlay(
                                RoundedRectangle(cornerRadius: ClickRadius.field)
                                    .stroke(ClickColors.separator, lineWidth: ClickMetrics.strokeWidth)
                            )

                            if !isAgeValid {
                                Text("You must be at least 13 years old to use Click.")
                                    .font(ClickTypography.metadata)
                                    .foregroundStyle(ClickColors.destructive)
                                    .padding(.top, ClickSpacing.xxs)
                            }
                        }
                    }

                    Spacer(minLength: 40)

                    // Save Button
                    Button {
                        saveProfileBasics()
                    } label: {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("Save and Continue")
                        }
                    }
                    .buttonStyle(.clickPrimary)
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
