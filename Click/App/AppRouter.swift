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

/// Stable, identity-rich route for a direct conversation.
///
/// The route deliberately carries immutable identity needed to render the first frame.
/// Mutable conversation state is resolved by ConversationModel/ChatRepository at the destination.
public struct DirectChatRoute: Hashable, Sendable {
    public let chatID: String?
    public let connectionID: String?
    public let peerUserID: String
    public let peerDisplayName: String
    public let peerHandle: String
    public let peerAvatarURL: String?
    public let isOnline: Bool
    public let lastActiveText: String

    public init(
        chatID: String? = nil,
        connectionID: String? = nil,
        peerUserID: String,
        peerDisplayName: String,
        peerHandle: String = "",
        peerAvatarURL: String? = nil,
        isOnline: Bool = false,
        lastActiveText: String = ""
    ) {
        self.chatID = chatID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.connectionID = connectionID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.peerUserID = peerUserID
        self.peerDisplayName = peerDisplayName
        self.peerHandle = peerHandle
        self.peerAvatarURL = peerAvatarURL
        self.isOnline = isOnline
        self.lastActiveText = lastActiveText
    }

    /// A temporary identity used only until ChatRepository resolves the canonical chat UUID.
    public var conversationIdentity: ConversationIdentity {
        ConversationIdentity(
            chatID: chatID ?? connectionID ?? "",
            connectionID: connectionID,
            peerUserID: peerUserID,
            peerDisplayName: peerDisplayName,
            peerHandle: peerHandle,
            peerAvatarURL: peerAvatarURL,
            isOnline: isOnline,
            lastActiveText: lastActiveText
        )
    }
}

/// Identity needed to paint a verified group chat's first frame. Membership used for encryption
/// is re-read from the server by `ChatRepository` before any write.
public struct GroupChatRoute: Hashable, Sendable {
    public let chatID: String
    public let groupID: String
    public let name: String
    public let avatarURL: String?
    public let memberUserIDs: [String]

    public init(chatID: String, groupID: String, name: String, avatarURL: String? = nil, memberUserIDs: [String] = []) {
        self.chatID = chatID
        self.groupID = groupID
        self.name = name
        self.avatarURL = avatarURL
        self.memberUserIDs = memberUserIDs
    }

    public var conversationIdentity: ConversationIdentity {
        ConversationIdentity(
            chatID: chatID,
            peerUserID: "",
            peerDisplayName: name,
            peerAvatarURL: avatarURL,
            kind: .group(groupID: groupID),
            participantUserIDs: memberUserIDs
        )
    }
}

/// Typed destination routes for the application.
public enum AppRoute: Hashable, Sendable {
    case chat(DirectChatRoute)
    case userProfile(userID: String, connectionID: String?)
    /// Limited, view-only profile for someone the viewer hasn't Clicked with (event directory).
    case publicProfile(userID: String)
    case groupChat(GroupChatRoute)
    case groupProfile(chatID: String)
    case event(beaconID: String)
    /// Event chat, always resolved through the server's event-chat resolver.
    case eventChat(beaconID: String)
    /// Who's going to an event (the event's people directory).
    case eventPeople(beaconID: String)
    /// The host's guest list import for an event.
    case guestList(beaconID: String)
    case beacon(beaconID: String)
    case hub(hubID: String)
    case myQR
    case scanQR
    case tapConnect
    case savedEvents
    /// An event's Click Drops recap (spec F1).
    case eventRecap(beaconID: String)
    /// Everything you've been part of: events, beacons, hangouts, saved events (spec F2).
    case history
    case settings(SettingsRoute)
    case connectionInvocation(ConnectionInvocation)
    /// A conversation known only by its chat ID (search hits, `click://chat/{id}`), resolved
    /// against the inbox when opened, optionally focused on one message.
    case conversation(chatID: String, messageID: String?)

    /// The tab whose stack hosts this route when it arrives from outside the app
    /// (deep links, notifications) rather than from in-app navigation.
    public var canonicalTab: MainTab {
        switch self {
        case .chat, .userProfile, .publicProfile, .groupChat, .groupProfile, .conversation:
            .connections
        case .event, .eventChat, .eventPeople, .guestList, .beacon, .hub, .eventRecap:
            .map
        case .myQR, .scanQR, .tapConnect, .connectionInvocation:
            .addClick
        case .savedEvents, .settings, .history:
            .settings
        }
    }
}

/// A request to show global search, optionally pre-filled.
public struct SearchRequest: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let query: String
}

/// A route presented as a sheet.
public struct SheetRoute: Identifiable, Hashable, Sendable {
    public let route: AppRoute
    public var id: AppRoute { route }
}

