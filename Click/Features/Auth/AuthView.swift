import SwiftUI
import AuthenticationServices

public enum AuthMode: String, CaseIterable, Identifiable {
    case signIn = "Sign In"
    case signUp = "Create Account"

    public var id: String { rawValue }
}

/// Sign in and sign up: Apple and Google first (one tap), then email and password. Sign-up asks
/// for nothing else; the Profile Basics gate collects name and birthday next.
public struct AuthView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    @State private var mode: AuthMode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var isPasswordVisible = false

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var appleRawNonce: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case email, password }

    static let minimumPasswordLength = 8

    public init(initialMode: AuthMode = .signIn) {
        self._mode = State(initialValue: initialMode)
    }

    private var canSubmit: Bool {
        let hasEmail = !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let passwordOK = mode == .signUp ? password.count >= Self.minimumPasswordLength : !password.isEmpty
        return hasEmail && passwordOK && !isLoading
    }

    public var body: some View {
        OnboardingPage(
            title: mode == .signIn ? "Welcome back" : "Join Click",
            subtitle: "In-person first connections and private messaging.",
            showsLogo: true
        ) {
            VStack(spacing: ClickSpacing.sm) {
                SignInWithAppleButton(
                    mode == .signIn ? .signIn : .continue,
                    onRequest: { request in
                        request.requestedScopes = [.fullName, .email]
                        let rawNonce = AuthCrypto.randomToken()
                        appleRawNonce = rawNonce
                        request.nonce = AuthCrypto.sha256Hex(rawNonce)
                    },
                    onCompletion: { result in
                        handleAppleSignIn(result)
                    }
                )
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: ClickMetrics.primaryActionHeight)
                .clipShape(Capsule())
                .id(colorScheme)

                Button(action: handleGoogleOAuthSignIn) {
                    Label("Continue with Google", systemImage: "globe")
                        .frame(minHeight: ClickMetrics.primaryActionHeight)
                }
                .buttonStyle(.clickSecondary)
            }
            .disabled(isLoading)

            HStack(spacing: ClickSpacing.md) {
                Rectangle().fill(ClickColors.separator).frame(height: 0.5)
                Text("or use email")
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.textTertiary)
                    .fixedSize()
                Rectangle().fill(ClickColors.separator).frame(height: 0.5)
            }

            VStack(alignment: .leading, spacing: ClickSpacing.sm) {
                GroupedSection {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.next)
                        .focused($focusedField, equals: .email)
                        .onSubmit { focusedField = .password }
                    HStack {
                        Group {
                            if isPasswordVisible {
                                TextField("Password", text: $password)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textContentType(mode == .signIn ? .password : .newPassword)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { if canSubmit { handlePrimaryAction() } }

                        Button {
                            isPasswordVisible.toggle()
                        } label: {
                            Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                                .foregroundStyle(ClickColors.textTertiary)
                                .frame(width: 32, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
                    }
                }
                .font(ClickTypography.body)

                HStack {
                    if mode == .signUp {
                        Text("At least \(Self.minimumPasswordLength) characters")
                            .foregroundStyle(password.isEmpty || password.count >= Self.minimumPasswordLength
                                             ? ClickColors.textTertiary : ClickColors.destructive)
                    } else {
                        // The reset finishes on joinclick.co in Safari, which holds the link's
                        // verifier; an in-app browser would strand the emailed link.
                        Button("Forgot password?") {
                            if let url = URL(string: "https://joinclick.co/forgot-password") { openURL(url) }
                        }
                        .foregroundStyle(ClickColors.accentForeground)
                    }
                    Spacer()
                }
                .font(ClickTypography.metadata)
                .padding(.horizontal, ClickSpacing.surfacePadding)
            }

            if let errorMessage {
                FormNotice(text: errorMessage)
            } else if let infoMessage {
                FormNotice(text: infoMessage, kind: .info)
            }
        } actions: {
            Button(action: handlePrimaryAction) {
                if isLoading { ProgressView() } else { Text(mode == .signIn ? "Sign In" : "Create Account") }
            }
            .buttonStyle(.clickPrimary)
            .disabled(!canSubmit)

            Button {
                switchMode()
            } label: {
                Text(mode == .signIn ? "New to Click? " : "Have an account? ")
                    + Text(mode == .signIn ? "Create an account" : "Sign in").foregroundStyle(ClickColors.accentForeground)
            }
            .buttonStyle(.onboardingText)
            .disabled(isLoading)

            // App Review 1.2: agreeing to terms that bar objectionable content and abusive users.
            Text("By continuing, you agree to Click's [Terms](https://joinclick.co/terms) and [Privacy Policy](https://joinclick.co/privacy). Click has zero tolerance for objectionable content or abusive users.")
                .font(ClickTypography.metadata)
                .foregroundStyle(ClickColors.textTertiary)
                .tint(ClickColors.accentForeground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(ClickMotion.subtleFade, value: mode)
        .animation(ClickMotion.subtleFade, value: errorMessage)
        .animation(ClickMotion.subtleFade, value: infoMessage)
    }

    // MARK: - Actions

    /// Switching by hand clears the other form's banners (the verify-email handoff sets the mode
    /// itself and keeps its banner).
    private func switchMode() {
        ClickHaptics.selection()
        errorMessage = nil
        infoMessage = nil
        mode = mode == .signIn ? .signUp : .signIn
    }

    private func handlePrimaryAction() {
        guard canSubmit else { return }
        ClickHaptics.impact(.medium)
        focusedField = nil
        isLoading = true
        errorMessage = nil
        infoMessage = nil
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                if mode == .signIn {
                    try await env.session.signInWithEmail(email: email, password: password)
                } else {
                    switch try await env.session.signUpWithEmail(email: email, password: password) {
                    case .authenticated:
                        break
                    case .verificationRequired(let userEmail):
                        // Hand off to Sign In with the credentials still filled: after tapping
                        // the emailed link, one tap finishes.
                        mode = .signIn
                        infoMessage = "Check \(userEmail) and tap the link we sent. Then come back and sign in."
                    }
                }
                ClickHaptics.success()
            } catch {
                errorMessage = error.localizedDescription
                ClickHaptics.error()
            }
            isLoading = false
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                errorMessage = "Unable to process Apple authorization credential."
                return
            }

            isLoading = true
            errorMessage = nil

            let nonce = appleRawNonce
            appleRawNonce = nil

            Task {
                do {
                    guard let nonce else {
                        throw APIError.validation(code: "apple_nonce_missing", message: "Apple sign-in state expired. Please try again.")
                    }
                    let authService = SupabaseAuthService()
                    let snapshot = try await authService.signInWithApple(idToken: token, nonce: nonce)
                    // Apple shares the name only on the first authorization: keep it for Profile Basics.
                    env.session.signIn(snapshot: snapshot, nameHint: credential.fullName)
                    ClickHaptics.success()
                } catch {
                    errorMessage = error.localizedDescription
                    ClickHaptics.error()
                }
                isLoading = false
            }

        case .failure(let error):
            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                errorMessage = error.localizedDescription
                ClickHaptics.error()
            }
        }
    }

    /// Google's own sign-in page for Click's iOS client, then the ID token goes to Supabase.
    private func handleGoogleOAuthSignIn() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let credential = try await GoogleSignIn.signIn()
                let snapshot = try await SupabaseAuthService().signInWithGoogle(idToken: credential.idToken, nonce: credential.nonce)
                env.session.signIn(snapshot: snapshot, nameHint: credential.name)
                ClickHaptics.success()
            } catch is CancellationError {
                // Closed the sheet: nothing to report.
            } catch {
                errorMessage = error.localizedDescription
                ClickHaptics.error()
            }
            isLoading = false
        }
    }
}
