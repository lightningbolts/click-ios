import Foundation
import Observation

/// The signed-in user's own profile, availability posts and saved events — one copy shared by
/// Home, Me, the settings editors and the availability sheet. An edit on any screen is visible
/// on every other screen immediately (no reload, no spinner), and repeated visits reuse fresh
/// data instead of refetching three endpoints on every appearance.
@Observable
@MainActor
final class SelfDataStore {
    private(set) var profile = ModuleState<SelfProfile>()
    private(set) var intents = ModuleState<[AvailabilityIntentPost]>()
    private(set) var savedEvents = ModuleState<[SavedEvent]>()

    private weak var environment: AppEnvironment?
    private var seededUserID: String?
    private var fetchedAt: [String: Date] = [:]
    private var inFlight: [String: Task<Void, Never>] = [:]

    /// Data younger than this is reused as-is on appearance.
    nonisolated static let freshFor: TimeInterval = 60

    func attach(_ environment: AppEnvironment) {
        self.environment = environment
    }

    private var userID: String? { environment?.session.currentSession?.userId }

    /// Paints cached values (disk) once per signed-in user.
    func seedIfNeeded() async {
        guard let environment, let userID, seededUserID != userID else { return }
        seededUserID = userID
        profile = ModuleState()
        intents = ModuleState()
        savedEvents = ModuleState()
        fetchedAt = [:]
        profile.seed(await environment.me.cachedSelfProfile(userID: userID))
        intents.seed(await environment.me.cachedIntents(userID: userID))
        savedEvents.seed(await environment.beacons.cachedBookmarks(userID: userID))
    }

    /// Refreshes whatever is stale (or everything with `force`); concurrent callers share work.
    func refresh(force: Bool = false) async {
        await seedIfNeeded()
        async let a: Void = loadProfile(force: force)
        async let b: Void = loadIntents(force: force)
        async let c: Void = loadSavedEvents(force: force)
        _ = await (a, b, c)
    }

    func loadProfile(force: Bool = false) async {
        await run("profile", force: force) { environment, userID in
            self.profile.begin()
            do {
                let fresh = try await Transport.refreshing { try await environment.me.selfProfile(userID: userID) }
                self.profile.succeed(fresh)
                if let free = fresh.isFreeCurrently { environment.settings.freeThisWeek = free }
            } catch {
                self.profile.fail(error)
                throw error
            }
        }
    }

    func loadIntents(force: Bool = false) async {
        await run("intents", force: force) { environment, userID in
            self.intents.begin()
            do {
                self.intents.succeed(try await Transport.refreshing { try await environment.me.availabilityIntents(userID: userID) })
            } catch {
                self.intents.fail(error)
                throw error
            }
        }
    }

    func loadSavedEvents(force: Bool = false) async {
        await run("saved", force: force) { environment, userID in
            self.savedEvents.begin()
            do {
                self.savedEvents.succeed(try await Transport.refreshing { try await environment.beacons.bookmarks(userID: userID) })
            } catch {
                self.savedEvents.fail(error)
                throw error
            }
        }
    }

    // MARK: Local edits (applied immediately, everywhere)

    /// An editor saved the profile: show the saved value on every screen right away.
    func apply(profile updated: SelfProfile) {
        profile.succeed(updated)
        fetchedAt["profile"] = .now
    }

    func apply(intents updated: [AvailabilityIntentPost]) {
        intents.succeed(updated)
        fetchedAt["intents"] = .now
    }

    func apply(savedEvents updated: [SavedEvent]) {
        savedEvents.succeed(updated)
        fetchedAt["saved"] = .now
    }

    // MARK: Private

    private func run(_ key: String, force: Bool, _ body: @escaping @MainActor (AppEnvironment, String) async throws -> Void) async {
        guard let environment, let userID else { return }
        if let running = inFlight[key] {
            await running.value
            return
        }
        if !force, let last = fetchedAt[key], Date().timeIntervalSince(last) < Self.freshFor { return }
        let task = Task { @MainActor in
            do {
                try await body(environment, userID)
                self.fetchedAt[key] = .now
            } catch {}
        }
        inFlight[key] = task
        await task.value
        inFlight[key] = nil
    }
}