extension AppRoute {
    /// Detail surfaces the contract presents as sheets rather than pushes.
    public var presentsAsSheet: Bool {
        switch self {
        case .event, .beacon: true
        default: false
        }
    }
}

/// Preference pages under the Me root. Typed so notifications/deep links can open them.
public enum SettingsRoute: Hashable, Sendable {
    case alerts
    case privacy
    case permissions
    case blocked
    case interests
    case personality
    case calendar
    case editProfile
}

/// What the Map root should bring into view when it is opened from elsewhere.
public enum MapFocus: Hashable, Sendable {
    case beacon(String)
    /// Centers the map on a beacon without selecting it (no detail reopens).
    case place(String)
    case hub(String)
    case layer(MapLayer)
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

private enum ScreenKey: Hashable {
    case conversation(String)
    case eventChat(String)
    case profile(String)
    case groupProfile(String)
    case route(AppRoute)

    /// The alias a direct conversation is known by through its peer (one chat per pair).
    static func peer(_ userID: String) -> String? { userID.isEmpty ? nil : "user:" + userID }
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

    /// A pending "show this on the map" intent, consumed by the Map root when it appears.
    public var mapFocus: MapFocus?

    /// Event and beacon details are sheets (medium/large) over whatever is on screen
    /// (interaction contract 3), owned by the shell — one modal owner.
    public var presentedSheet: SheetRoute? {
        didSet { if presentedSheet?.id != oldValue?.id { sheetPath = [] } }
    }
    /// Screens pushed inside the detail sheet (event chat, people, profiles).
    public var sheetPath: [AppRoute] = []

    /// The Map's Nearby sheet stack; nil while the sheet is closed.
    public var nearbyPath: [AppRoute]?

    /// The one global search surface. Every search control (Home, Clicks, Nearby, Map) opens
    /// this, presented by the shell, so results route identically everywhere.
    public var searchRequest: SearchRequest?
    /// Where to go once the search sheet has finished dismissing (never two surfaces at once).
    private var routeAfterSearch: AppRoute?

    public func presentSearch(query: String = "") {
        dismissSheets()
        searchRequest = SearchRequest(query: query)
    }

    /// Closes search, then opens `route` after the sheet is gone.
    public func openFromSearch(_ route: AppRoute) {
        routeAfterSearch = route
        searchRequest = nil
    }

    /// Called from the search sheet's `onDismiss`.
    public func searchDidDismiss() {
        guard let route = routeAfterSearch else { return }
        routeAfterSearch = nil
        navigate(to: route)
    }

    /// Beacons deleted this session; map, lists and Home drop them before the next refresh.
    public private(set) var deletedBeaconIDs: Set<String> = []

    public func noteBeaconDeleted(_ id: String) {
        deletedBeaconIDs.insert(id)
    }

    public init() {}

    /// Switches to the Map root and asks it to focus a beacon, hub, or layer ("View on Map").
    public func showOnMap(_ focus: MapFocus? = nil) {
        dismissSheets()
        mapFocus = focus
        mapPath.removeAll()
        selectedTab = .map
    }

    /// Navigates to a typed route. Every stack registers the canonical `AppRouteDestination`,
    /// so any route may be pushed onto any stack:
    /// - with a sheet open (Nearby, or an event/beacon detail), it pushes inside that sheet, so
    ///   whatever you came from stays one back-swipe away and nothing jumps behind the sheet;
    /// - otherwise details open as a sheet and everything else pushes onto the selected tab.
    ///
    /// A screen is never stacked twice: if the destination is already in the stack (chat →
    /// profile → "Message", or a push for the chat that's open), the stack pops back to it.
    public func navigate(to route: AppRoute) {
        queueMessageFocus(for: route)
        if nearbyPath != nil {
            nearbyPath = pushed(route, onto: nearbyPath ?? [])
        } else if presentedSheet != nil {
            sheetPath = pushed(route, onto: sheetPath)
        } else if route.presentsAsSheet {
            presentedSheet = SheetRoute(route: route)
        } else {
            self[path: selectedTab] = pushed(route, onto: self[path: selectedTab])
        }
    }

    /// Closes any open sheet (for arrivals from outside the app).
    public func dismissSheets() {
        presentedSheet = nil
        nearbyPath = nil
    }

    private func pushed(_ route: AppRoute, onto path: [AppRoute]) -> [AppRoute] {
        if let index = openIndex(of: route, in: path) { return Array(path[...index]) }
        return path + [route]
    }

    private func queueMessageFocus(for route: AppRoute) {
        if case let .conversation(chatID, messageID?) = route {
            pendingMessageFocus = MessageFocus(conversationIDs: [chatID], messageID: messageID)
        }
    }

