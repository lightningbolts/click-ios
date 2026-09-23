import SwiftUI

/// Peer profile surface. The self/account experience lives in SettingsView; this view is shaped
/// around the relationship with another Click user.
public struct ProfileView: View {
    @Environment(AppEnvironment.self) private var env
    private let requestedUserID: String?
    private let connectionID: String?

    @State private var data: Phase3ProfileData?
    @State private var refreshError: String?
    @State private var selectedTab: ProfileTab = .timeline
    @State private var timelineDraft = ""
    @State private var timelineVisibility: TimelineVisibility = .privateOnly
    @State private var isPostingTimeline = false
    @State private var tabPayload = ProfileTabPayload.empty
    @State private var isSendingNudge = false
    @State private var nudgeStatus: String?

    public init(
        userID: String? = nil,
        connectionID: String? = nil,
        initialProfile: UserProfileSnapshot? = nil
    ) {
        self.requestedUserID = userID
        self.connectionID = connectionID
        self._data = State(
            initialValue: initialProfile.map {
                Phase3ProfileData(profile: $0, timeline: [])
            }
        )
    }

    private var resolvedUserID: String? {
        requestedUserID ?? env.session.currentSession?.userId
    }

    private var isSelf: Bool {
        guard let resolvedUserID,
              let current = env.session.currentSession?.userId else {
            return false
        }
        return resolvedUserID == current
    }

