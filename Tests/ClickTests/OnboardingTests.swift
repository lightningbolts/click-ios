import Testing
import Foundation
import UIKit
@testable import Click


@Suite("Onboarding Coordinator & Taxonomy Tests")
struct OnboardingTests {

    @Test("OnboardingCoordinator step progression for brand new user")
    func coordinatorProgression() async throws {
        let coordinator = await MainActor.run {
            OnboardingCoordinator(
                userId: "test_new_user_\(UUID().uuidString)",
                initialState: OnboardingState(),
                userHasAvatar: { false },
                userDefaults: UserDefaults(suiteName: "test_onboarding_\(UUID().uuidString)")!
            )
        }

        await MainActor.run {
            #expect(coordinator.step == .welcome)
            #expect(coordinator.visibleStepIndex == 0)
            #expect(coordinator.canGoBack == false)

            // 1. Welcome -> Interests
            coordinator.onWelcomeAcknowledged()
            #expect(coordinator.step == .interests)
            #expect(coordinator.visibleStepIndex == 1)
            #expect(coordinator.canGoBack == true)

            // 2. Interests -> Personality
            coordinator.onInterestsSaved()
            #expect(coordinator.step == .personality)
            #expect(coordinator.visibleStepIndex == 2)
            #expect(coordinator.canGoBack == true)

            // 3. Personality -> Avatar
            coordinator.onPersonalitySaved()
            #expect(coordinator.step == .avatar)
            #expect(coordinator.visibleStepIndex == 3)
            #expect(coordinator.canGoBack == true)

            // 4. Avatar -> PriorConnections
            coordinator.onAvatarSetOrSkipped()
            #expect(coordinator.step == .priorConnections)
            #expect(coordinator.visibleStepIndex == 4)
            #expect(coordinator.canGoBack == true)

            // 5. PriorConnections -> Complete
            coordinator.onPriorConnectionsSetOrSkipped()
            #expect(coordinator.step == .complete)
            #expect(coordinator.needsOnboarding == false)
        }
    }

    @Test("Returning user with hydrated interests and avatar fast-forwards directly to complete")
    func returningUserFastForwards() async throws {
        let hydrated = OnboardingState.hydratedForReturningUser(hasInterests: true, hasAvatar: true)

        let coordinator = await MainActor.run {
            OnboardingCoordinator(
                userId: "test_returning_user",
                initialState: hydrated,
                userHasAvatar: { true }
            )
        }

        await MainActor.run {
            #expect(coordinator.step == .complete)
            #expect(coordinator.needsOnboarding == false)
        }
    }

    @Test("Back navigation transitions accurately through the sequence")
    func backNavigation() async throws {
        let coordinator = await MainActor.run {
            let coord = OnboardingCoordinator(
                userId: "test_back_user",
                initialState: OnboardingState(welcomeSeen: true, interestsCompleted: true, personalityCompleted: true),
                userHasAvatar: { false }
            )
            return coord
        }

        await MainActor.run {
            // Currently on avatar
            #expect(coordinator.step == .avatar)

            // Avatar -> Personality
            coordinator.goBack()
            #expect(coordinator.step == .personality)

            // Personality -> Interests
            coordinator.goBack()
            #expect(coordinator.step == .interests)

            // Interests -> Welcome
            coordinator.goBack()
            #expect(coordinator.step == .welcome)
            #expect(coordinator.canGoBack == false)
        }
    }

    @Test("Interests taxonomy contains canonical 21 categories with valid subcategories")
    func interestsTaxonomy() {
        #expect(kInterestCategories.count == 21)
        #expect(kInterestOnboardingMinTags == 5)

        for category in kInterestCategories {
            #expect(!category.emoji.isEmpty)
            #expect(!category.label.isEmpty)
            #expect(!category.subcategories.isEmpty, "Category \(category.label) must contain subcategories")
        }

        let predefined = predefinedInterestTags()
        #expect(predefined.contains("music"))
        #expect(predefined.contains("live shows"))
        #expect(predefined.contains("coffee"))
        #expect(predefined.contains("espresso"))
        #expect(predefined.contains("hiking"))
        #expect(predefined.contains("trail running"))

        let sampleInput = ["Music", "Live Shows", "NOT_A_TAG_12345", "Coffee"]
        let filtered = filterToPredefinedInterestTags(sampleInput)
        #expect(filtered == ["Music", "Live Shows", "Coffee"])
    }

