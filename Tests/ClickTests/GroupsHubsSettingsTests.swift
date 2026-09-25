import Foundation
import Testing
@testable import Click

@Suite("Groups, hubs and settings")
struct GroupsHubsSettingsTests {
    @Test("Clique pre-check explains who a candidate hasn't Clicked with")
    func cliqueReason() {
        let pairs = [CliqueEligibility.key("x", "lena"): false, CliqueEligibility.key("x", "sam"): false,
                     CliqueEligibility.key("y", "lena"): true]
        let names = ["lena": "Lena", "sam": "Sam"]
        #expect(CliqueEligibility.reason(for: "x", selected: ["lena"], pairs: pairs, names: names) == "Hasn't Clicked with Lena")
        #expect(CliqueEligibility.reason(for: "x", selected: ["lena", "sam"], pairs: pairs, names: names) == "Hasn't Clicked with Lena and 1 more")
        #expect(CliqueEligibility.reason(for: "y", selected: ["lena"], pairs: pairs, names: names) == nil)
        // Unknown pairs stay selectable; the server re-validates on create.
        #expect(CliqueEligibility.reason(for: "z", selected: ["lena"], pairs: pairs, names: names) == nil)
        #expect(CliqueEligibility.key("b", "a") == CliqueEligibility.key("a", "b"))
    }

    @Test("Appearance: saved mode wins, legacy toggle maps, new users follow the system")
    @MainActor
    func appearanceMigration() {
        #expect(SettingsStore.storedAppearance(mode: "dark", legacyDarkMode: false) == .dark)
        #expect(SettingsStore.storedAppearance(mode: nil, legacyDarkMode: true) == .dark)
        #expect(SettingsStore.storedAppearance(mode: nil, legacyDarkMode: false) == .light)
        #expect(SettingsStore.storedAppearance(mode: nil, legacyDarkMode: nil) == .system)
        #expect(SettingsStore.storedAppearance(mode: "bogus", legacyDarkMode: nil) == .system)
    }

    @Test("Appearance writes keep the legacy KMP flag in step")
    @MainActor
    func appearanceWritesLegacy() {
        let suite = "appearance-test-\(UUID().uuidString)"
        let store = SettingsStore(suiteName: suite)
        store.appearance = .dark
        #expect(UserDefaults(suiteName: suite)?.bool(forKey: "dark_mode_enabled") == true)
        store.appearance = .system
        #expect(UserDefaults(suiteName: suite)?.bool(forKey: "dark_mode_enabled") == false)
        #expect(SettingsStore(suiteName: suite).appearance == .system)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    @Test("Hub category labels")
    func hubCategoryLabel() {
        #expect(HubInfoView.label("music") == "Music")
        #expect(HubInfoView.label("Board games") == "Board Games")
    }
}