    public var body: some View {
        Group {
            if let data {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if refreshError != nil {
                            offlineNotice
                        }

                        profileHeader(data.profile)

                        if !isSelf {
                            relationshipActions(data.profile)
                        }

                        if !data.profile.interests.isEmpty {
                            sharedInterests(data.profile.interests)
                        }

                        profileTabBar

                        switch selectedTab {
                        case .timeline:
                            timelineTab(data.timeline)
                        case .beacons:
                            attachmentTab(
                                items: tabPayload.beacons,
                                emptyTitle: "No shared beacons",
                                emptyDescription: "Beacons shared in this conversation appear here.",
                                icon: "mappin.and.ellipse"
                            )
                        case .media:
                            attachmentTab(
                                items: tabPayload.media,
                                emptyTitle: "No shared media",
                                emptyDescription: "Photos and audio shared in this conversation appear here.",
                                icon: "photo.on.rectangle.angled"
                            )
                        case .links:
                            linksTab
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 30)
                }
                .refreshable { await refresh() }
            } else {
                loadingState
            }
        }
        .background(ClickColors.background.ignoresSafeArea())
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .tint(ClickColors.primary)
        .task { await bootstrap() }
    }

    private func profileHeader(_ profile: UserProfileSnapshot) -> some View {
        HStack(spacing: 15) {
            avatar(profile)
                .frame(width: 82, height: 82)
                .clipShape(Circle())
                .overlay {
                    Circle().stroke(ClickColors.primary, lineWidth: 2)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.displayName)
                    .font(ClickTypography.headlineSmall)
                    .foregroundStyle(ClickColors.textPrimary)
                    .lineLimit(2)

                if !profile.handle.isEmpty {
                    Text(profile.handle)
                        .font(ClickTypography.bodyMedium)
                        .foregroundStyle(ClickColors.textSecondary)
                }

                if !profile.bio.isEmpty {
                    Text(profile.bio)
                        .font(ClickTypography.bodySmall)
                        .foregroundStyle(ClickColors.textSecondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func relationshipActions(_ profile: UserProfileSnapshot) -> some View {
        VStack(spacing: 12) {
            Button {
                openChat(profile)
            } label: {
                Label("Message", systemImage: "message.fill")
                    .font(ClickTypography.titleMedium)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(ClickColors.primary)
            .disabled(connectionID == nil)

            HStack(spacing: 10) {
                Button {
                    Task { await sendNudge(profile) }
                } label: {
                    Label("Nudge", systemImage: "bell.badge.fill")
                        .font(ClickTypography.labelLarge)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(.bordered)
                .disabled(connectionID == nil)

                Button {
                    selectedTab = .media
                    ClickHaptics.selection()
                } label: {
                    Label("Drops", systemImage: "camera.fill")
                        .font(ClickTypography.labelLarge)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func sharedInterests(_ tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Shared interests")
                .font(ClickTypography.captionSmall)
                .foregroundStyle(ClickColors.textSecondary)

            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(tags.prefix(8), id: \.self) { tag in
                        Text(tag)
                            .font(ClickTypography.captionSmall)
                            .foregroundStyle(ClickColors.primary)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(ClickColors.primary.opacity(0.1))
                            .clipShape(Capsule())
                            .overlay {
                                Capsule().stroke(ClickColors.primary.opacity(0.35), lineWidth: 1)
                            }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var profileTabBar: some View {
        HStack(spacing: 0) {
            ForEach(ProfileTab.allCases) { tab in
                Button {
                    selectedTab = tab
                    ClickHaptics.selection()
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 17, weight: .semibold))
                        Text(tab.title)
                            .font(ClickTypography.captionSmall)
                            .foregroundStyle(selectedTab == tab ? ClickColors.textPrimary : ClickColors.textSecondary)
                            .frame(maxWidth: .infinity)

                        Rectangle()
                            .fill(selectedTab == tab ? ClickColors.primary : .clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ClickColors.quietBorder.opacity(0.45))
                .frame(height: 1)
        }
    }

    private func timelineTab(_ entries: [ProfileTimelineEntry]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Write a quick memory, note, or plan…", text: $timelineDraft, axis: .vertical)
                    .font(ClickTypography.bodyLarge)
                    .lineLimit(4...7)
                    .padding(14)
                    .frame(minHeight: 118, alignment: .topLeading)
                    .background(ClickColors.surfaceContainerLow)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(ClickColors.quietBorder.opacity(0.7), lineWidth: 1)
                    }

                HStack(spacing: 10) {
                    visibilityButton(.privateOnly)
                    visibilityButton(.shared)

                    Spacer()

                    Button {
                        Task { await postTimeline() }
                    } label: {
                        if isPostingTimeline {
                            ProgressView().controlSize(.small)
                                .frame(minWidth: 54)
                        } else {
                            Text("Add")
                                .font(ClickTypography.labelLarge)
                                .frame(minWidth: 54)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ClickColors.primary)
                    .disabled(
                        timelineDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isPostingTimeline
                    )
                }
            }
            .padding(14)
            .background(ClickColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(ClickColors.quietBorder.opacity(0.65), lineWidth: 1)
            }

            Text("Journal")
                .font(ClickTypography.titleSmall)
                .foregroundStyle(ClickColors.textSecondary)
                .padding(.top, 8)

            if entries.isEmpty {
                profileEmpty(
                    title: "No timeline notes yet",
                    description: "Private notes stay with you. Shared notes are visible to this connection.",
                    icon: "note.text"
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(entry.body)
                                .font(ClickTypography.bodyMedium)
                                .foregroundStyle(ClickColors.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 5) {
                                if let author = entry.authorName, !author.isEmpty {
                                    Text(author)
                                }
                                Text(entry.visibility.capitalized)
                                if let created = entry.createdAt {
                                    Text("·")
                                    Text(created, style: .relative)
                                }
                            }
                            .font(ClickTypography.microcopy)
                            .foregroundStyle(ClickColors.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 13)

                        if entry.id != entries.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func attachmentTab(
        items: [ProfileTabItem],
        emptyTitle: String,
        emptyDescription: String,
        icon: String
    ) -> some View {
        Group {
            if items.isEmpty {
                profileEmpty(title: emptyTitle, description: emptyDescription, icon: icon)
            } else {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.systemImage)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(ClickColors.primary)
                                .frame(width: 38, height: 38)
                                .background(ClickColors.primary.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(ClickTypography.bodyMedium)
                                    .foregroundStyle(ClickColors.textPrimary)
                                    .lineLimit(1)
                                if let subtitle = item.subtitle {
                                    Text(subtitle)
                                        .font(ClickTypography.captionSmall)
                                        .foregroundStyle(ClickColors.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 10)

                        if item.id != items.last?.id {
                            Divider().padding(.leading, 50)
                        }
                    }
                }
            }
        }
    }

    private var linksTab: some View {
        profileEmpty(
            title: "No links yet",
            description: "Links are derived locally from decrypted conversation history and will populate with the native media phase.",
            icon: "link"
        )
    }

    private func profileEmpty(title: String, description: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(ClickColors.tertiaryLabel)
            Text(title)
                .font(ClickTypography.titleMedium)
                .foregroundStyle(ClickColors.textPrimary)
            Text(description)
                .font(ClickTypography.bodySmall)
                .foregroundStyle(ClickColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    @ViewBuilder
    private func avatar(_ profile: UserProfileSnapshot) -> some View {
        if let raw = profile.avatarUrl, let url = URL(string: raw) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                avatarFallback(profile)
            }
        } else {
            avatarFallback(profile)
        }
    }

    private func avatarFallback(_ profile: UserProfileSnapshot) -> some View {
        Circle()
            .fill(ClickColors.primary.opacity(0.12))
            .overlay {
                Text(profile.initials)
                    .font(ClickTypography.headlineSmall)
                    .foregroundStyle(ClickColors.primary)
            }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().tint(ClickColors.primary)
            Text("Loading profile…")
                .font(ClickTypography.bodySmall)
                .foregroundStyle(ClickColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var offlineNotice: some View {
        HStack(spacing: 7) {
            Image(systemName: "wifi.exclamationmark")
            Text("Offline — showing saved profile")
                .font(ClickTypography.captionSmall)
            Spacer()
            Button("Retry") { Task { await refresh() } }
                .font(ClickTypography.captionSmall)
        }
        .foregroundStyle(ClickColors.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ClickColors.surfaceContainerLow)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func openChat(_ profile: UserProfileSnapshot) {
        guard let connectionID, let userID = resolvedUserID else { return }
        env.router.connectionsPath.append(
            .chat(
                DirectChatRoute(
                    connectionID: connectionID,
                    peerUserID: userID,
                    peerDisplayName: profile.displayName,
                    peerHandle: profile.handle,
                    peerAvatarURL: profile.avatarUrl
                )
            )
        )
    }

    private func visibilityButton(_ value: TimelineVisibility) -> some View {
        Button {
            timelineVisibility = value
            ClickHaptics.selection()
        } label: {
            Text(value.label)
                .font(ClickTypography.labelMedium)
                .foregroundStyle(timelineVisibility == value ? ClickColors.primary : ClickColors.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(
                    timelineVisibility == value
                        ? ClickColors.primary.opacity(0.10)
                        : ClickColors.surfaceContainerLow
                )
                .clipShape(Capsule())
                .overlay {
                    Capsule().stroke(
                        timelineVisibility == value
                            ? ClickColors.primary.opacity(0.8)
                            : ClickColors.quietBorder.opacity(0.7),
                        lineWidth: 1
                    )
                }
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func sendNudge(_ profile: UserProfileSnapshot) async {
        guard
            let connectionID,
            let currentUserID = env.session.currentSession?.userId,
            let peerUserID = resolvedUserID
        else { return }

        do {
            let chatID = try await env.chat.resolveCanonicalChatID(
                chatID: connectionID,
                connectionID: connectionID
            )
            _ = try await env.chat.sendMessage(
                chatID: chatID,
                connectionID: connectionID,
                peerUserID: peerUserID,
                currentUserID: currentUserID,
                currentUserName: "Someone",
                content: "👋 Someone nudged you!",
                replyToID: nil,
                replyToSnippet: nil,
                replyToSenderName: nil,
                clientMessageID: UUID().uuidString
            )
            ClickHaptics.success()
        } catch {
            refreshError = error.localizedDescription
            ClickHaptics.error()
        }
    }

    @MainActor
    private func bootstrap() async {
        guard data == nil, let userID = resolvedUserID else { return }
        if let cached = await env.phase3.cachedProfile(for: userID) {
            data = cached
        }
        await refresh()
        await loadTabs()
    }

    @MainActor
    private func refresh() async {
        guard let userID = resolvedUserID else { return }

        do {
            data = isSelf
                ? try await env.phase3.refreshSelfProfile(userID: userID)
                : try await env.phase3.refreshProfile(userID: userID, connectionID: connectionID)
            refreshError = nil
        } catch {
            refreshError = error.localizedDescription
        }
    }

    @MainActor
    private func sendNudge(_ profile: UserProfileSnapshot) async {
        guard
            let connectionID,
            let peerUserID = resolvedUserID,
            let currentUserID = env.session.currentSession?.userId
        else { return }

        isSendingNudge = true
        defer { isSendingNudge = false }

        do {
            let cachedProfile = await env.phase3.cachedProfile(for: currentUserID)
            let currentProfile: Phase3ProfileData?
            if let cachedProfile {
                currentProfile = cachedProfile
            } else {
                currentProfile = try? await env.phase3.refreshSelfProfile(userID: currentUserID)
            }
            let senderName = currentProfile?.profile.displayName.nonEmpty ?? "Someone"
            let canonicalChatID = try await env.chat.resolveCanonicalChatID(
                chatID: connectionID,
                connectionID: connectionID
            )
            _ = try await env.chat.sendMessage(
                chatID: canonicalChatID,
                connectionID: connectionID,
                peerUserID: peerUserID,
                currentUserID: currentUserID,
                currentUserName: senderName,
                content: "👋 \(senderName) nudged you!",
                replyToID: nil,
                replyToSnippet: nil,
                replyToSenderName: nil,
                clientMessageID: UUID().uuidString.lowercased()
            )
            nudgeStatus = "Nudge sent to \(profile.displayName)."
            ClickHaptics.success()
        } catch {
            nudgeStatus = error.localizedDescription
            ClickHaptics.error()
        }
    }

    @MainActor
    private func postTimeline() async {
        guard let userID = resolvedUserID else { return }
        let clean = timelineDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        isPostingTimeline = true
        defer { isPostingTimeline = false }

        do {
            let body = try JSONSerialization.data(withJSONObject: [
                "target_type": "user",
                "target_id": userID,
                "body": clean,
                "visibility": timelineVisibility.apiValue
            ])
            let request = APIRequest(
                path: "/api/profile/timeline",
                method: .post,
                body: body,
                requiresAuth: true
            )
            _ = try await env.api.executeRaw(request)
            timelineDraft = ""
            await refresh()
            ClickHaptics.success()
        } catch {
            refreshError = error.localizedDescription
            ClickHaptics.error()
        }
    }

    @MainActor
    private func loadTabs() async {
        guard let connectionID, !connectionID.isEmpty else { return }
        do {
            let request = APIRequest(
                path: "/api/connections/\(connectionID)/tabs",
                method: .get,
                queryItems: [URLQueryItem(name: "limit", value: "200")],
                requiresAuth: true
            )
            let (raw, _) = try await env.api.executeRaw(request)
            tabPayload = ProfileTabPayload.decode(raw)
        } catch {
            // Timeline/profile remain usable even when optional attachment metadata is unavailable.
        }
    }
}

private enum ProfileTab: String, CaseIterable, Identifiable {
    case timeline
    case beacons
    case media
    case links

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .timeline: return "clock.arrow.circlepath"
        case .beacons: return "mappin"
        case .media: return "photo"
        case .links: return "link"
        }
    }
}

private enum TimelineVisibility: String, CaseIterable, Identifiable {
    case privateOnly
    case shared

    var id: String { rawValue }
    var label: String { self == .privateOnly ? "Private" : "Everyone" }
    var apiValue: String { self == .privateOnly ? "private" : "shared" }
}

private struct ProfileTabItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String
}

private struct ProfileTabPayload {
    var media: [ProfileTabItem]
    var beacons: [ProfileTabItem]

    static let empty = ProfileTabPayload(media: [], beacons: [])

    static func decode(_ data: Data) -> ProfileTabPayload {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }

        func makeItems(_ rows: [[String: Any]], fallbackIcon: String) -> [ProfileTabItem] {
            rows.compactMap { row in
                guard let id = row["id"] as? String else { return nil }
                let type = (row["message_type"] as? String) ?? ""
                let metadata = row["metadata"] as? [String: Any] ?? [:]
                let fileName =
                    (metadata["file_name"] as? String)
                    ?? (metadata["filename"] as? String)
                    ?? (metadata["name"] as? String)
                let title = fileName ?? {
                    switch type {
                    case "image": return "Photo"
                    case "audio": return "Audio"
                    case "file": return "File"
                    case "beacon": return "Shared beacon"
                    default: return "Shared item"
                    }
                }()
                let icon: String = {
                    switch type {
                    case "image": return "photo"
                    case "audio": return "waveform"
                    case "file": return "doc"
                    case "beacon": return "mappin.and.ellipse"
                    default: return fallbackIcon
                    }
                }()
                return ProfileTabItem(id: id, title: title, subtitle: nil, systemImage: icon)
            }
        }

        return ProfileTabPayload(
            media: makeItems(root["media"] as? [[String: Any]] ?? [], fallbackIcon: "photo"),
            beacons: makeItems(root["beacons"] as? [[String: Any]] ?? [], fallbackIcon: "mappin")
        )
    }
}


private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
