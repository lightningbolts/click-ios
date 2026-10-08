import AuthenticationServices
import UIKit

/// Runs one `ASWebAuthenticationSession` (Google sign-in, ticket checkout) and returns the URL it
/// called back with. Throws `CancellationError` when the person closes the sheet.
@MainActor
enum WebAuthPresenter {
    /// Held while the sheet is up (the session must be retained until it finishes).
    private static var activeSession: ASWebAuthenticationSession?

    static func present(_ url: URL, callback: ASWebAuthenticationSession.Callback, startFailure: Error) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: callback) { callback, error in
                activeSession = nil
                if let callback {
                    continuation.resume(returning: callback)
                } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: error ?? CancellationError())
                }
            }
            session.presentationContextProvider = AuthContextProvider.shared
            session.prefersEphemeralWebBrowserSession = false
            activeSession = session
            if !session.start() {
                activeSession = nil
                continuation.resume(throwing: startFailure)
            }
        }
    }
}

/// Anchors web authentication sheets to the key window.
final class AuthContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthContextProvider()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) else {
            return ASPresentationAnchor()
        }
        return window
    }
}
