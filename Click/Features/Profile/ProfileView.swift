import SwiftUI

/// The one canonical person profile (spec §47), reached from Clicks, chat headers, map pins,
/// search, event directories, and Home. Identity first; Message is the primary relationship
/// action; secondary and safety actions are quieter; the Timeline is relationship history.
public struct ProfileView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ConversationListModel.self) private var conversations
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var model: PeerProfileModel
    @State private var tab: ProfileTab = .timeline
    @State private var journalEditor: JournalEditorTarget?
    @State private var taggingEncounter: Encounter?
    @State private var safetyAction: SafetyAction?
    @State private var reportReason = ""
    @State private var isWorking = false
    @State private var notice: String?
    @State private var showsCompactTitle = false
    @State private var viewerURL: ProfileViewerURL?
    @State private var takingDrop = false
    @State private var quickLookURL: URL?

    public init(userID: String, connectionID: String? = nil) {
        _model = State(initialValue: PeerProfileModel.shared(userID: userID, connectionID: connectionID))
    }

    private var inboxItem: ConnectionItem? {
        (conversations.active + conversations.archived).first { $0.userID == model.userID }
    }

    private var isSelf: Bool { env.session.currentSession?.userId == model.userID }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                identity
                if !isSelf { actions }
                if let notice {
                    Text(notice)
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textSecondary)
                        .frame(maxWidth: .infinity)
                }
                commonGround
                Section {
                    tabContent
                } header: {
                    tabChips
                }
            }
            .padding(.horizontal, ClickSpacing.screenGutter)
            .padding(.bottom, 32)
            // Sections that arrive later fade and slide into place instead of popping.
            .animation(ClickMotion.content, value: loadSignature)
        }
        .background(ClickColors.background.ignoresSafeArea())
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 170
        } action: { _, scrolledPastName in
            showsCompactTitle = scrolledPastName
        }
        .refreshable { await model.load(force: true) }
        .fullScreenCover(item: $viewerURL) { item in MediaViewer(url: item.url) }
        .quickLookPreview($quickLookURL)
        .navigationTitle(model.profile.value?.displayName ?? "Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(model.profile.value?.displayName ?? "")
                    .font(.headline)
                    .opacity(showsCompactTitle ? 1 : 0)
            }
            if !isSelf, model.connectionID != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Remove connection", systemImage: "person.badge.minus", role: .destructive) { safetyAction = .remove }
                        Button("Report", systemImage: "exclamationmark.bubble") { safetyAction = .report }
                        Button("Block", systemImage: "hand.raised", role: .destructive) { safetyAction = .block }
                    } label: {
                        Label("More actions", systemImage: "ellipsis")
                    }
                }
            }
        }
        .task {
            model.attach(env, fallbackConnectionID: inboxItem?.connectionID)
            await model.load()
        }
        .sheet(item: $taggingEncounter) { encounter in
            EncounterTagEditor(encounter: encounter) {
                Task { await model.loadEncounters() }
            }
        }
        .sheet(item: $journalEditor) { target in
            JournalEditor(target: target) { body, visibility in
                try await model.saveJournal(body: body, visibility: visibility, editing: target.entry)
            }
        }
        .confirmationDialog(safetyTitle, isPresented: Binding(
            get: { safetyAction == .remove || safetyAction == .block },
            set: { if !$0 { safetyAction = nil } }
        ), titleVisibility: .visible) {
            Button(safetyAction == .block ? "Block" : "Remove", role: .destructive) {
                Task { await performSafety() }
            }
        } message: {
            Text(safetyAction == .block
                 ? "They won't be able to message you, and they'll be removed from your Clicks."
                 : "This Click is removed from your inbox and map. It can't be undone.")
        }
        .alert("Report \(model.profile.value?.firstName ?? "this person")", isPresented: Binding(
            get: { safetyAction == .report },
            set: { if !$0 { safetyAction = nil; reportReason = "" } }
        )) {
            TextField("What happened?", text: $reportReason)
            Button("Submit") { Task { await performSafety() } }
                .disabled(reportReason.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reports are private and reviewed by the Click team.")
        }
    }

    /// Changes whenever a module lands, driving one content animation.
    private var loadSignature: [Int] {
        [model.profile.value == nil ? 0 : 1, model.timeline.count, model.encounters.isPending ? 0 : 1, model.journal.isPending ? 0 : 1]
    }

    // MARK: - Identity

    private var identity: some View {
        let profile = model.profile.value
        return VStack(spacing: 6) {
            AvatarView(
                imageURL: profile?.avatarURL ?? inboxItem?.avatarUrl,
                seed: model.userID,
                initials: profile?.initials ?? inboxItem?.initials ?? "",
                size: 112
            )
            Text(profile?.displayName ?? inboxItem?.displayName ?? " ")
                .font(ClickTypography.identityTitle)
                .foregroundStyle(ClickColors.textPrimary)
                .multilineTextAlignment(.center)
                .redacted(reason: profile == nil && inboxItem == nil ? .placeholder : [])
                .padding(.top, 8)
            if let bio = profile?.bio {
                Text(bio)
                    .font(ClickTypography.body)
                    .foregroundStyle(ClickColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            if let line = model.relationshipLine {
                Text(line)
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textTertiary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 6) {
                if inboxItem?.isCore == true { StatusPill("Core") }
                if profile?.isFreeCurrently == true { StatusPill("Free now") }
            }
            .padding(.top, 4)
            if model.profile.value == nil, let message = model.profile.errorMessage {
                Button("Couldn't load this profile. \(message) Retry") { Task { await model.loadProfile() } }
                    .font(ClickTypography.supporting)
            } else {
                OfflineNotice(showing: "a saved profile", hasCachedValue: model.profile.value != nil, refreshFailed: model.profile.isStale) {
                    Task { await model.loadProfile() }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                actionTile("Message", systemImage: "message") { openChat() }
                    .disabled(model.connectionID == nil)
                if model.connectionID != nil {
                    actionTile("Nudge", systemImage: "hand.wave", busy: isWorking) { Task { await sendNudge() } }
                        .disabled(isWorking)
                    if let item = inboxItem {
                        actionTile("Core", systemImage: item.isCore ? "star.fill" : "star", tint: item.isCore ? ClickColors.accentForeground : nil) {
                            Task { await conversations.setCore(item, isCore: !item.isCore) }
                        }
                        .accessibilityLabel(item.isCore ? "Remove from Core" : "Add to Core")
                    }
                    actionTile("Click Drop", systemImage: "hourglass") { takingDrop = true }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                }
            }
            if model.connectionID == nil {
                Text("You can message people after you Click in person.")
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.textTertiary)
            }
        }
        .fullScreenCover(isPresented: $takingDrop) {
            CameraCapture { image in
                takingDrop = false
                if let image { Task { await sendClickDrop(image) } }
            }
            .ignoresSafeArea()
        }
    }

    private func actionTile(_ title: String, systemImage: String, tint: Color? = nil, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    if busy { ProgressView() } else { Image(systemName: systemImage).font(.system(size: 20)) }
                }
                .frame(height: 24)
                Text(title).font(ClickTypography.supporting).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(tint ?? ClickColors.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(ClickColors.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Click Drop from the profile: sent into the direct chat, revealed 24 h later.
    private func sendClickDrop(_ image: UIImage) async {
        guard let connectionID = model.connectionID, let userID = env.session.currentSession?.userId,
              let data = image.jpegData(compressionQuality: 0.9), var draft = await MediaDraftBuilder.image(from: data) else { return }
        draft.isClickDrop = true
        let conversation = ConversationIdentity(
            chatID: inboxItem?.chatID ?? connectionID, connectionID: connectionID,
            peerUserID: model.userID, peerDisplayName: model.profile.value?.displayName ?? "Click user"
        )
        do {
            _ = try await env.chat.sendMedia(conversation: conversation, currentUserID: userID, currentUserName: "You",
                                             draft: draft, replyToID: nil, clientMessageID: UUID().uuidString.lowercased())
            notice = "Click Drop sent. It develops in 24 hours."
            ClickHaptics.success()
        } catch {
            notice = "Couldn't send the Click Drop. \(error.userFacingMessage)"
        }
    }

    // MARK: - Common ground

    @ViewBuilder
    private var commonGround: some View {
        if let profile = model.profile.value, !(profile.sharedInterests.isEmpty && profile.personality.isEmpty && profile.interests.isEmpty) {
            VStack(alignment: .leading, spacing: 10) {
                let shared = profile.sharedInterests
                Text("Common ground")
                    .font(ClickTypography.bodyEmphasized)
                if !shared.isEmpty {
                    Text(shared.count == 1 ? "1 shared interest" : "\(shared.count) shared interests")
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textTertiary)
                }
                // Every interest they have: shared ones first and highlighted, the rest outlined.
                let others = profile.interests.filter { tag in !shared.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
                FlowLayout(spacing: 7) {
                    ForEach(shared, id: \.self) { InterestChip(text: $0, shared: true) }
                    ForEach(others, id: \.self) { InterestChip(text: $0, shared: false) }
                }
                if !profile.personality.isEmpty {
                    Divider().padding(.vertical, 4)
                    Text("Personality")
                        .font(ClickTypography.bodyEmphasized)
                    TagFlow(tags: profile.personality, highlighted: false)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .groupedSurface()
        }
    }

    // MARK: - Tabs

    private var tabChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(ProfileTab.allCases) { value in
                    Button {
                        tab = value
                        ClickHaptics.selection()
                        if value == .links, let name = model.profile.value?.displayName {
                            Task { await model.loadLinks(peerName: name) }
                        }
                    } label: {
                        Text(value.title)
                            .font(ClickTypography.supporting.weight(tab == value ? .semibold : .medium))
                            .foregroundStyle(tab == value ? ClickColors.accentForeground : ClickColors.textSecondary)
                            .padding(.horizontal, 15)
                            .frame(minHeight: ClickMetrics.chipHeight)
                            .background(tab == value ? ClickColors.selectionTint : ClickColors.fillSubtle, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == value ? .isSelected : [])
                }
            }
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .background(ClickColors.background)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .timeline: timelineTab
        case .media: mediaTab
        case .links: linksTab
        case .files: filesTab
        case .beacons: sharedList(model.tabs.value?.beacons, empty: "No events or beacons shared yet.")
        }
    }

    private var timelineTab: some View {
        VStack(spacing: 0) {
            Button {
                journalEditor = JournalEditorTarget(entry: nil)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(ClickColors.accentForeground)
                        .frame(width: 34, height: 34)
                        .background(ClickColors.selectionTint, in: Circle())
                    Text("Add journal note")
                        .font(ClickTypography.body)
                        .foregroundStyle(ClickColors.accentForeground)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(minHeight: ClickMetrics.rowMinHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            let items = model.timeline
            if items.isEmpty {
                Divider().padding(.leading, 64)
                Group {
                    if model.encounters.isPending || model.journal.isPending {
                        // Reserved space shaped like timeline rows, so history doesn't jump in.
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(0..<2, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Reconnected at a place").font(ClickTypography.bodyEmphasized)
                                    Text("Sep 22 · 7:30 PM · 68°F").font(ClickTypography.metadata)
                                }
                            }
                        }
                        .redacted(reason: .placeholder)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    } else if model.encounters.errorMessage != nil || model.journal.errorMessage != nil {
                        Button("Couldn't load your history. Retry") {
                            Task { await model.loadEncounters(); await model.loadJournal() }
                        }
                        .font(ClickTypography.supporting)
                        .padding(20)
                    } else {
                        Text("Your shared history appears here.")
                            .font(ClickTypography.supporting)
                            .foregroundStyle(ClickColors.textTertiary)
                            .padding(20)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            ForEach(items) { item in
                Divider().padding(.leading, 64)
                TimelineRow(item: item, isOwn: isOwn(item)) { entry in
                    journalEditor = JournalEditorTarget(entry: entry)
                } onDelete: { entry in
                    Task { try? await model.deleteJournal(entry) }
                } onOpenEvent: { beaconID in
                    env.router.navigate(to: .event(beaconID: beaconID))
                } onEditTags: { encounter in
                    taggingEncounter = encounter
                }
            }
        }
        .groupedSurface()
    }

    private func isOwn(_ item: TimelineItem) -> Bool {
        if case .journal(let entry) = item { return entry.authorID == env.session.currentSession?.userId }
        return false
    }

    @ViewBuilder
    private func sharedList(_ items: [SharedItem]?, empty: String) -> some View {
        VStack(spacing: 0) {
            if let items {
                if items.isEmpty {
                    Text(empty)
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textTertiary)
                        .padding(20)
                        .frame(maxWidth: .infinity)
                }
                ForEach(items) { item in
                    Button { open(item) } label: { SharedItemRow(item: item, isOwn: item.senderID == env.session.currentSession?.userId) }
                        .buttonStyle(.plain)
                    if item.id != items.last?.id { Divider().padding(.leading, 68) }
                }
            } else {
                switch model.tabs.phase {
                case .unavailable(let reason):
                    Text(reason).font(ClickTypography.supporting).foregroundStyle(ClickColors.textTertiary).padding(20)
                case .failed:
                    Button("Couldn't load shared content. Retry") { Task { await model.loadTabs() } }
                        .font(ClickTypography.supporting).padding(20)
                default:
                    ClickLoadingView(size: 28, fillsSpace: false).padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .groupedSurface()
    }

    // MARK: - Media & files

    @ViewBuilder
    private var mediaTab: some View {
        if model.tabs.value == nil {
            sharedList(nil, empty: "")
        } else if model.mediaItems.isEmpty {
            sharedList([], empty: "No photos or voice notes shared yet.")
        } else {
            let photos = model.mediaItems.filter { $0.media?.kind == .image }
            let voice = model.mediaItems.filter { $0.media?.kind == .audio }
            VStack(alignment: .leading, spacing: 14) {
                if !photos.isEmpty {
                    let prefetchFrom = Set(photos.suffix(12).map(\.id))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                        ForEach(photos) { item in
                            ProfileMediaThumbnail(item: item, load: { try await model.mediaURL(for: item) }) { url in
                                viewerURL = ProfileViewerURL(url: url)
                            }
                            // The next page loads while the last rows are still coming into view.
                            .onAppear {
                                if prefetchFrom.contains(item.id) { Task { await model.loadMoreMedia() } }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: ClickRadius.compact, style: .continuous))
                }
                if !voice.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Voice notes")
                            .font(ClickTypography.supportingEmphasized)
                            .foregroundStyle(ClickColors.textSecondary)
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(voice) { item in
                                if let media = item.media {
                                    MessageMediaContent(message: item, media: media, load: { try await model.mediaURL(for: item) }, onOpen: { _ in })
                                        .onAppear {
                                            if item.id == voice.last?.id { Task { await model.loadMoreMedia() } }
                                        }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var filesTab: some View {
        if model.tabs.value == nil {
            sharedList(nil, empty: "")
        } else if model.fileItems.isEmpty {
            sharedList([], empty: "No files shared yet.")
        } else {
            VStack(spacing: 8) {
                ForEach(model.fileItems) { item in
                    if let media = item.media {
                        MessageMediaContent(message: item, media: media, load: { try await model.mediaURL(for: item) }) { url in
                            quickLookURL = url
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var linksTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                if let links = model.links.value {
                    if links.isEmpty {
                        Text("No links shared yet.")
                            .font(ClickTypography.supporting)
                            .foregroundStyle(ClickColors.textTertiary)
                            .padding(20)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(links, id: \.absoluteString) { url in
                        Link(destination: url) {
                            HStack(spacing: 14) {
                                Image(systemName: "link")
                                    .frame(width: 38, height: 38)
                                    .background(ClickColors.fillSubtle, in: RoundedRectangle(cornerRadius: ClickRadius.compact, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(url.host() ?? url.absoluteString)
                                        .font(ClickTypography.body)
                                        .foregroundStyle(ClickColors.textPrimary)
                                        .lineLimit(1)
                                    Text(url.absoluteString)
                                        .font(ClickTypography.supporting)
                                        .foregroundStyle(ClickColors.textTertiary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
                        if url != links.last { Divider().padding(.leading, 68) }
                    }
                } else if case .unavailable(let reason) = model.links.phase {
                    Text(reason).font(ClickTypography.supporting).foregroundStyle(ClickColors.textTertiary).padding(20)
                } else if model.links.errorMessage != nil {
                    Button("Couldn't read your messages for links. Retry") {
                        Task { await model.loadLinks(peerName: model.profile.value?.displayName ?? "") }
                    }
                    .font(ClickTypography.supporting).padding(20)
                } else {
                    ClickLoadingView(size: 28, fillsSpace: false).padding(8)
                }
            }
            .groupedSurface()
            Text("Links are collected on this iPhone from your decrypted messages.")
                .font(ClickTypography.metadata)
                .foregroundStyle(ClickColors.textTertiary)
                .padding(.horizontal, 12)
        }
    }

    // MARK: - Actions

    private func open(_ item: SharedItem) {
        if let beaconID = item.beaconID {
            env.router.navigate(to: .event(beaconID: beaconID))
        } else {
            openChat()
        }
    }

    private func openChat() {
        guard let connectionID = model.connectionID else { return }
        let profile = model.profile.value
        env.router.navigate(to: .chat(DirectChatRoute(
            chatID: inboxItem?.chatID,
            connectionID: connectionID,
            peerUserID: model.userID,
            peerDisplayName: profile?.displayName ?? inboxItem?.displayName ?? "Click user",
            peerAvatarURL: profile?.avatarURL ?? inboxItem?.avatarUrl
        )))
    }

    /// Nudge is an ordinary encrypted chat message, like the shipping client (spec §29.7).
    private func sendNudge() async {
        guard let connectionID = model.connectionID, let currentUserID = env.session.currentSession?.userId else { return }
        isWorking = true
        defer { isWorking = false }
        let senderName = await env.me.cachedSelfProfile(userID: currentUserID)?.firstName.nonEmptyTrimmed ?? "Someone"
        do {
            let chatID = try await env.chat.resolveCanonicalChatID(chatID: connectionID, connectionID: connectionID)
            let conversation = ConversationIdentity(
                chatID: chatID, connectionID: connectionID, peerUserID: model.userID,
                peerDisplayName: model.profile.value?.displayName ?? "Click user"
            )
            _ = try await env.chat.sendMessage(
                conversation: conversation,
                currentUserID: currentUserID, currentUserName: senderName,
                content: "👋 \(senderName) nudged you!", replyToID: nil, replyToSnippet: nil,
                replyToSenderName: nil, clientMessageID: UUID().uuidString.lowercased()
            )
            notice = "Nudge sent."
            ClickHaptics.success()
        } catch {
            notice = "Couldn't send the nudge. \(error.userFacingMessage)"
            ClickHaptics.error()
        }
    }

    private var safetyTitle: String {
        safetyAction == .block ? "Block \(model.profile.value?.firstName ?? "this person")?" : "Remove this Click?"
    }

    /// The UI changes only after the server confirms (no optimistic removal).
    private func performSafety() async {
        guard let action = safetyAction, let connectionID = model.connectionID else { return }
        safetyAction = nil
        isWorking = true
        defer { isWorking = false }
        do {
            switch action {
            case .report:
                try await conversations.report(connectionID: connectionID, reason: reportReason.trimmingCharacters(in: .whitespacesAndNewlines))
                reportReason = ""
                notice = "Thanks. Your report was sent."
            case .block:
                try await conversations.block(userID: model.userID, connectionID: connectionID)
                dismiss()
            case .remove:
                try await conversations.hideConnection(connectionID: connectionID)
                dismiss()
            }
        } catch {
            notice = "That didn't go through. \(error.userFacingMessage)"
        }
    }
}

private enum ProfileTab: String, CaseIterable, Identifiable {
    case timeline, beacons, media, links, files
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

private enum SafetyAction {
    case remove, report, block
}

struct JournalEditorTarget: Identifiable {
    let entry: JournalEntry?
    var id: String { entry?.id ?? "new" }
}

private struct TimelineRow: View {
    let item: TimelineItem
    let isOwn: Bool
    let onEdit: (JournalEntry) -> Void
    let onDelete: (JournalEntry) -> Void
    let onOpenEvent: (String) -> Void
    let onEditTags: (Encounter) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isJournal ? ClickColors.textSecondary : ClickColors.accentForeground)
                .frame(width: 38, height: 38)
                .background(isJournal ? ClickColors.fillSubtle : ClickColors.selectionTint, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(header)
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textTertiary)
                content
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contextMenu {
            if case .journal(let entry) = item, isOwn {
                Button("Edit", systemImage: "pencil") { onEdit(entry) }
                Button("Delete", systemImage: "trash", role: .destructive) { onDelete(entry) }
            }
            if case .encounter(let encounter, _) = item {
                Button("Edit tags", systemImage: "tag") { onEditTags(encounter) }
            }
        }
    }

    private var isJournal: Bool {
        if case .journal = item { return true }
        return false
    }

    private var symbol: String {
        switch item {
        case .encounter(let encounter, let isFirst):
            encounter.eventTitle != nil ? "calendar" : (isFirst ? "sparkles" : "arrow.clockwise")
        case .journal: "pencil"
        }
    }

    /// "Yesterday · Sep 22", "Aug 29", "Journal · Sep 21".
    private var header: String {
        let date = item.date
        let day = date.formatted(.dateTime.month(.abbreviated).day())
        let calendar = Calendar.current
        let dayWithYear = calendar.isDate(date, equalTo: .now, toGranularity: .year)
            ? day : date.formatted(.dateTime.month(.abbreviated).day().year())
        if isJournal { return "Journal · \(dayWithYear)" }
        if calendar.isDateInToday(date) { return "Today · \(day)" }
        if calendar.isDateInYesterday(date) { return "Yesterday · \(day)" }
        return dayWithYear
    }

    @ViewBuilder
    private var content: some View {
        switch item {
        case .encounter(let encounter, let isFirst):
            Text(EncounterLabels.whenLine(encounter.date))
                .font(ClickTypography.caption)
                .foregroundStyle(ClickColors.textSecondary)

            if let title = encounter.eventTitle {
                Button {
                    if let beaconID = encounter.eventBeaconID { onOpenEvent(beaconID) }
                } label: {
                    Text([title, encounter.placeName].compactMap { $0 }.joined(separator: " · "))
                        .font(ClickTypography.bodyEmphasized)
                        .foregroundStyle(ClickColors.textPrimary)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                Text("You were both at this event.")
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
            } else {
                Text(title(encounter, isFirst: isFirst))
                    .font(ClickTypography.bodyEmphasized)
                    .foregroundStyle(ClickColors.textPrimary)
            }

            let currentTitle = encounter.eventTitle ?? title(encounter, isFirst: isFirst)
            if let place = EncounterLabels.placeLine(locationName: encounter.locationName ?? encounter.venue,
                                                     displayLocation: encounter.displayLocation,
                                                     neighbourhood: encounter.neighbourhood),
               place != currentTitle {
                Text(place)
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
            }

            let chips = EncounterLabels.chips(for: encounter)
            if !chips.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(chips, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 14))
                                .foregroundStyle(ClickColors.accentForeground)
                            Text(tag)
                                .font(ClickTypography.caption.weight(.medium))
                                .foregroundStyle(ClickColors.textPrimary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(ClickColors.fillSubtle, in: Capsule())
                        .overlay(Capsule().stroke(ClickColors.separator, lineWidth: 1))
                    }
                }
                .padding(.top, 2)
            }

            let pills = EncounterLabels.metricPills(for: encounter)
            if !pills.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(pills, id: \.self) { pill in
                        TimelineMetricPill(pill: pill)
                    }
                }
                .padding(.top, 2)
            }

            if let vibe = encounter.vibeCapture {
                Text("“\(vibe)”")
                    .font(ClickTypography.supporting.italic())
                    .foregroundStyle(ClickColors.textSecondary)
            }
            Button("Edit tags") { onEditTags(encounter) }
                .font(ClickTypography.metadataEmphasized)
                .foregroundStyle(ClickColors.accentForeground)
                .buttonStyle(.borderless)
                .padding(.top, 2)
        case .journal(let entry):
            Text(entry.visibility == .private ? "Note to self" : "Shared note")
                .font(ClickTypography.bodyEmphasized)
                .foregroundStyle(ClickColors.textPrimary)
            Text(entry.body)
                .font(ClickTypography.body)
                .foregroundStyle(ClickColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !isOwn, let author = entry.authorName {
                Text("From \(author)")
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.textTertiary)
            }
            if isOwn {
                HStack(spacing: 20) {
                    Button("Edit") { onEdit(entry) }
                        .foregroundStyle(ClickColors.accentForeground)
                    Button("Delete", role: .destructive) { onDelete(entry) }
                        .foregroundStyle(ClickColors.destructive)
                }
                .font(ClickTypography.body)
                .buttonStyle(.borderless)
                .padding(.top, 6)
            }
        }
    }

    private func title(_ encounter: Encounter, isFirst: Bool) -> String {
        let place = encounter.placeName
        if isFirst { return place.map { "First Clicked at \($0)" } ?? "First Clicked" }
        return place.map { "Reconnected at \($0)" } ?? "Reconnected"
    }
}

private struct InterestChip: View {
    let text: String
    let shared: Bool

    var body: some View {
        Text(text)
            .font(ClickTypography.supporting)
            .foregroundStyle(shared ? ClickColors.accentForeground : ClickColors.textSecondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(shared ? ClickColors.selectionTint : .clear, in: Capsule())
            .overlay(Capsule().stroke(shared ? .clear : ClickColors.separator, lineWidth: 1))
    }
}

/// "Edit tags" for one timeline encounter (KMP `ConnectionRepositoryEncounters` update).
private struct EncounterTagEditor: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let encounter: Encounter
    let onSaved: () -> Void

    @State private var selected: [String]
    @State private var custom = ""
    @State private var saving = false
    @State private var error: String?

    init(encounter: Encounter, onSaved: @escaping () -> Void) {
        self.encounter = encounter
        self.onSaved = onSaved
        _selected = State(initialValue: encounter.contextTags)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(EncounterLabels.whenLine(encounter.date))
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textTertiary)
                    ContextTagPicker(
                        selected: $selected,
                        custom: $custom,
                        suggestions: ContextTagTaxonomy.suggest(locationName: encounter.placeName, hour: Calendar.current.component(.hour, from: encounter.date))
                    )
                    if let error {
                        Text(error).font(ClickTypography.metadata).foregroundStyle(ClickColors.destructive)
                    }
                }
                .padding(ClickSpacing.screenGutter)
            }
            .navigationTitle("Edit tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }.disabled(saving)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await env.encounterContext.setTags(encounterID: encounter.id, tags: ContextTagPicker.resolved(selected: selected, custom: custom))
            onSaved()
            dismiss()
        } catch {
            self.error = "Tags weren't saved. \(error.userFacingMessage)"
        }
    }
}

struct ProfileViewerURL: Identifiable {
    let url: URL
    var id: URL { url }
}

/// A square, decrypted photo thumbnail in the profile Media grid.
struct ProfileMediaThumbnail: View {
    let item: ChatMessageItem
    let load: () async throws -> URL
    let onOpen: (URL) -> Void

    @State private var image: UIImage?
    @State private var url: URL?
    @State private var failed = false

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if failed {
                    Image(systemName: "photo.badge.exclamationmark").foregroundStyle(ClickColors.textTertiary)
                } else {
                    ProgressView()
                }
            }
            .background(ClickColors.fillSubtle)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { if let url { onOpen(url) } }
            .task(id: item.id) {
                guard image == nil else { return }
                do {
                    let fileURL = try await load()
                    let thumb = await Task.detached(priority: .utility) {
                        UIImage(contentsOfFile: fileURL.path)?.preparingThumbnail(of: CGSize(width: 360, height: 360))
                    }.value
                    url = fileURL
                    image = thumb
                    failed = thumb == nil
                } catch {
                    failed = true
                }
            }
            .accessibilityLabel("Photo from \(item.createdAt.formatted(date: .abbreviated, time: .omitted))")
            .accessibilityAddTraits(.isButton)
    }
}

private struct SharedItemRow: View {
    let item: SharedItem
    let isOwn: Bool

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let beaconID = item.beaconID {
                    EventVisual(seed: beaconID, symbol: "calendar")
                } else {
                    Image(systemName: symbol)
                        .foregroundStyle(ClickColors.accentForeground)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(ClickColors.selectionTint, in: RoundedRectangle(cornerRadius: ClickRadius.compact, style: .continuous))
                }
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(ClickTypography.body)
                    .foregroundStyle(ClickColors.textPrimary)
                    .lineLimit(1)
                Text([isOwn ? "You" : nil, item.createdAt?.formatted(date: .abbreviated, time: .omitted)].compactMap { $0 }.joined(separator: " · "))
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textTertiary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ClickColors.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var title: String {
        if item.beaconID != nil { return item.beaconTitle ?? "Shared event" }
        switch item.messageType {
        case "image": return "Photo"
        case "audio": return "Voice note"
        case "file": return "File"
        default: return "Shared item"
        }
    }

    private var symbol: String {
        switch item.messageType {
        case "image": "photo"
        case "audio": "waveform"
        case "file": "doc"
        default: "paperclip"
        }
    }
}

/// Wrapping chip layout for interests, traits, and encounter context.
struct TagFlow: View {
    let tags: [String]
    let highlighted: Bool
    var compact = false

    var body: some View {
        FlowLayout(spacing: 7) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(compact ? ClickTypography.metadata : ClickTypography.supporting)
                    .foregroundStyle(highlighted ? ClickColors.accentForeground : ClickColors.textSecondary)
                    .padding(.horizontal, compact ? 9 : 12)
                    .frame(minHeight: compact ? 24 : 32)
                    .background(highlighted ? ClickColors.selectionTint : ClickColors.fillSubtle, in: Capsule())
            }
        }
    }
}

private struct TimelineMetricPill: View {
    let pill: EncounterLabels.MetricPill

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: pill.symbol)
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: pill.tintHex))
            Text(pill.text)
                .font(ClickTypography.caption.weight(.medium))
                .foregroundStyle(ClickColors.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(ClickColors.fillSubtle, in: Capsule())
        .overlay(Capsule().stroke(ClickColors.separator, lineWidth: 1))
    }
}

extension String {
    var nonEmptyTrimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
