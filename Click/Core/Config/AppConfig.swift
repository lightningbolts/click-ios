import Foundation

/// Centralized typed application configuration loaded from generated Info.plist / xcconfig.
public struct AppConfig: Sendable {
    public static let shared = AppConfig()

    public let apiBaseURL: URL
    public let supabaseURL: URL
    public let supabaseAnonKey: String

    public init(bundle: Bundle = .main) {
        self.apiBaseURL = Self.urlValue(
            key: "CLICK_API_BASE_URL",
            bundle: bundle,
            fallback: URL(string: "https://joinclick.co")!
        )
        self.supabaseURL = Self.urlValue(
            key: "SUPABASE_URL",
            bundle: bundle,
            fallback: URL(string: "https://lrgcwnmcscimkmslihxp.supabase.co")!
        )

        guard let key = Self.resolvedValue(key: "SUPABASE_ANON_KEY", bundle: bundle),
              key.count > 20 else {
            preconditionFailure(
                "Missing SUPABASE_ANON_KEY. Copy Config/Secrets.example.xcconfig to " +
                "Config/Secrets.xcconfig and provide the public Supabase anon key."
            )
        }
        self.supabaseAnonKey = key
    }

    public init(apiBaseURL: URL, supabaseURL: URL, supabaseAnonKey: String) {
        precondition(!supabaseAnonKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        self.apiBaseURL = apiBaseURL
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
    }

    private static func resolvedValue(key: String, bundle: Bundle) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.contains("$("),
              value.lowercased() != "placeholder" else {
            return nil
        }
        return value
    }

    private static func urlValue(key: String, bundle: Bundle, fallback: URL) -> URL {
        guard let raw = resolvedValue(key: key, bundle: bundle),
              let url = URL(string: raw),
              let scheme = url.scheme,
              scheme == "https" || scheme == "http" else {
            return fallback
        }
        return url
    }
}
