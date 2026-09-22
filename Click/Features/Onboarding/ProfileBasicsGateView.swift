import SwiftUI

/// Blocking gate view required for accounts missing essential profile fields (first name, last name, birthday).
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
                VStack(alignment: .leading, spacing: ClickSpacing.large) {
                    // Header
                    VStack(alignment: .leading, spacing: ClickSpacing.xSmall) {
                        Text("Complete your profile")
                            .font(ClickTypography.title)
                            .foregroundStyle(ClickColors.label)

                        Text("We need your name and date of birth to continue. This keeps Click safe, authenticated, and age-appropriate.")
                            .font(ClickTypography.body)
                            .foregroundStyle(ClickColors.secondaryLabel)
                    }
                    .padding(.top, ClickSpacing.large)

                    // Error Banner
                    if let error = errorMessage {
                        HStack(spacing: ClickSpacing.small) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(ClickColors.statusDanger)
                            Text(error)
                                .font(ClickTypography.footnote)
                                .foregroundStyle(ClickColors.statusDanger)
                            Spacer()
                        }
                        .padding(ClickSpacing.small)
                        .background(ClickColors.statusDanger.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusSmall))
                    }

                    // Fields
                    VStack(spacing: ClickSpacing.medium) {
                        VStack(alignment: .leading, spacing: ClickSpacing.xxSmall) {
                            Text("FIRST NAME")
                                .font(ClickTypography.caption2)
                                .foregroundStyle(ClickColors.secondaryLabel)
                            TextField("First name", text: $firstName)
                                .textContentType(.givenName)
                                .padding()
                                .background(ClickColors.secondaryBackground)
                                .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusMedium))
                        }

                        VStack(alignment: .leading, spacing: ClickSpacing.xxSmall) {
                            Text("LAST NAME")
                                .font(ClickTypography.caption2)
                                .foregroundStyle(ClickColors.secondaryLabel)
                            TextField("Last name", text: $lastName)
                                .textContentType(.familyName)
                                .padding()
                                .background(ClickColors.secondaryBackground)
                                .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusMedium))
                        }

                        VStack(alignment: .leading, spacing: ClickSpacing.xxSmall) {
                            Text("DATE OF BIRTH")
                                .font(ClickTypography.caption2)
                                .foregroundStyle(ClickColors.secondaryLabel)

                            DatePicker(
                                "Date of Birth",
                                selection: $birthday,
                                in: ...Date(),
                                displayedComponents: .date
                            )
                            .padding(.horizontal, ClickSpacing.small)
                            .padding(.vertical, ClickSpacing.xSmall)
                            .background(ClickColors.secondaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusMedium))

                            if !isAgeValid {
                                Text("You must be at least 13 years old to use Click.")
                                    .font(ClickTypography.caption)
                                    .foregroundStyle(ClickColors.statusDanger)
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
                                    .tint(.white)
                            } else {
                                Text("Save and Continue")
                                    .font(ClickTypography.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, ClickSpacing.medium)
                        .background(canSave ? ClickColors.brandElectric : ClickColors.brandElectric.opacity(0.4))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusMedium))
                    }
                    .disabled(!canSave)
                }
                .padding(.horizontal, ClickSpacing.large)
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
