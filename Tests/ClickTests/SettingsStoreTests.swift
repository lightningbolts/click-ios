import Testing
import Foundation
@testable import Click

@Suite("Settings Store Preferences Tests")
@MainActor
struct SettingsStoreTests {
    let testSuite = "test_click_auth_prefs_\(UUID().uuidString)"

    @Test("Reads and updates preferences within suite")
    func readAndWritePreferences() {
        let store = SettingsStore(suiteName: testSuite)

        #expect(store.freeThisWeek == false)
        store.freeThisWeek = true
        #expect(store.freeThisWeek == true)

        #expect(store.messageNotificationsEnabled == true)
        store.messageNotificationsEnabled = false
        #expect(store.messageNotificationsEnabled == false)

        store.onboardingState = "step_avatar"
        #expect(store.onboardingState == "step_avatar")

        store.resetSessionScopedData()
        #expect(store.onboardingState == nil)
        #expect(store.freeThisWeek == true) // Preserved across session reset

        UserDefaults.standard.removePersistentDomain(forName: testSuite)
    }
    @Test("Persists native onboarding state per user")
    func perUserOnboardingState() {
        let store = SettingsStore(suiteName: testSuite)
        let userId = "user_123"
        let state = OnboardingState(
            welcomeSeen: true,
            interestsCompleted: true,
            personalityCompleted: false,
            avatarSetOrSkipped: true,
            priorConnectionsSetOrSkipped: false
        )

        store.saveOnboardingState(state, for: userId)
        #expect(store.onboardingState(for: userId) == state)

        store.clearOnboardingState(for: userId)
        #expect(store.onboardingState(for: userId) == nil)
    }

}
