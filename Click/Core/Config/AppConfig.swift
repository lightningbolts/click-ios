import Foundation

/// Centralized typed application configuration loaded from build-time generated Info.plist / xcconfig.
public struct AppConfig: Sendable {
    public static let shared = AppConfig()

    public let apiBaseURL: URL
    public let supabaseURL: URL
    public let supabaseAnonKey: String

    public init(bundle: Bundle = .main) {
        // 1. API Base URL
        if let rawAPI = bundle.object(forInfoDictionaryKey: "CLICK_API_BASE_URL") as? String,
           !rawAPI.isEmpty,
           let url = URL(string: rawAPI) {
            self.apiBaseURL = url
        } else {
            self.apiBaseURL = URL(string: "https://joinclick.co")!
        }

        // 2. Supabase URL
        if let rawSupa = bundle.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
           !rawSupa.isEmpty,
           let url = URL(string: rawSupa) {
            self.supabaseURL = url
        } else {
            self.supabaseURL = URL(string: "https://lrgcwnmcscimkmslihxp.supabase.co")!
        }

        // 3. Supabase Anon Key
        if let rawKey = bundle.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
           !rawKey.isEmpty,
           rawKey != "placeholder" {
            self.supabaseAnonKey = rawKey
        } else {
            self.supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxyZ2N3bm1jc2NpbWttc2xpaHhwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjA1MTgwNDksImV4cCI6MjA3NjA5NDA0OX0.-_LAhv-gUeCvViwTt8QZwM13U7jMIgTbiMZDkFf-oXk"
        }
    }

    public init(
        apiBaseURL: URL,
        supabaseURL: URL,
        supabaseAnonKey: String
    ) {
        self.apiBaseURL = apiBaseURL
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
    }
}
