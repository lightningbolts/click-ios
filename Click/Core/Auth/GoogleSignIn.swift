import AuthenticationServices
import UIKit
import CryptoKit
import Foundation

/// Native Google sign-in without an SDK: Google's own sign-in page for Click's iOS OAuth client
/// (authorization code + PKCE), then the ID token is exchanged with Supabase
/// (`signInWithGoogle(idToken:nonce:)`). iOS and Google show Click and accounts.google.com,
/// never the Supabase project URL that the web redirect flow exposed.
@MainActor
enum GoogleSignIn {
    struct Credential {
        let idToken: String
        /// The raw nonce; Google's token carries its SHA-256, which Supabase verifies.
        let nonce: String

        /// The given/family name claims of the ID token (requested with the `profile` scope).
        var name: PersonNameComponents? {
            let parts = idToken.split(separator: ".")
            guard parts.count > 1 else { return nil }
            var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            guard let data = Data(base64Encoded: payload),
                  let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            var name = PersonNameComponents()
            name.givenName = claims["given_name"] as? String
            name.familyName = claims["family_name"] as? String
            return name.givenName == nil && name.familyName == nil ? nil : name
        }
    }

    /// Throws `CancellationError` when the user closes the sheet.
    static func signIn(bundle: Bundle = .main) async throws -> Credential {
        guard let clientID = bundle.object(forInfoDictionaryKey: "GIDClientID") as? String,
              clientID.hasSuffix(".apps.googleusercontent.com") else {
            throw APIError.validation(code: "google_not_configured", message: "Google sign-in isn't set up in this build.")
        }
        // The server (web) client is the ID token's audience, as the Google SDK requested it.
        let audience = bundle.object(forInfoDictionaryKey: "GIDServerClientID") as? String
        let scheme = "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        let redirectURI = scheme + ":/oauth2redirect"
        let verifier = AuthCrypto.randomToken()
        let state = AuthCrypto.randomToken()
        let nonce = AuthCrypto.randomToken()

        var authorize = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        authorize.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: AuthCrypto.sha256Base64URL(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: AuthCrypto.sha256Hex(nonce))
        ]

        let callback = try await present(authorize.url!, scheme: scheme)
        let returned = Dictionary(
            (URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        if let error = returned["error"] {
            if error == "access_denied" { throw CancellationError() }
            throw APIError.validation(code: "google_\(error)", message: "Google sign-in didn't complete. Please try again.")
        }
        guard returned["state"] == state, let code = returned["code"], !code.isEmpty else {
            throw APIError.validation(code: "google_bad_callback", message: "Google sign-in didn't return to Click correctly. Please try again.")
        }

        var form = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ]
        if let audience, !audience.isEmpty { form["audience"] = audience }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.map { "\($0.key)=\(formEncode($0.value))" }.joined(separator: "&").utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = json["id_token"] as? String else {
            throw APIError.validation(code: "google_token_exchange", message: "Couldn't finish Google sign-in. Please try again.")
        }
        return Credential(idToken: idToken, nonce: nonce)
    }

    private static func present(_ url: URL, scheme: String) async throws -> URL {
        try await WebAuthPresenter.present(
            url,
            callback: .customScheme(scheme),
            startFailure: APIError.validation(code: "google_start", message: "Unable to start Google sign-in.")
        )
    }

    private static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }
}

/// Nonces and PKCE values for the Apple and Google sign-in flows.
enum AuthCrypto {
    /// 256 random bits, base64url without padding.
    static func randomToken() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { base64URL(Data($0)) }
    }

    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Base64URL(_ value: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(value.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
