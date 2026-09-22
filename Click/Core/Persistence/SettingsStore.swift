import Foundation
import Observation

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
        static let messageNotificationsEnabled = "message_notifications_enabled"
        static let ambientNoiseOptIn = "ambient_noise_opt_in"
        static let barometricContextOptIn = "barometric_context_opt_in"
        static let locationExplainerSeen = "location_explainer_seen"
        static let onboardingState = "onboarding_state"
        static let hasCompletedOnboarding = "has_completed_onboarding"
        static let legacyMigrationCompleted = "legacy_kmp_migration_completed"
    }

    public init(suiteName: String = SettingsStore.suiteName) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    public var freeThisWeek: Bool {
        get { defaults.bool(forKey: Key.freeThisWeek) }
        set { defaults.set(newValue, forKey: Key.freeThisWeek) }
    }

    public var tagsInitialized: Bool {
        get { defaults.bool(forKey: Key.tagsInitialized) }
        set { defaults.set(newValue, forKey: Key.tagsInitialized) }
    }

    public var darkModeEnabled: Bool {
        get { defaults.bool(forKey: Key.darkModeEnabled) }
        set { defaults.set(newValue, forKey: Key.darkModeEnabled) }
    }

    public var messageNotificationsEnabled: Bool {
        get { defaults.object(forKey: Key.messageNotificationsEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.messageNotificationsEnabled) }
    }

    public var ambientNoiseOptIn: Bool {
        get { defaults.bool(forKey: Key.ambientNoiseOptIn) }
        set { defaults.set(newValue, forKey: Key.ambientNoiseOptIn) }
    }

    public var barometricContextOptIn: Bool {
        get { defaults.bool(forKey: Key.barometricContextOptIn) }
        set { defaults.set(newValue, forKey: Key.barometricContextOptIn) }
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

    /// Resets non-durable session preferences while preserving account independent settings.
    public func resetSessionScopedData() {
        defaults.removeObject(forKey: Key.onboardingState)
        defaults.removeObject(forKey: Key.hasCompletedOnboarding)
    }
}