    @Test("Personality taxonomy contains exactly 24 traits across 4 groups")
    func personalityTaxonomy() {
        #expect(kPersonalityTraitGroups.count == 4)
        #expect(kPersonalityTraits.count == 24)
        #expect(kPersonalityRequiredTagCount == 5)

        let groups = Set(kPersonalityTraitGroups.map { $0.title })
        #expect(groups.contains("Social"))
        #expect(groups.contains("Energy"))
        #expect(groups.contains("Mind"))
        #expect(groups.contains("Style"))

        let sample = ["outgoing", "WARM", "witty", "Outgoing", "invalid_trait"]
        let canonical = canonicalizePersonalityTags(sample)
        #expect(canonical == ["Outgoing", "Warm", "Witty"])
    }

    @Test("Contact normalization rules adhere to E.164 and lowercase trimmed email")
    func contactNormalizationRules() {
        // Phone numbers
        #expect(ContactDiscoveryService.normalizePhoneE164("(555) 234-5678") == "+15552345678")
        #expect(ContactDiscoveryService.normalizePhoneE164("+1 (555) 234-5678") == "+15552345678")
        #expect(ContactDiscoveryService.normalizePhoneE164("555.234.5678") == "+15552345678")
        #expect(ContactDiscoveryService.normalizePhoneE164("123") == nil) // Under 10 digits

        // Emails
        #expect(ContactDiscoveryService.normalizeEmail("  Alice@Example.COM  ") == "alice@example.com")
        #expect(ContactDiscoveryService.normalizeEmail("invalid-email") == nil)
    }

    @Test("SHA-256 produces standard lowercase hex digests")
    func sha256HexCalculation() {
        let emptyHash = ContactDiscoveryService.sha256Hex("")
        #expect(emptyHash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        let hash = ContactDiscoveryService.sha256Hex("+15552345678")
        #expect(hash.count == 64)
        #expect(hash == hash.lowercased())
    }

    @Test("AvatarService normalizes and compresses image data to within 2 MB")
    func avatarImageDownsampling() throws {
        let size = CGSize(width: 2000, height: 2000)
        let renderer = UIGraphicsImageRenderer(size: size)
        let testImage = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }

        let rawData = testImage.pngData()!
        let service = AvatarService.shared
        let preparedData = try service.prepareImageData(rawData)

        #expect(preparedData.count <= 2_000_000)
        let decoded = UIImage(data: preparedData)
        #expect(decoded != nil)
        #expect(decoded!.size.width <= 1200)
        #expect(decoded!.size.height <= 1200)
    }
    @Test("Production coordinator stays loading until reconciliation")
    func coordinatorDoesNotFlashWelcomeBeforeHydration() async {
        let suiteName = "test_onboarding_loading_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let coordinator = await MainActor.run {
            OnboardingCoordinator(
                userId: "returning_user",
                userHasAvatar: { false },
                userDefaults: defaults
            )
        }

        await MainActor.run {
            #expect(coordinator.step == .loading)
            #expect(coordinator.needsOnboarding == true)

            coordinator.hydrate(OnboardingState(), hasAvatar: false)
            #expect(coordinator.step == .welcome)
        }

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Onboarding completion is not persisted before Prior Connections")
    func completionIsNotPersistedEarly() async {
        let suiteName = "test_onboarding_completion_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let coordinator = await MainActor.run {
            OnboardingCoordinator(
                userId: "new_user",
                initialState: OnboardingState(),
                userHasAvatar: { false },
                userDefaults: defaults
            )
        }

        await MainActor.run {
            coordinator.onWelcomeAcknowledged()
            coordinator.onInterestsSaved()
            coordinator.onPersonalitySaved()
            coordinator.onAvatarSetOrSkipped()

            #expect(coordinator.step == .priorConnections)
            #expect(defaults.bool(forKey: "has_completed_onboarding") == false)

            coordinator.onPriorConnectionsSetOrSkipped()

            #expect(coordinator.step == .complete)
            #expect(defaults.bool(forKey: "has_completed_onboarding") == true)
        }

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Prior Connections known-since values match backend contract")
    func priorKnownSinceContract() {
        #expect(PriorKnownSince.childhood.rawValue == "childhood")
        #expect(PriorKnownSince.highSchool.rawValue == "high_school")
        #expect(PriorKnownSince.college.rawValue == "college")
        #expect(PriorKnownSince.thisYear.rawValue == "this_year")
        #expect(PriorKnownSince.unspecified.rawValue == "unspecified")
    }

}
