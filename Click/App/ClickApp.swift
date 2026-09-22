import SwiftUI

@main
struct ClickApp: App {
    @State private var environment = AppEnvironment()

    init() {
        ClickFonts.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootGateView()
                .environment(environment)
                .task {
                    if CommandLine.arguments.contains("-preview-profile-basics") {
                        environment.session.requireProfileBasics(userId: "usr_preview_99")
                    } else if CommandLine.arguments.contains("-preview-shell") {
                        environment.session.signIn(
                            snapshot: SessionSnapshot(
                                userId: "usr_preview_active",
                                jwt: "mock_jwt",
                                refreshToken: "mock_refresh"
                            )
                        )
                    } else if CommandLine.arguments.contains("-preview-signup") || CommandLine.arguments.contains("-preview-signin") {
                        await environment.session.signOut()
                    } else {
                        await environment.bootstrap()
                    }
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
