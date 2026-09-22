import SwiftUI
import AuthenticationServices

public enum AuthMode: String, CaseIterable, Identifiable {
    case signIn = "Sign In"
    case signUp = "Create Account"

    public var id: String { rawValue }
}

/// Native SwiftUI authentication screen supporting Email/Password, Sign in with Apple, and Google OAuth.
public struct AuthView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var mode: AuthMode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var isPasswordVisible = false

    // Sign up specific fields
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var birthday = Calendar.current.date(byAdding: .year, value: -18, to: Date()) ?? Date()

    @State private var isLoading = false
    @State private var errorMessage: String?

    public init(initialMode: AuthMode = .signIn) {
        self._mode = State(initialValue: initialMode)
    }

    private var isAgeValid: Bool {
        let age = Calendar.current.dateComponents([.year], from: birthday, to: Date()).year ?? 0
        return age >= 13
    }

    private var canSubmit: Bool {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              password.count >= 6,
              !isLoading else { return false }

        if mode == .signUp {
            return !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                   !lastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                   isAgeValid
        }
        return true
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ClickSpacing.large) {
                    // Header Brand
                    VStack(spacing: ClickSpacing.small) {
                        Image(systemName: "circle.circle.fill")
                            .resizable()
                            .frame(width: 52, height: 52)
                            .foregroundStyle(ClickColors.brandElectric)
                            .padding(.top, ClickSpacing.medium)

                        Text("Click")
                            .font(ClickTypography.largeTitle)
                            .foregroundStyle(ClickColors.label)

                        Text("In-person first connection & private messaging.")
                            .font(ClickTypography.subheadline)
                            .foregroundStyle(ClickColors.secondaryLabel)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, ClickSpacing.large)
                    }

                    // Mode Picker
                    Picker("Authentication Mode", selection: $mode) {
                        ForEach(AuthMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, ClickSpacing.large)

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
                        .padding(.horizontal, ClickSpacing.large)
                    }

                    // Form Fields
                    VStack(spacing: ClickSpacing.medium) {
                        if mode == .signUp {
                            HStack(spacing: ClickSpacing.small) {
                                TextField("First name", text: $firstName)
                                    .textContentType(.givenName)
                                    .padding()
                                    .background(ClickColors.secondaryBackground)
                                    .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusMedium))

                                TextField("Last name", text: $lastName)
                                    .textContentType(.familyName)
                                    .padding()
                                    .background(ClickColors.secondaryBackground)
                                    .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusMedium))
                            }

                            // Birthday Picker
                            VStack(alignment: .leading, spacing: ClickSpacing.xxSmall) {
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
                                        .padding(.leading, ClickSpacing.xSmall)
                                }
                            }
                        }

                        // Email
                        TextField("Email address", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding()
                            .background(ClickColors.secondaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusMedium))

                        // Password
                        HStack {
                            if isPasswordVisible {
                                TextField("Password", text: $password)
                                    .textContentType(mode == .signIn ? .password : .newPassword)
                            } else {
                                SecureField("Password", text: $password)
                                    .textContentType(mode == .signIn ? .password : .newPassword)
                            }

                            Button {
                                isPasswordVisible.toggle()
                            } label: {
                                Image(systemName: isPasswordVisible ? "eye.slash.fill" : "eye.fill")
                                    .foregroundStyle(ClickColors.secondaryLabel)
                            }
                        }
                        .padding()
                        .background(ClickColors.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusMedium))
                    }
                    .padding(.horizontal, ClickSpacing.large)

                    // Primary Action Button
                    Button {
                        handlePrimaryAction()
                    } label: {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text(mode == .signIn ? "Sign In" : "Create Account")
                                    .font(ClickTypography.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, ClickSpacing.medium)
                        .background(canSubmit ? ClickColors.brandElectric : ClickColors.brandElectric.opacity(0.4))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusMedium))
                    }
                    .disabled(!canSubmit)
                    .padding(.horizontal, ClickSpacing.large)

                    // Forgot Password
                    if mode == .signIn {
                        Button {
                            if let url = URL(string: "https://joinclick.co/forgot-password") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Text("Forgot password?")
                                .font(ClickTypography.footnote)
                                .foregroundStyle(ClickColors.brandElectric)
                        }
                    }

                    // Divider
                    HStack {
                        Rectangle().frame(height: 1).foregroundStyle(ClickColors.separator)
                        Text("or")
                            .font(ClickTypography.footnote)
                            .foregroundStyle(ClickColors.secondaryLabel)
                            .padding(.horizontal, ClickSpacing.small)
                        Rectangle().frame(height: 1).foregroundStyle(ClickColors.separator)
                    }
                    .padding(.horizontal, ClickSpacing.large)
                    .padding(.vertical, ClickSpacing.xSmall)

                    // Third Party Sign In
                    VStack(spacing: ClickSpacing.small) {
                        SignInWithAppleButton(
                            .signIn,
                            onRequest: { request in
                                request.requestedScopes = [.fullName, .email]
                            },
                            onCompletion: { result in
                                handleAppleSignIn(result)
                            }
                        )
                        .signInWithAppleButtonStyle(.black)
                        .frame(height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusMedium))

                        // Google Sign-In
                        Button {
                            // Opens Google OAuth callback
                            if let url = URL(string: "https://lrgcwnmcscimkmslihxp.supabase.co/auth/v1/authorize?provider=google&redirect_to=click://login") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: ClickSpacing.small) {
                                Image(systemName: "globe")
                                    .foregroundStyle(ClickColors.label)
                                Text("Continue with Google")
                                    .font(ClickTypography.headline)
                                    .foregroundStyle(ClickColors.label)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(ClickColors.secondaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusMedium))
                        }

                        // Demo Mode Bypass (Quick Test)
                        Button {
                            env.session.signIn(
                                snapshot: SessionSnapshot(
                                    userId: "usr_demo_\(UUID().uuidString.prefix(6))",
                                    jwt: "demo_jwt_token",
                                    refreshToken: "demo_refresh_token"
                                )
                            )
                        } label: {
                            Text("Fast Demo Sign-In")
                                .font(ClickTypography.footnote)
                                .foregroundStyle(ClickColors.secondaryLabel)
                                .padding(.top, ClickSpacing.small)
                        }
                    }
                    .padding(.horizontal, ClickSpacing.large)
                    .padding(.bottom, ClickSpacing.xxLarge)
                }
            }
            .background(ClickColors.background.ignoresSafeArea())
            .animation(ClickMotion.content, value: mode)
        }
    }

    private func handlePrimaryAction() {
        ClickHaptics.impact(.medium)
        isLoading = true
        errorMessage = nil

        Task {
            do {
                if mode == .signIn {
                    try await env.session.signInWithEmail(email: email, password: password)
                } else {
                    try await env.session.signUpWithEmail(
                        email: email,
                        password: password,
                        firstName: firstName,
                        lastName: lastName,
                        birthday: birthday
                    )
                }
                ClickHaptics.success()
            } catch let err as APIError {
                errorMessage = err.localizedDescription
                ClickHaptics.error()
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
            if let credential = auth.credential as? ASAuthorizationAppleIDCredential {
                let userId = credential.user
                let snapshot = SessionSnapshot(
                    userId: userId,
                    jwt: "apple_credential_jwt",
                    refreshToken: "apple_credential_refresh"
                )
                // If account missing names, can transition to ProfileBasics
                env.session.signIn(snapshot: snapshot)
            }
        case .failure(let err):
            let nsErr = err as NSError
            if nsErr.code != ASAuthorizationError.canceled.rawValue {
                errorMessage = err.localizedDescription
            }
        }
    }
}
