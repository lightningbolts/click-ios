import Foundation
import Observation

/// The activity inbox for the signed-in user, shared by the Home bell and the Activity screen.
/// The shell loads it at launch (cached page first), so the bell's dot is right before Home
/// paints and opening the inbox never waits on the network.
@Observable
@MainActor
final class ActivityStore {
    private(set) var feed = ModuleState<ActivityPage>()
    /// The last "load more" failed: the list offers Retry instead of a spinner.
    private(set) var moreFailed = false
    /// Moves forward the moment the inbox is opened (the server is told in the background).
    private(set) var seenAt: Date?

    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private var userID: String?
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    /// A forced refresh asked for while one was running (e.g. a push just landed): read once more.
    @ObservationIgnored private var rerun = false
    @ObservationIgnored private var loadingMore = false
    /// Bumped by every first-page load, so an older "load more" never lands on a newer list.
    @ObservationIgnored private var generation = 0

    /// A first page younger than this is reused as-is when the inbox opens.
    nonisolated static let freshFor: TimeInterval = 30

    var items: [ActivityItem] { feed.value?.items ?? [] }

    func isNew(_ item: ActivityItem) -> Bool {
        Self.isNewer(item.createdAt, than: seenAt)
    }

    /// Newer than a seen mark (everything is, before the first visit). Compared at millisecond
    /// precision: the mark round-trips through JavaScript, which drops Postgres's microseconds.
    nonisolated static func isNewer(_ date: Date, than mark: Date?) -> Bool {
        guard let mark else { return true }
        return date.timeIntervalSince(mark) >= 0.001
    }

    /// Items are newest first, so the first one decides.
    var hasUnseen: Bool { items.first.map(isNew) ?? false }

    func attach(_ environment: AppEnvironment) {
        self.environment = environment
    }

    /// Switches to `userID` (never showing another account's inbox), paints the cached page,
    /// then reads the first page.
    func start(userID: String?) async {
        guard let environment, let userID else { return reset() }
        if self.userID != userID {
            reset()
            self.userID = userID
            let cached = await environment.activityRepository.cachedFirstPage(userID: userID)
            guard self.userID == userID else { return }
            feed.seed(cached)
            seenAt = cached?.seenAt
        }
        await refresh(force: true)
    }

    func reset() {
        feed = ModuleState()
        moreFailed = false
        seenAt = nil
        userID = nil
        fetchedAt = nil
        generation += 1
    }

    /// Reads the first page unless it's fresh (or `force`). Concurrent callers share one read.
    func refresh(force: Bool = false) async {
        if let inFlight {
            if force { rerun = true }
            return await inFlight.value
        }
        if !force, let fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.freshFor { return }
        let task = Task {
            repeat {
                rerun = false
                await loadFirstPage()
            } while rerun
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func loadFirstPage() async {
        guard let environment, let userID else { return }
        generation += 1
        feed.begin()
        do {
            let page = try await environment.activityRepository.page()
            guard self.userID == userID else { return }
            feed.succeed(page)
            fetchedAt = .now
            moreFailed = false
            // Never moves back: an open inbox may have marked newer items seen meanwhile.
            if let serverSeen = page.seenAt, serverSeen > (seenAt ?? .distantPast) { seenAt = serverSeen }
            AvatarView.prefetch(page.items.map { $0.actor?.avatarURL }, size: ActivityStore.avatarSize)
            await persist(environment, userID: userID)
        } catch {
            guard self.userID == userID else { return }
            feed.fail(error)
        }
    }

    /// Appends the next page, if there is one. A failure keeps the rows and marks `moreFailed`.
    func loadMore() async {
        guard !loadingMore, let environment, let userID, let cursor = feed.value?.nextBefore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let generation = generation
        do {
            let next = try await environment.activityRepository.page(before: cursor)
            guard generation == self.generation, self.userID == userID, var page = feed.value else { return }
            // A grouped item that moved to the top while paging is already on screen.
            let shown = Set(page.items.map(\.id))
            page.items += next.items.filter { !shown.contains($0.id) }
            page.nextBefore = next.nextBefore
            feed.succeed(page)
            moreFailed = false
        } catch {
            if generation == self.generation, !error.isCancellation { moreFailed = true }
        }
    }

    /// Everything loaded is now seen: the dot clears at once and the server is told.
    func markSeen() {
        guard let environment, let userID, let newest = items.first, isNew(newest) else { return }
        seenAt = newest.createdAt
        Task {
            await persist(environment, userID: userID)
            try? await environment.activityRepository.markSeen(newest.createdAtRaw)
        }
    }

    /// Saves what the next launch paints first: the newest items and the local seen mark.
    private func persist(_ environment: AppEnvironment, userID: String) async {
        guard self.userID == userID, var page = feed.value else { return }
        if page.items.count > Self.cachedItemLimit {
            page.items = Array(page.items.prefix(Self.cachedItemLimit))
            page.nextBefore = page.items.last?.createdAtRaw
        }
        page.seenAt = seenAt
        await environment.activityRepository.saveFirstPage(page, userID: userID)
    }

    nonisolated static let cachedItemLimit = 40

    nonisolated static let avatarSize: CGFloat = 44
}
