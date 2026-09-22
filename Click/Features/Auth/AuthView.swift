import SwiftUI
import AuthenticationServices

public enum AuthMode: String, CaseIterable, Identifiable {
    case signIn = "Sign In"
    case signUp = "Create Account"

    public var id: String { rawValue }
}

/// Native SwiftUI authentication screen supporting Email/Password, Sign in with Apple, and Google OAuth.
/// Formatted strictly according to Click's purple-first Functional Clarity visual identity.
public struct AuthView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var colorScheme

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
                VStack(spacing: ClickSpacing.lg) {
                    // Header Brand
                    VStack(spacing: ClickSpacing.sm) {
                        ClickLogo(size: 64)
                            .padding(.top, ClickSpacing.md)

                        Text("Click")
                            .font(ClickTypography.headlineLarge)
                            .tracking(-0.5)
                            .foregroundStyle(ClickColors.textPrimary)

                        Text("In-person first connection & private messaging.")
                            .font(ClickTypography.bodyMedium)
                            .foregroundStyle(ClickColors.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, ClickSpacing.lg)
                    }

                    // Mode Picker
                    Picker("Authentication Mode", selection: $mode) {
                        ForEach(AuthMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, ClickSpacing.lg)

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
                        .padding(.horizontal, ClickSpacing.lg)
                    }

                    // Form Fields
                    VStack(spacing: ClickSpacing.md) {
                        if mode == .signUp {
                            HStack(spacing: ClickSpacing.sm) {
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

                            // Birthday Picker
                            VStack(alignment: .leading, spacing: ClickSpacing.xs) {
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
                                        .padding(.leading, ClickSpacing.xs)
                                }
                            }
                        }

                        // Email Field
                        TextField("Email address", text: $email)
                            .font(ClickTypography.bodyMedium)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(.horizontal, ClickSpacing.md)
                            .padding(.vertical, 14)
                            .background(ClickColors.surfaceContainerLow)
                            .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusInput))
                            .overlay(
                                RoundedRectangle(cornerRadius: ClickSpacing.radiusInput)
                                    .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
                            )

                        // Password Field
                        HStack {
                            if isPasswordVisible {
                                TextField("Password", text: $password)
                                    .font(ClickTypography.bodyMedium)
                                    .textContentType(mode == .signIn ? .password : .newPassword)
                            } else {
                                SecureField("Password", text: $password)
                                    .font(ClickTypography.bodyMedium)
                                    .textContentType(mode == .signIn ? .password : .newPassword)
                            }

                            Button {
                                isPasswordVisible.toggle()
                            } label: {
                                Image(systemName: isPasswordVisible ? "eye.slash.fill" : "eye.fill")
                                    .foregroundStyle(ClickColors.textSecondary)
                            }
                        }
                        .padding(.horizontal, ClickSpacing.md)
                        .padding(.vertical, 14)
                        .background(ClickColors.surfaceContainerLow)
                        .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusInput))
                        .overlay(
                            RoundedRectangle(cornerRadius: ClickSpacing.radiusInput)
                                .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
                        )
                    }
                    .padding(.horizontal, ClickSpacing.lg)

                    // Primary Action Button (Canonical Click Purple)
                    Button {
                        handlePrimaryAction()
                    } label: {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .tint(ClickColors.onPrimary)
                            } else {
                                Text(mode == .signIn ? "Sign In" : "Create Account")
                                    .font(ClickTypography.labelBold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(canSubmit ? ClickColors.primary : ClickColors.primary.opacity(0.4))
                        .foregroundStyle(ClickColors.onPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusButton))
                    }
                    .disabled(!canSubmit)
                    .padding(.horizontal, ClickSpacing.lg)

                    // Forgot Password Link
                    if mode == .signIn {
                        Button {
                            if let url = URL(string: "https://joinclick.co/forgot-password") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Text("Forgot password?")
                                .font(ClickTypography.labelMedium)
                                .foregroundStyle(ClickColors.primary)
                        }
                    }

                    // Divider
                    HStack {
                        Rectangle()
                            .frame(height: ClickSpacing.borderQuietWidth)
                            .foregroundStyle(ClickColors.quietBorder)
                        Text("or")
                            .font(ClickTypography.labelMedium)
                            .foregroundStyle(ClickColors.textSecondary)
                            .padding(.horizontal, ClickSpacing.sm)
                        Rectangle()
                            .frame(height: ClickSpacing.borderQuietWidth)
                            .foregroundStyle(ClickColors.quietBorder)
                    }
                    .padding(.horizontal, ClickSpacing.lg)
                    .padding(.vertical, ClickSpacing.xs)

                    // Third-Party Providers
                    VStack(spacing: ClickSpacing.sm) {
                        SignInWithAppleButton(
                            .signIn,
                            onRequest: { request in
                                request.requestedScopes = [.fullName, .email]
                            },
                            onCompletion: { result in
                                handleAppleSignIn(result)
                            }
                        )
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusButton))

                        // Google Sign-In
                        Button {
                            if let url = URL(string: "https://lrgcwnmcscimkmslihxp.supabase.co/auth/v1/authorize?provider=google&redirect_to=click://login") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: ClickSpacing.sm) {
                                Image(systemName: "globe")
                                    .foregroundStyle(ClickColors.textPrimary)
                                Text("Continue with Google")
                                    .font(ClickTypography.labelBold)
                                    .foregroundStyle(ClickColors.textPrimary)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(ClickColors.surfaceContainerLow)
                            .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusButton))
                            .overlay(
                                RoundedRectangle(cornerRadius: ClickSpacing.radiusButton)
                                    .stroke(ClickColors.quietBorder, lineWidth: ClickSpacing.borderQuietWidth)
                            )
                        }

                        #if DEBUG
                        // Demo Mode Bypass (strictly debug-only per Section 9)
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
                                .font(ClickTypography.labelMedium)
                                .foregroundStyle(ClickColors.textSecondary)
                                .padding(.top, ClickSpacing.sm)
                        }
                        #endif
                    }
                    .padding(.horizontal, ClickSpacing.lg)
                }
                .padding(.bottom, ClickSpacing.xxl)
            }
            .background(ClickColors.background.ignoresSafeArea())
        }
    }

    // MARK: - Actions
    private func handlePrimaryAction() {
        ClickHaptics.impact(.medium)
        isLoading = true
        errorMessage = nil

        Task {
            do {
                if mode == .signIn {
                    try await env.session.signInWithEmail(
                        email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                        password: password
                    )
                } else {
                    try await env.session.signUpWithEmail(
                        email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                        password: password,
                        firstName: firstName.trimmingCharacters(in: .whitespacesAndNewlines),
                        lastName: lastName.trimmingCharacters(in: .whitespacesAndNewlines),
                        birthday: birthday
                    )
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
            // Supabase auth using id_token
            let userId = credential.user
            env.session.signIn(
                snapshot: SessionSnapshot(
                    userId: userId,
                    jwt: token,
                    refreshToken: "apple_auth_refresh"
                )
            )
            ClickHaptics.success()
        case .failure(let error):
            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                errorMessage = error.localizedDescription
                ClickHaptics.error()
            }
        }
    }
}
