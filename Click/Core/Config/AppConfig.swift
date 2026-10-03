import Foundation

/// Centralized typed application configuration loaded from generated Info.plist / xcconfig.
public struct AppConfig: Sendable {
    public static let shared = AppConfig()

    public let apiBaseURL: URL
    public let supabaseURL: URL
    public let supabaseAnonKey: String
    /// KLIPY GIF API app key (`KLIPY_APP_KEY`); nil hides GIF search.
    public let klipyAppKey: String?
    /// The App Store listing (`CLICK_APP_STORE_URL`); nil until the app is live, which hides invites.
    public let appStoreURL: URL?

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

        // Do not crash the process when public runtime configuration is absent.
        // Test hosts and previews intentionally run without production credentials.
        // SupabaseAuthService reports a typed configuration error only when auth is used.
        self.supabaseAnonKey = Self.resolvedValue(key: "SUPABASE_ANON_KEY", bundle: bundle) ?? ""
        self.klipyAppKey = Self.resolvedValue(key: "KLIPY_APP_KEY", bundle: bundle)
        self.appStoreURL = Self.resolvedValue(key: "CLICK_APP_STORE_URL", bundle: bundle)
            .flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
    }

    public init(apiBaseURL: URL, supabaseURL: URL, supabaseAnonKey: String, klipyAppKey: String? = nil, appStoreURL: URL? = nil) {
        self.apiBaseURL = apiBaseURL
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
        self.klipyAppKey = klipyAppKey
        self.appStoreURL = appStoreURL
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
