import Foundation
import Observation

/// The application's top-level dependency container.
@Observable
@MainActor
public final class AppEnvironment {
    public let session: SessionController
    public let router: AppRouter
    public let settings: SettingsStore
    public let api: ClickAPIClient

    public init(
        session: SessionController = SessionController(),
        router: AppRouter = AppRouter(),
        settings: SettingsStore = SettingsStore(),
        api: ClickAPIClient? = nil
    ) {
        self.session = session
        self.router = router
        self.settings = settings

        let baseURL = URL(string: "https://joinclick.co")!
        self.api = api ?? ClickAPIClient(baseURL: baseURL) { [weak session] in
            await session?.currentSession?.jwt
        }
    }

    /// Initializes and restores local app state.
    public func bootstrap() async {
        await session.restoreSession()
        if session.currentSession != nil {
            router.flushPendingRoute()
        }
    }
}
