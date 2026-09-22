import Foundation

/// DTO representing Supabase Auth session response.
public struct SupabaseAuthResponse: Decodable, Sendable {
    public let accessToken: String?
    public let refreshToken: String?
    public let expiresIn: Int?
    public let tokenType: String?
    public let user: SupabaseUser?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case user
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
        self.refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        self.expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn)
        self.tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType)
        
        // GoTrue returns user either in container or at root level during signup confirmation
        if let u = try container.decodeIfPresent(SupabaseUser.self, forKey: .user) {
            self.user = u
        } else {
            self.user = try? SupabaseUser(from: decoder)
        }
    }

    public init(
        accessToken: String?,
        refreshToken: String?,
        expiresIn: Int? = nil,
        tokenType: String? = nil,
        user: SupabaseUser? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.tokenType = tokenType
        self.user = user
    }
}

public struct SupabaseUser: Decodable, Sendable {
    public let id: String
    public let email: String?
    public let userMetadata: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case userMetadata = "user_metadata"
    }

    public init(id: String, email: String? = nil, userMetadata: [String: AnyCodable]? = nil) {
        self.id = id
        self.email = email
        self.userMetadata = userMetadata
    }
}

/// Result of an email sign up operation.
public enum SignUpResult: Equatable, Sendable {
    case authenticated(SessionSnapshot)
    case verificationRequired(email: String)
}

/// Helper for flexible decoding of user_metadata dictionary.
public struct AnyCodable: Decodable, Sendable {
    public let stringValue: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            stringValue = s
        } else if let b = try? container.decode(Bool.self) {
            stringValue = String(b)
        } else if let i = try? container.decode(Int.self) {
            stringValue = String(i)
        } else {
            stringValue = nil
        }
    }

    public init(stringValue: String?) {
        self.stringValue = stringValue
    }
}

/// Directly integrates with Supabase GoTrue Auth service for Click.
public actor SupabaseAuthService {
    public let baseURL: URL
    public let anonKey: String
    private let session: URLSession

    public init(
        baseURL: URL = AppConfig.shared.supabaseURL,
        anonKey: String = AppConfig.shared.supabaseAnonKey,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.session = session
    }

    /// Signs in with email and password via GoTrue password grant.
    public func signIn(email: String, password: String) async throws -> SessionSnapshot {
        let url = baseURL.appendingPathComponent("/auth/v1/token")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "password")]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": password
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let authResponse = try await execute(request)
        guard let token = authResponse.accessToken,
              let refresh = authResponse.refreshToken,
              let user = authResponse.user else {
            throw APIError.decoding
        }

        let expiresAt = authResponse.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        return SessionSnapshot(
            userId: user.id,
            jwt: token,
            refreshToken: refresh,
            expiresAt: expiresAt
        )
    }

    /// Signs up with email, password, and basic profile metadata.
    public func signUp(
        email: String,
        password: String,
        firstName: String,
        lastName: String,
        birthdayIso: String
    ) async throws -> SignUpResult {
        let url = baseURL.appendingPathComponent("/auth/v1/signup")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullName = [f, l].filter { !$0.isEmpty }.joined(separator: " ")

        let payload: [String: Any] = [
            "email": cleanEmail,
            "password": password,
            "data": [
                "first_name": f,
                "last_name": l,
                "birthday": birthdayIso,
                "full_name": fullName,
                "name": fullName
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let authResponse = try await execute(request)

        if let token = authResponse.accessToken,
           let refresh = authResponse.refreshToken,
           let user = authResponse.user {
            let expiresAt = authResponse.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
            let snapshot = SessionSnapshot(
                userId: user.id,
                jwt: token,
                refreshToken: refresh,
                expiresAt: expiresAt
            )
            return .authenticated(snapshot)
        } else {
            return .verificationRequired(email: cleanEmail)
        }
    }

    /// Exchanges an Apple ID token for a Supabase session.
    public func signInWithApple(idToken: String, nonce: String? = nil) async throws -> SessionSnapshot {
        try await signInWithIdToken(provider: "apple", idToken: idToken, nonce: nonce)
    }

    /// Exchanges a Google ID token for a Supabase session.
    public func signInWithGoogle(idToken: String, nonce: String? = nil) async throws -> SessionSnapshot {
        try await signInWithIdToken(provider: "google", idToken: idToken, nonce: nonce)
    }

    /// Exchanges an ID token provider grant for a Supabase session.
    public func signInWithIdToken(provider: String, idToken: String, nonce: String? = nil) async throws -> SessionSnapshot {
        let url = baseURL.appendingPathComponent("/auth/v1/token")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "id_token")]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "provider": provider,
            "id_token": idToken
        ]
        if let nonce = nonce {
            payload["nonce"] = nonce
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let authResponse = try await execute(request)
        guard let token = authResponse.accessToken,
              let refresh = authResponse.refreshToken,
              let user = authResponse.user else {
            throw APIError.decoding
        }

        let expiresAt = authResponse.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        return SessionSnapshot(
            userId: user.id,
            jwt: token,
            refreshToken: refresh,
            expiresAt: expiresAt
        )
    }

    /// Refreshes an expired JWT using a valid refresh token.
    public func refreshToken(_ refreshToken: String) async throws -> SessionSnapshot {
        let url = baseURL.appendingPathComponent("/auth/v1/token")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = ["refresh_token": refreshToken]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let authResponse = try await execute(request)
        guard let token = authResponse.accessToken,
              let refresh = authResponse.refreshToken,
              let user = authResponse.user else {
            throw APIError.decoding
        }

        let expiresAt = authResponse.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        return SessionSnapshot(
            userId: user.id,
            jwt: token,
            refreshToken: refresh,
            expiresAt: expiresAt
        )
    }

    /// Signs out the active user session on the server.
    public func signOut(jwt: String) async {
        let url = baseURL.appendingPathComponent("/auth/v1/logout")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")

        _ = try? await session.data(for: request)
    }

    private func execute(_ request: URLRequest) async throws -> SupabaseAuthResponse {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.server(status: -1, code: nil, message: "Invalid network response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 400 || httpResponse.statusCode == 401 {
                // Parse error message
                let errObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let message = errObj?["msg"] as? String ?? errObj?["error_description"] as? String ?? errObj?["error"] as? String ?? "Invalid credentials"
                throw APIError.validation(code: String(httpResponse.statusCode), message: message)
            }
            throw APIError.server(status: httpResponse.statusCode, code: nil, message: "Authentication failed")
        }

        do {
            return try JSONDecoder().decode(SupabaseAuthResponse.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }
}
