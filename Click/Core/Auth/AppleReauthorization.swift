import AuthenticationServices
import Foundation
import UIKit

/// Sign in with Apple again at account deletion. The fresh authorization code goes to
/// `DELETE /api/user/delete`, which exchanges it and revokes the Apple tokens (App Store
/// 5.1.1(v)). Supabase `signInWithIdToken` keeps no Apple refresh token, so this is the only
/// way to revoke; it also confirms it's really the account holder deleting.
@MainActor
enum AppleReauthorization {
    /// Whether the signed-in account has an Apple identity: `app_metadata.providers` (or the
    /// primary `provider`) in the Supabase access token.
    nonisolated static func isAppleAccount(jwt: String) -> Bool {
        let parts = jwt.split(separator: ".")
        guard parts.count > 1 else { return false }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let appMetadata = claims["app_metadata"] as? [String: Any] else { return false }
        if let providers = appMetadata["providers"] as? [String] { return providers.contains("apple") }
        return appMetadata["provider"] as? String == "apple"
    }

    /// Kept alive while the Apple sheet is up; the controller holds its delegate weakly.
    private static var active: Coordinator?

    /// A fresh authorization code. Throws `CancellationError` when the person cancels.
    static func authorizationCode() async throws -> String {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        let controller = ASAuthorizationController(authorizationRequests: [request])
        return try await withCheckedThrowingContinuation { continuation in
            let coordinator = Coordinator { result in
                active = nil
                continuation.resume(with: result)
            }
            active = coordinator
            controller.delegate = coordinator
            controller.presentationContextProvider = coordinator
            controller.performRequests()
        }
    }

    private final class Coordinator: NSObject, ASAuthorizationControllerDelegate,
        ASAuthorizationControllerPresentationContextProviding {
        private let finish: @MainActor (Result<String, Error>) -> Void

        init(finish: @escaping @MainActor (Result<String, Error>) -> Void) {
            self.finish = finish
        }

        nonisolated func authorizationController(
            controller: ASAuthorizationController,
            didCompleteWithAuthorization authorization: ASAuthorization
        ) {
            let code = (authorization.credential as? ASAuthorizationAppleIDCredential)?
                .authorizationCode
                .flatMap { String(data: $0, encoding: .utf8) }
            MainActor.assumeIsolated {
                if let code {
                    finish(.success(code))
                } else {
                    finish(.failure(APIError.validation(code: "apple_code_missing", message: "Apple didn't return an authorization code.")))
                }
            }
        }

        nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
            let canceled = (error as? ASAuthorizationError)?.code == .canceled
            MainActor.assumeIsolated {
                finish(.failure(canceled ? CancellationError() : error))
            }
        }

        nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
            MainActor.assumeIsolated {
                let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
                return scene?.windows.first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
            }
        }
    }
}