    /// A message to scroll to when its conversation is next on screen (search, pins, plans).
    public var pendingMessageFocus: MessageFocus?

    /// Expands a conversation ID to every ID its live conversation is known by (chat,
    /// connection, hub), so routes naming one chat differently still match. Set by the environment.
    @ObservationIgnored var conversationAliases: (String) -> Set<String> = { [$0] }

    /// Where `route`'s screen already sits in `path`, if it does.
    private func openIndex(of route: AppRoute, in path: [AppRoute]) -> Int? {
        let keys = screenKeys(route)
        return path.lastIndex { !screenKeys($0).isDisjoint(with: keys) }
    }

    /// Which screen a route shows. A conversation is named by every ID it's known by (a chat
    /// arrives by chat, connection, peer or hub ID); a profile by its person.
    private func screenKeys(_ route: AppRoute) -> Set<ScreenKey> {
        let conversation = { (ids: [String?]) in
            Set(ids.compactMap { $0 }.flatMap(self.conversationAliases).filter { !$0.isEmpty }.map(ScreenKey.conversation))
        }
        switch route {
        case .chat(let chat): return conversation([chat.chatID, chat.connectionID, ScreenKey.peer(chat.peerUserID)])
        case .groupChat(let group): return conversation([group.chatID])
        case .conversation(let id, _), .hub(let id): return conversation([id])
        case .eventChat(let beaconID): return [.eventChat(beaconID)]
        case .userProfile(let userID, _), .publicProfile(let userID): return [.profile(userID)]
        case .groupProfile(let chatID): return [.groupProfile(chatID)]
        default: return [.route(route)]
        }
    }

    /// Handles a tab-bar selection. Re-selecting the active tab pops it to its root.
    public func selectTab(_ tab: MainTab) {
        if selectedTab == tab {
            resetCurrentTabPath()
        } else {
            selectedTab = tab
        }
    }

    /// Resets the current tab stack to its root view.
    public func resetCurrentTabPath() {
        self[path: selectedTab].removeAll()
    }

    /// The navigation path owned by a tab.
    public subscript(path tab: MainTab) -> [AppRoute] {
        get {
            switch tab {
            case .home: homePath
            case .addClick: addClickPath
            case .connections: connectionsPath
            case .map: mapPath
            case .settings: settingsPath
            }
        }
        set {
            switch tab {
            case .home: homePath = newValue
            case .addClick: addClickPath = newValue
            case .connections: connectionsPath = newValue
            case .map: mapPath = newValue
            case .settings: settingsPath = newValue
            }
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
            // click://chat/{chatId}?m={messageId}
            if host == "chat", let chatID = pathComponents.first {
                let messageID = components?.queryItems?.first { $0.name == "m" || $0.name == "message" }?.value
                return .conversation(chatID: chatID, messageID: messageID)
            }
            // click://profile/{userId}
            if host == "profile" || host == "u", let userID = pathComponents.first {
                return .publicProfile(userID: userID)
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
        let venueNames = Set(["venue_id", "venue"])
        let venueID = queryItems.first(where: { venueNames.contains($0.name.lowercased()) })?.value

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

    /// `click://search?q=…` and `https://…/search?q=…` open global search.
    public func searchQuery(from url: URL) -> String? {
        let scheme = url.scheme?.lowercased()
        let isSearch = (scheme == "click" && url.host?.lowercased() == "search")
            || ((scheme == "https" || scheme == "http") && url.pathComponents.filter { $0 != "/" }.first == "search")
        guard isSearch else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems?.first { $0.name == "q" }?.value ?? ""
    }

    /// Enqueues or immediately presents an incoming URL destination.
    public func handleIncomingURL(_ url: URL, isAuthenticated: Bool) {
        if let query = searchQuery(from: url) {
            if isAuthenticated { presentSearch(query: query) }
            return
        }
        guard let route = parseIncomingURL(url) else { return }

        if isAuthenticated {
            resolveRoute(route)
        } else {
            pendingRoute = route
        }
    }

    /// Resolves and executes a queued or active route on its canonical tab, or on the current
    /// tab when that screen is already open there (never a second copy elsewhere).
    public func resolveRoute(_ route: AppRoute) {
        dismissSheets()
        if openIndex(of: route, in: self[path: selectedTab]) == nil {
            selectedTab = route.canonicalTab
        }
        navigate(to: route)
    }

    /// Flushes any pending deep-link route after authentication succeeds.
    public func flushPendingRoute() {
        guard let route = pendingRoute else { return }
        pendingRoute = nil
        resolveRoute(route)
    }
}


private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
