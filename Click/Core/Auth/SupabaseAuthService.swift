import Foundation

/// DTO representing Supabase Auth session response.
public struct SupabaseAuthResponse: Decodable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresIn: Int?
    public let tokenType: String?
    public let user: SupabaseUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case user
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
}

/// Directly integrates with Supabase GoTrue Auth service for Click.
public actor SupabaseAuthService {
    public let baseURL: URL
    public let anonKey: String
    private let session: URLSession

    public static let defaultBaseURL = URL(string: "https://lrgcwnmcscimkmslihxp.supabase.co")!
    public static let defaultAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxyZ2N3bm1jc2NpbWttc2xpaHhwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjA1MTgwNDksImV4cCI6MjA3NjA5NDA0OX0.-_LAhv-gUeCvViwTt8QZwM13U7jMIgTbiMZDkFf-oXk"

    public init(
        baseURL: URL = SupabaseAuthService.defaultBaseURL,
        anonKey: String = SupabaseAuthService.defaultAnonKey,
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
        let expiresAt = authResponse.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }

        return SessionSnapshot(
            userId: authResponse.user.id,
            jwt: authResponse.accessToken,
            refreshToken: authResponse.refreshToken,
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
    ) async throws -> SessionSnapshot {
        let url = baseURL.appendingPathComponent("/auth/v1/signup")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let f = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullName = [f, l].filter { !$0.isEmpty }.joined(separator: " ")

        let payload: [String: Any] = [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
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
        let expiresAt = authResponse.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }

        return SessionSnapshot(
            userId: authResponse.user.id,
            jwt: authResponse.accessToken,
            refreshToken: authResponse.refreshToken,
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
        let expiresAt = authResponse.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }

        return SessionSnapshot(
            userId: authResponse.user.id,
            jwt: authResponse.accessToken,
            refreshToken: authResponse.refreshToken,
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
                let message = errObj?["msg"] as? String ?? errObj?["error_description"] as? String ?? "Invalid credentials"
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
