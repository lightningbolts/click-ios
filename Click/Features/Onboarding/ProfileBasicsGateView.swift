import SwiftUI

/// Blocking gate for accounts missing their name or birthday: every new email account (sign-up
/// asks only for email and password) and any Apple/Google account the provider didn't name.
public struct ProfileBasicsGateView: View {
    @Environment(AppEnvironment.self) private var env

    public let userId: String

    @State private var firstName: String = ""
    @State private var lastName: String = ""
    @State private var birthday: Date?
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case firstName, lastName }

    public init(userId: String, initialFirstName: String = "", initialLastName: String = "") {
        self.userId = userId
        self._firstName = State(initialValue: initialFirstName)
        self._lastName = State(initialValue: initialLastName)
    }

    private var canSave: Bool {
        !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !lastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        BirthdayField.isOldEnough(birthday) &&
        !isLoading
    }

    public var body: some View {
        OnboardingPage(
            title: "About you",
            subtitle: "Your name is how people you meet will know you. Your birthday keeps Click age-appropriate."
        ) {
            GroupedSection {
                TextField("First name", text: $firstName)
                    .textContentType(.givenName)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .firstName)
                    .onSubmit { focusedField = .lastName }
                TextField("Last name", text: $lastName)
                    .textContentType(.familyName)
                    .submitLabel(.done)
                    .focused($focusedField, equals: .lastName)
                BirthdayField(birthday: $birthday)
            }
            .font(ClickTypography.body)

            if BirthdayField.isTooYoung(birthday) {
                FormNotice(text: "You must be at least \(BirthdayField.minimumAge) years old to use Click.")
            } else if let errorMessage {
                FormNotice(text: errorMessage)
            }
        } actions: {
            Button(action: saveProfileBasics) {
                if isLoading { ProgressView() } else { Text("Continue") }
            }
            .buttonStyle(.clickPrimary)
            .disabled(!canSave)

            // Signed in with the wrong Apple ID or Google account: a way back out.
            Button("Use a different account") {
                Task { await env.session.signOut() }
            }
            .buttonStyle(.onboardingText)
            .disabled(isLoading)
        }
        .animation(ClickMotion.subtleFade, value: errorMessage)
        .onAppear {
            // Prefill what Apple/Google (or a partial profile) already told us.
            let hint = env.session.profileNameHint
            if firstName.isEmpty, let given = hint?.givenName { firstName = given }
            if lastName.isEmpty, let family = hint?.familyName { lastName = family }
            if firstName.isEmpty { focusedField = .firstName }
        }
    }

    private func saveProfileBasics() {
        guard canSave, let birthday else { return }
        ClickHaptics.impact(.medium)
        focusedField = nil
        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await env.session.completeProfileBasics(firstName: firstName, lastName: lastName, birthday: birthday)
                ClickHaptics.success()
            } catch {
                errorMessage = error.localizedDescription
                ClickHaptics.error()
            }
            isLoading = false
        }
    }
}
