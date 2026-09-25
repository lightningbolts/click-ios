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

@Suite("Encounter sensors")
struct EncounterSensorTests {
    @Test("Noise tiers match KMP thresholds and enum names")
    func noiseTiers() {
        #expect(EncounterSensorSampler.noiseLevel(decibels: 34.9) == "VERY_QUIET")
        #expect(EncounterSensorSampler.noiseLevel(decibels: 35) == "QUIET")
        #expect(EncounterSensorSampler.noiseLevel(decibels: 74.9) == "MODERATE")
        #expect(EncounterSensorSampler.noiseLevel(decibels: 89.9) == "LOUD")
        #expect(EncounterSensorSampler.noiseLevel(decibels: 90) == "VERY_LOUD")
    }

    @Test("dB approximation is average power + 90, clamped")
    func approximation() {
        #expect(EncounterSensorSampler.approximateDecibels(averagePower: -40) == 50)
        #expect(EncounterSensorSampler.approximateDecibels(averagePower: -160) == 0)
        #expect(EncounterSensorSampler.approximateDecibels(averagePower: 20) == 100)
    }

    @Test("Handshake body carries opted-in sensor fields with KMP keys")
    func handshakeBody() {
        var evidence = ProximityEvidence(myToken: "t", heardTokens: [], detectedDevices: [], latitude: nil, longitude: nil, simulatorMock: false)
        #expect(evidence.body["exact_barometric_elevation_m"] == nil)
        evidence.sensor = EncounterSensorContext(noiseLevel: "QUIET", noiseDecibels: 40, barometricElevationMeters: 12.5)
        #expect(evidence.body["exact_barometric_elevation_m"] as? Double == 12.5)
        #expect(evidence.body["noise_level"] as? String == "QUIET")
        #expect(evidence.body["exact_noise_level_db"] as? Double == 40)
    }

    @Test("Handshake body carries the connect-time hardware snapshot with encounter column keys")
    func handshakeHardwareBody() {
        var evidence = ProximityEvidence(myToken: "t", heardTokens: [], detectedDevices: [], latitude: nil, longitude: nil, simulatorMock: false)
        evidence.sensor = EncounterSensorContext(luxLevel: 600, motionVariance: 0.04, compassAzimuth: 114.9, batteryLevel: 56)
        #expect(evidence.body["lux_level"] as? Double == 600)
        #expect(evidence.body["motion_variance"] as? Double == 0.04)
        #expect(evidence.body["compass_azimuth"] as? Double == 114.9)
        #expect(evidence.body["battery_level"] as? Int == 56)
        #expect(evidence.body["my_token"] as? String == "t")
        #expect(!evidence.sensor.isEmpty)
        #expect(EncounterSensorContext().isEmpty)
    }

    @Test("Motion variance is the population variance, nil below three samples")
    func motionVariance() {
        #expect(HardwareVibeSampler.variance([1, 2]) == nil)
        #expect(HardwareVibeSampler.variance([2, 4, 4, 4, 5, 5, 7, 9]) == 4)
    }

    @Test("Nested JSON strings decode and the no-location placeholder is dropped")
    func legacyEncounterFields() {
        let doubleEncoded = "\"{\\\"condition\\\":\\\"Clear\\\",\\\"temperatureCelsius\\\":26.3}\""
        #expect(JSONFields.dictionary(doubleEncoded)?["condition"] as? String == "Clear")
        #expect(JSONFields.dictionary("{\"condition\":\"Sunny\"}")?["condition"] as? String == "Sunny")
        #expect(JSONFields.dictionary("\"plain\"") == nil)
        #expect(JSONFields.place("A new city") == nil)
        #expect(JSONFields.place("Seattle, Washington") == "Seattle, Washington")
    }
}
