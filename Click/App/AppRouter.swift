import Foundation
import Observation

/// The five authoritative main tab root destinations.
public enum MainTab: String, CaseIterable, Hashable, Sendable {
    case home
    case addClick = "add_click"
    case connections
    case map
    case settings // User-facing label: Me
}

/// Typed destination routes for the application.
/// Typed destination routes for the application.
public enum AppRoute: Hashable, Sendable {
    case chat(chatID: String)
    case userProfile(userID: String, connectionID: String?)
    case groupProfile(chatID: String)
    case event(beaconID: String)
    case beacon(beaconID: String)
    case hub(hubID: String)
    case myQR
    case scanQR
    case tapConnect
    case savedEvents
    case connectionInvocation(ConnectionInvocation)
}

/// Invocation payload for canonical connection flow initiated via deep link / QR scan.
public struct ConnectionInvocation: Hashable, Sendable {
    public let userID: String
    public let token: String?
    public let expiresAt: Date?
    public let issuedAt: Date?
    public let venueID: String?

    public init(
        userID: String,
        token: String? = nil,
        expiresAt: Date? = nil,
        issuedAt: Date? = nil,
        venueID: String? = nil
    ) {
        self.userID = userID
        self.token = token
        self.expiresAt = expiresAt
        self.issuedAt = issuedAt
        self.venueID = venueID
    }
}

/// Coordinates navigation stacks, modal presentations, and deep-link routing.
@Observable
@MainActor
public final class AppRouter {
    public var selectedTab: MainTab = .home

    // Navigation stacks for each tab root
    public var homePath: [AppRoute] = []
    public var addClickPath: [AppRoute] = []
    public var connectionsPath: [AppRoute] = []
    public var mapPath: [AppRoute] = []
    public var settingsPath: [AppRoute] = []

    /// Pending destination queued while waiting for auth/onboarding gating resolution.
    public var pendingRoute: AppRoute?

    public init() {}

    /// Navigates to a typed route within the active tab's stack.
    public func navigate(to route: AppRoute) {
        switch selectedTab {
        case .home:
            homePath.append(route)
        case .addClick:
            addClickPath.append(route)
        case .connections:
            connectionsPath.append(route)
        case .map:
            mapPath.append(route)
        case .settings:
            settingsPath.append(route)
        }
    }

    /// Selects a main tab and resets its path to root if re-selected.
    public func selectTab(_ tab: MainTab) {
        if selectedTab == tab {
            resetCurrentTabPath()
        } else {
            selectedTab = tab
        }
    }

    /// Resets the current tab stack to its root view.
    public func resetCurrentTabPath() {
        switch selectedTab {
        case .home:
            homePath.removeAll()
        case .addClick:
            addClickPath.removeAll()
        case .connections:
            connectionsPath.removeAll()
        case .map:
            mapPath.removeAll()
        case .settings:
            settingsPath.removeAll()
        }
    }

    /// Parses incoming URLs (universal links and custom `click://` scheme) into typed routes.
    public func parseIncomingURL(_ url: URL) -> AppRoute? {
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased()
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: true)

        // Ignore auth callbacks from product deep-link parsing
        if host == "login" || host == "auth" {
            return nil
        }

        // 1. Custom URL Scheme: click://...
        if scheme == "click" {
            // click://c/{uuid} or click://connect/{uuid} -> canonical connection handshake
            if host == "c" || host == "connect", let id = pathComponents.first {
                let invocation = parseConnectionInvocation(userID: id, components: components)
                return .connectionInvocation(invocation)
            }
            // click://e/{beaconId}
            if host == "e", let beaconId = pathComponents.first {
                return .event(beaconID: beaconId)
            }
            // click://hub/{hubId}
            if host == "hub", let hubId = pathComponents.first {
                return .hub(hubID: hubId)
            }
            // Direct host commands
            if host == "myqr" { return .myQR }
            if host == "scan" { return .scanQR }
            if host == "tap" { return .tapConnect }
        }

        // 2. Universal Links: https://joinclick.co/... or https://click-us.vercel.app/...
        if scheme == "https" || scheme == "http" {
            guard let first = pathComponents.first else { return nil }

            // /c/{uuid} or /connect/{uuid}
            if (first == "c" || first == "connect"), pathComponents.count > 1 {
                let id = pathComponents[1]
                let invocation = parseConnectionInvocation(userID: id, components: components)
                return .connectionInvocation(invocation)
            }
            // /e/{beaconId}
            if first == "e", pathComponents.count > 1 {
                return .event(beaconID: pathComponents[1])
            }
            // /hub/{hubId}
            if first == "hub", pathComponents.count > 1 {
                return .hub(hubID: pathComponents[1])
            }
        }

        return nil
    }

    private func parseConnectionInvocation(userID: String, components: URLComponents?) -> ConnectionInvocation {
        let queryItems = components?.queryItems ?? []
        let tokenNames = Set(["token", "qr_token", "qt", "t"])
        let token = queryItems.first(where: { tokenNames.contains($0.name.lowercased()) })?.value
        let venueID = queryItems.first(where: { $0.name.lowercased() == "venue_id" })?.value

        let expiresAt = queryItems
            .first(where: { $0.name.lowercased() == "expires_at" || $0.name.lowercased() == "exp" })
            .flatMap { parseTimestamp($0.value) }

        let issuedAt = queryItems
            .first(where: { $0.name.lowercased() == "issued_at" || $0.name.lowercased() == "iat" })
            .flatMap { parseTimestamp($0.value) }

        return ConnectionInvocation(
            userID: userID,
            token: token,
            expiresAt: expiresAt,
            issuedAt: issuedAt,
            venueID: venueID
        )
    }

    private func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let numeric = Double(raw) {
            let seconds = numeric > 10_000_000_000 ? numeric / 1000.0 : numeric
            return Date(timeIntervalSince1970: seconds)
        }
        return ISO8601DateFormatter().date(from: raw)
    }

    /// Enqueues or immediately presents an incoming URL destination.
    public func handleIncomingURL(_ url: URL, isAuthenticated: Bool) {
        guard let route = parseIncomingURL(url) else { return }

        if isAuthenticated {
            resolveRoute(route)
        } else {
            pendingRoute = route
        }
    }

    /// Resolves and executes a queued or active route.
    public func resolveRoute(_ route: AppRoute) {
        switch route {
        case .chat:
            selectedTab = .connections
            connectionsPath.append(route)
        case .userProfile:
            selectedTab = .connections
            connectionsPath.append(route)
        case .groupProfile:
            selectedTab = .connections
            connectionsPath.append(route)
        case .event, .beacon:
            selectedTab = .map
            mapPath.append(route)
        case .hub:
            selectedTab = .map
            mapPath.append(route)
        case .myQR, .scanQR, .tapConnect, .connectionInvocation:
            selectedTab = .addClick
            addClickPath.append(route)
        case .savedEvents:
            selectedTab = .settings
            settingsPath.append(route)
        }
    }

    /// Flushes any pending deep-link route after authentication succeeds.
    public func flushPendingRoute() {
        guard let route = pendingRoute else { return }
        pendingRoute = nil
        resolveRoute(route)
    }
}
