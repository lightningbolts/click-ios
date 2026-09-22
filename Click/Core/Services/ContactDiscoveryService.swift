import Foundation
import Contacts
import CryptoKit

public struct DiscoveredContactCard: Identifiable, Equatable, Sendable, Decodable {
    public let id: String
    public let name: String
    public let avatarUrl: String?
    public let tags: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case avatarUrl = "avatar_url"
        case tags
    }

    public init(id: String, name: String, avatarUrl: String? = nil, tags: [String] = []) {
        self.id = id
        self.name = name
        self.avatarUrl = avatarUrl
        self.tags = tags
    }
}

public struct DiscoverContactsResponse: Decodable, Sendable {
    public let matches: [DiscoveredContactCard]
}

/// Service that performs privacy-preserving on-device contact hashing and server matching.
public final class ContactDiscoveryService: Sendable {
    public static let shared = ContactDiscoveryService()

    public static let maxDiscoverHashes = 1000

    public init() {}

    /// Normalizes email according to Click canonical rules.
    public static func normalizeEmail(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count >= 3, trimmed.contains("@") else { return nil }
        return trimmed
    }

    /// Normalizes phone number to E.164-style according to Click canonical rules.
    public static func normalizePhoneE164(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter { $0.isNumber }
        guard digits.count >= 10 else { return nil }

        if trimmed.hasPrefix("+") {
            return "+\(digits)"
        }
        if digits.count == 10 {
            return "+1\(digits)"
        }
        if digits.count == 11, digits.hasPrefix("1") {
            return "+\(digits)"
        }
        return "+\(digits)"
    }

    /// Computes lowercase SHA-256 hex digest of a UTF-8 string.
    public static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Reads contacts from device, normalizes, hashes, and discards raw contacts immediately.
    public func collectAndHashDeviceContacts() async throws -> [String] {
        let store = CNContactStore()
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]

        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        var hashes = Set<String>()

        try store.enumerateContacts(with: request) { contact, _ in
            // Collect and normalize phone numbers
            for phone in contact.phoneNumbers {
                let rawNumber = phone.value.stringValue
                if let normalized = Self.normalizePhoneE164(rawNumber) {
                    hashes.insert(Self.sha256Hex(normalized))
                }
            }

            // Collect and normalize emails
            for email in contact.emailAddresses {
                let rawEmail = email.value as String
                if let normalized = Self.normalizeEmail(rawEmail) {
                    hashes.insert(Self.sha256Hex(normalized))
                }
            }
        }

        return Array(hashes.prefix(Self.maxDiscoverHashes))
    }

    /// Matches contact hashes against Click backend users without ever uploading plaintext data.
    public func discoverMatches(hashes: [String], client: ClickAPIClient) async throws -> [DiscoveredContactCard] {
        guard !hashes.isEmpty else { return [] }

        let payload: [String: Any] = [
            "hashed_contacts": hashes
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)

        let request = APIRequest(
            path: "/api/contacts/discover",
            method: .post,
            body: body,
            requiresAuth: true
        )

        let response: DiscoverContactsResponse = try await client.execute(request)
        return response.matches
    }

    /// Sends a self-reported prior connection request for a discovered user.
    public func requestPriorConnection(targetUserId: String, contextTag: String? = nil, client: ClickAPIClient) async throws {
        var payload: [String: Any] = [
            "target_user_id": targetUserId
        ]
        if let context = contextTag, !context.isEmpty {
            payload["context_tag"] = context
        }

        let body = try JSONSerialization.data(withJSONObject: payload)
        let request = APIRequest(
            path: "/api/connections/prior/request",
            method: .post,
            body: body,
            requiresAuth: true
        )

        _ = try await client.executeRaw(request)
    }
}
