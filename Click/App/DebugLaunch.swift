import Foundation

/// Design/preview launch arguments (`-preview-*`). They seed mock sessions and fixture data, so
/// they are honored only in DEBUG builds; release builds always take the real session path.
enum DebugLaunch {
    static func has(_ flag: String) -> Bool {
        #if DEBUG
        CommandLine.arguments.contains(flag)
        #else
        false
        #endif
    }

    static func hasPrefix(_ prefix: String) -> Bool {
        #if DEBUG
        CommandLine.arguments.contains { $0.hasPrefix(prefix) }
        #else
        false
        #endif
    }
}
