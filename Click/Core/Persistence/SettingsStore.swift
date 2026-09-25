import Foundation
import Observation
import SwiftUI

/// Accesses and manages user preferences stored in the `click_auth_prefs` suite.
@Observable
@MainActor
public final class SettingsStore {
    public static let suiteName = "click_auth_prefs"

    private let defaults: UserDefaults

    // Preference keys matching legacy KMP TokenStorage.ios.kt
    private enum Key {
        static let freeThisWeek = "free_this_week"
        static let tagsInitialized = "tags_initialized"
        static let darkModeEnabled = "dark_mode_enabled"
        static let appearance = "appearance_mode"
        static let messageNotificationsEnabled = "message_notifications_enabled"
        static let ambientNoiseOptIn = "ambient_noise_opt_in"
        static let barometricContextOptIn = "barometric_context_opt_in"
        static let locationExplainerSeen = "location_explainer_seen"
        static let onboardingState = "onboarding_state"
        static let hasCompletedOnboarding = "has_completed_onboarding"
        static let legacyMigrationCompleted = "legacy_kmp_migration_completed"
    }

    public init(suiteName: String = SettingsStore.suiteName) {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.defaults = defaults
        self.freeThisWeek = defaults.bool(forKey: Key.freeThisWeek)
        self.appearance = Self.storedAppearance(
            mode: defaults.string(forKey: Key.appearance),
            legacyDarkMode: defaults.object(forKey: Key.darkModeEnabled) as? Bool
        )
        self.messageNotificationsEnabled = defaults.object(forKey: Key.messageNotificationsEnabled) as? Bool ?? true
        self.ambientNoiseOptIn = defaults.bool(forKey: Key.ambientNoiseOptIn)
        self.barometricContextOptIn = defaults.bool(forKey: Key.barometricContextOptIn)
    }

    // User-visible preferences are stored properties so SwiftUI observes changes; a computed
    // UserDefaults accessor never invalidates views (Dark mode would not apply live). Each
    // write-through keeps the legacy `click_auth_prefs` key current.

    /// Local cache of "Free currently". Server truth is `user_availability.is_free_this_week`.
    public var freeThisWeek: Bool {
        didSet { defaults.set(freeThisWeek, forKey: Key.freeThisWeek) }
    }

    /// System / Light / Dark. The legacy KMP `dark_mode_enabled` flag is kept in step.
    public var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            defaults.set(appearance == .dark, forKey: Key.darkModeEnabled)
        }
    }

    public enum Appearance: String, CaseIterable, Identifiable, Sendable {
        case system, light, dark
        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
    }

    /// A saved mode wins; otherwise an explicit legacy toggle maps to Dark/Light, and a user
    /// who never chose follows the system.
    nonisolated static func storedAppearance(mode: String?, legacyDarkMode: Bool?) -> Appearance {
        if let mode, let saved = Appearance(rawValue: mode) { return saved }
        switch legacyDarkMode {
        case true?: return .dark
        case false?: return .light
        case nil: return .system
        }
    }

    public var messageNotificationsEnabled: Bool {
        didSet { defaults.set(messageNotificationsEnabled, forKey: Key.messageNotificationsEnabled) }
    }

    /// Ambient sound enrichment opt-in (encounter context). Local, like the KMP build.
    public var ambientNoiseOptIn: Bool {
        didSet { defaults.set(ambientNoiseOptIn, forKey: Key.ambientNoiseOptIn) }
    }

    public var barometricContextOptIn: Bool {
        didSet { defaults.set(barometricContextOptIn, forKey: Key.barometricContextOptIn) }
    }

    public var tagsInitialized: Bool {
        get { defaults.bool(forKey: Key.tagsInitialized) }
        set { defaults.set(newValue, forKey: Key.tagsInitialized) }
    }

    public var locationExplainerSeen: Bool {
        get { defaults.bool(forKey: Key.locationExplainerSeen) }
        set { defaults.set(newValue, forKey: Key.locationExplainerSeen) }
    }

    public var onboardingState: String? {
        get { defaults.string(forKey: Key.onboardingState) }
        set { defaults.set(newValue, forKey: Key.onboardingState) }
    }

    public var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Key.hasCompletedOnboarding) }
    }

    public var legacyMigrationCompleted: Bool {
        get { defaults.bool(forKey: Key.legacyMigrationCompleted) }
        set { defaults.set(newValue, forKey: Key.legacyMigrationCompleted) }
    }

    private func nativeOnboardingKey(for userId: String) -> String {
        "click_onboarding_\(userId)"
    }

    public func onboardingState(for userId: String) -> OnboardingState? {
        guard let data = defaults.data(forKey: nativeOnboardingKey(for: userId)) else {
            return nil
        }
        return try? JSONDecoder().decode(OnboardingState.self, from: data)
    }

    public func saveOnboardingState(_ state: OnboardingState, for userId: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: nativeOnboardingKey(for: userId))
    }

    public func clearOnboardingState(for userId: String) {
        defaults.removeObject(forKey: nativeOnboardingKey(for: userId))
    }

    /// Resets non-durable session preferences while preserving account independent settings.
    public func resetSessionScopedData() {
        defaults.removeObject(forKey: Key.onboardingState)
        defaults.removeObject(forKey: Key.hasCompletedOnboarding)
    }
}

extension SettingsStore.Appearance {
    /// nil follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
