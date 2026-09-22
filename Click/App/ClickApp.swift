import SwiftUI

@main
struct ClickApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootGateView()
                .environment(environment)
                .task {
                    await environment.bootstrap()
                }
                .onOpenURL { url in
                    environment.router.handleIncomingURL(
                        url,
                        isAuthenticated: environment.session.currentSession != nil
                    )
                }
        }
    }
}
