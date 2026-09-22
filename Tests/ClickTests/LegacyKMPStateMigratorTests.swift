import Testing
import Foundation
@testable import Click

@Suite("Legacy KMP State Migrator Tests")
struct LegacyKMPStateMigratorTests {
    let migrator = LegacyKMPStateMigrator()

    @Test("Decodes valid legacy KMP session_v2 JSON fixture")
    func decodeValidLegacySession() throws {
        let json = """
        {
            "version": 2,
            "jwt": "header.payload.signature_xyz",
            "refreshToken": "refresh_token_abc_123",
            "expiresAt": 1726900000000,
            "tokenType": "bearer",
            "userId": "usr_99887766"
        }
        """.data(using: .utf8)!

        let session = try migrator.decodeSession(from: json)
        #expect(session.version == 2)
        #expect(session.jwt == "header.payload.signature_xyz")
        #expect(session.refreshToken == "refresh_token_abc_123")
        #expect(session.expiresAt == 1726900000000)
        #expect(session.tokenType == "bearer")
        #expect(session.userId == "usr_99887766")
    }

    @Test("Decodes legacy session with optional null fields")
    func decodeSessionWithNulls() throws {
        let json = """
        {
            "version": 2,
            "jwt": "jwt_minimal",
            "refreshToken": "refresh_minimal"
        }
        """.data(using: .utf8)!

        let session = try migrator.decodeSession(from: json)
        #expect(session.jwt == "jwt_minimal")
        #expect(session.refreshToken == "refresh_minimal")
        #expect(session.expiresAt == nil)
        #expect(session.userId == nil)
    }

    @Test("Rejects empty JWT token")
    func rejectEmptyJWT() {
        let json = """
        {
            "version": 2,
            "jwt": "   ",
            "refreshToken": "valid_refresh"
        }
        """.data(using: .utf8)!

        #expect(throws: LegacyKMPStateMigrator.MigrationError.emptyJWT) {
            try migrator.decodeSession(from: json)
        }
    }

    @Test("Rejects empty refresh token")
    func rejectEmptyRefreshToken() {
        let json = """
        {
            "version": 2,
            "jwt": "valid_jwt",
            "refreshToken": ""
        }
        """.data(using: .utf8)!

        #expect(throws: LegacyKMPStateMigrator.MigrationError.emptyRefreshToken) {
            try migrator.decodeSession(from: json)
        }
    }

    @Test("Rejects unsupported version")
    func rejectUnsupportedVersion() {
        let json = """
        {
            "version": 3,
            "jwt": "valid_jwt",
            "refreshToken": "valid_refresh"
        }
        """.data(using: .utf8)!

        #expect(throws: LegacyKMPStateMigrator.MigrationError.unsupportedVersion(3)) {
            try migrator.decodeSession(from: json)
        }
    }

    @Test("Extracts sub UUID claim from valid JWT payload")
    func extractSubClaimFromValidJWT() {
        // payload: {"sub":"456e4567-e89b-12d3-a456-426614174000","exp":1750000000}
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiI0NTZlNDU2Ny1lODliLTEyZDMtYTQ1Ni00MjY2MTQxNzQwMDAiLCJleHAiOjE3NTAwMDAwMDB9.sig"
        let sub = LegacyKMPStateMigrator.extractSubFromJWT(jwt)
        #expect(sub == "456e4567-e89b-12d3-a456-426614174000")
    }

    @Test("Returns nil for malformed or missing sub claim in JWT")
    func extractSubFromMalformedJWT() {
        // Missing parts
        #expect(LegacyKMPStateMigrator.extractSubFromJWT("not-a-jwt") == nil)

        // Invalid base64
        #expect(LegacyKMPStateMigrator.extractSubFromJWT("header.???invalidbase64???.sig") == nil)

        // Valid JSON payload without 'sub'
        // payload: {"role":"authenticated"} -> eyJyb2xlIjoiYXV0aGVudGljYXRlZCJ9
        let jwtWithoutSub = "eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoiYXV0aGVudGljYXRlZCJ9.sig"
        #expect(LegacyKMPStateMigrator.extractSubFromJWT(jwtWithoutSub) == nil)
    }

    @Test("Purges retired keys during full migration")
    @MainActor
    func fullMigrationPurgesRetiredKeys() {
        let legacyDefaults = UserDefaults(suiteName: LegacyKMPStateMigrator.legacySuiteName) ?? .standard
        legacyDefaults.set(true, forKey: "call_notifications_enabled")
        legacyDefaults.set("grid", forKey: "home_layout_mode")

        let settings = SettingsStore(suiteName: "test_settings_\(UUID().uuidString)")
        settings.legacyMigrationCompleted = false

        migrator.performFullMigration(settings: settings)

        #expect(legacyDefaults.object(forKey: "call_notifications_enabled") == nil)
        #expect(legacyDefaults.object(forKey: "home_layout_mode") == nil)
        #expect(settings.legacyMigrationCompleted == true)
    }
}

