import Foundation
import os

/// Unified logging (visible in Xcode and Console.app in Release builds too). Never log message
/// plaintext, tokens, or private attachment URLs (spec §87.3): paths, statuses and error classes.
enum ClickLog {
    static let net = Logger(subsystem: "click.net", category: "api")
    static let auth = Logger(subsystem: "click.net", category: "auth")
    static let realtime = Logger(subsystem: "click.net", category: "realtime")
    static let store = Logger(subsystem: "click.store", category: "local")

    /// A short, whitespace-collapsed excerpt of a response body for decode failures.
    static func excerpt(_ data: Data, limit: Int = 200) -> String {
        let text = String(decoding: data.prefix(limit * 2), as: UTF8.self)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(text.prefix(limit))
    }
}
