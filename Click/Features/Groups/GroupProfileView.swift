import PhotosUI
import SwiftUI

/// Canonical verified-group profile (spec §30, §48): identity, members, shared content, and
/// management. Every membership change is confirmed by the server and followed by the E2EE
/// epoch reconciliation; the UI reports exactly which of those completed.
struct GroupProfileView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ConversationListModel.self) private var conversations
    @Environment(\.dismiss) private var dismiss

    let chatID: String

    @State private var tabs = ModuleState<SharedTabs>()
    @State private var isWorking = false
    @State private var notice: String?
    @State private var pendingRemoval: GroupMember?
    @State private var confirmLeave = false
    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var draftName = ""
    @State private var showingAddMembers = false
    @State private var photoItem: PhotosPickerItem?
    /// A server-side membership change whose encryption step still needs to complete.
    @State private var unfinishedRotation: [String]?

    private var group: CliqueItem? { conversations.groups.first { $0.chatID == chatID } }
    private var currentUserID: String? { env.session.currentSession?.userId }

    var body: some View {
        Group {
            if let group {
                content(group)
            } else if conversations.groupsLoaded {
                ContentUnavailableView(
                    "Group unavailable",
                    systemImage: "person.3",
                    description: Text(conversations.groupsError ?? "You're no longer a member of this group, or it was deleted.")
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Group")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if group == nil { await conversations.refresh() }
            await loadTabs()
        }
        .alert("Group", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    private func content(_ group: CliqueItem) -> some View {
        let isCreator = group.createdBy == currentUserID
        return List {
            headerSection(group)
            rotationSection(group)
            membersSection(group, isCreator: isCreator)
            Section("Common interests") { GroupCommonInterests(members: group.members) }
            sharedSection
            Section("Journal") { GroupJournalSection(chatID: group.chatID) }
            manageSection(group, isCreator: isCreator)
        }
        .listStyle(.insetGrouped)
        .overlay { if isWorking { ProgressView() } }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "member")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let member = pendingRemoval { Task { await remove(member, from: group) } }
            }
        } message: {
            Text("They won't be able to read new messages in this group.")
        }
        .confirmationDialog("Leave \(group.name)?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave Group", role: .destructive) { Task { await leave(group) } }
        }
        .confirmationDialog("Delete \(group.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Group", role: .destructive) { Task { await delete(group) } }
        } message: {
            Text("The group and its conversation are removed for everyone.")
        }
        .alert("Rename group", isPresented: $renaming) {
            TextField("Group name", text: $draftName)
            Button("Save") { Task { await rename(group) } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingAddMembers) {
            GroupMemberPickerSheet(
                title: "Add People",
                actionTitle: "Add",
                candidates: conversations.active.filter { item in
                    !item.userID.isEmpty && !group.members.contains { $0.userID == item.userID }
                },
                onDone: { _, ids in Task { await add(ids, to: group) } }
            )
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await uploadPhoto(item, group: group) }
        }
    }

    private func headerSection(_ group: CliqueItem) -> some View {
        Section {
            VStack(spacing: 10) {
                GroupAvatarView(
                    avatarURL: group.avatarURL,
                    seed: group.chatID,
                    initials: group.initials,
                    members: group.avatarMembers(excluding: currentUserID),
                    size: 96
                )
                Text(group.name)
                    .font(ClickTypography.identityTitle)
                    .foregroundStyle(ClickColors.textPrimary)
                    .multilineTextAlignment(.center)
                Text("\(group.memberCount) members · Verified group")
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
                Button {
                    env.router.navigate(to: .groupChat(group.chatRoute))
                } label: {
                    Label("Message", systemImage: "bubble.left.and.bubble.right.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(ClickColors.primaryActionFill)
                .controlSize(.large)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private func rotationSection(_ group: CliqueItem) -> some View {
        if let pending = unfinishedRotation {
            Section {
                Label("Membership changed, but the new encryption key isn't set up yet. New messages can't be sent until it is.", systemImage: "lock.trianglebadge.exclamationmark")
                    .font(ClickTypography.supporting)
                Button("Finish Securing Group") { Task { await reconcile(group, members: pending) } }
                    .disabled(isWorking)
            }
        }
    }

    private func membersSection(_ group: CliqueItem, isCreator: Bool) -> some View {
        Section("Members") {
            ForEach(group.members) { member in
                memberRow(member, group: group, isCreator: isCreator)
            }
            if isCreator {
                Button {
                    showingAddMembers = true
                } label: {
                    Label("Add People", systemImage: "person.badge.plus")
                }
                .disabled(isWorking)
            }
        }
    }

    private var sharedSection: some View {
        Section("Shared") {
            if let group {
                NavigationLink { GroupSharedView(group: group, kind: .media) } label: {
                    sharedRow("Media", systemImage: "photo.on.rectangle", items: tabs.value?.media)
                }
                NavigationLink { GroupSharedView(group: group, kind: .files) } label: {
                    sharedRow("Files", systemImage: "doc", items: tabs.value?.files)
                }
                NavigationLink { GroupSharedView(group: group, kind: .beacons) } label: {
                    sharedRow("Events & beacons", systemImage: "mappin.and.ellipse", items: tabs.value?.beacons)
                }
            }
            if let error = tabs.errorMessage, tabs.value == nil {
                Button("Couldn't load shared content. Retry") { Task { await loadTabs() } }
                    .font(ClickTypography.supporting)
                    .accessibilityHint(error)
            }
        }
    }

    private func manageSection(_ group: CliqueItem, isCreator: Bool) -> some View {
        Section {
            if isCreator {
                Button("Rename Group", systemImage: "pencil") {
                    draftName = group.name
                    renaming = true
                }
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Change Group Photo", systemImage: "camera")
                }
                if group.avatarURL != nil {
                    Button("Remove Group Photo", systemImage: "trash") {
                        Task { await removePhoto(group) }
                    }
                }
            }
            Button("Leave Group", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                confirmLeave = true
            }
            if isCreator {
                Button("Delete Group", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        }
        .disabled(isWorking)
    }

    private func memberRow(_ member: GroupMember, group: CliqueItem, isCreator: Bool) -> some View {
        let isSelf = member.userID == currentUserID
        return Button {
            guard !isSelf else { return }
            let connectionID = conversations.active.first { $0.userID == member.userID }?.connectionID
            env.router.navigate(to: .userProfile(userID: member.userID, connectionID: connectionID))
        } label: {
            HStack(spacing: 12) {
                AvatarView(imageURL: member.avatarURL, seed: member.userID, initials: member.initials, size: 40)
                Text(isSelf ? "\(member.name) (You)" : member.name)
                    .font(ClickTypography.body)
                    .foregroundStyle(ClickColors.textPrimary)
                Spacer()
                if member.userID == group.createdBy {
                    Text("Creator")
                        .font(ClickTypography.metadata)
                        .foregroundStyle(ClickColors.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
        .swipeActions {
            if isCreator, !isSelf {
                Button("Remove", role: .destructive) { pendingRemoval = member }
            }
        }
        .contextMenu {
            if isCreator, !isSelf {
                Button("Remove from Group", systemImage: "person.badge.minus", role: .destructive) { pendingRemoval = member }
            }
        }
    }

    private func sharedRow(_ title: String, systemImage: String, items: [SharedItem]?) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .foregroundStyle(ClickColors.textPrimary)
            Spacer()
            if let items {
                Text(items.isEmpty ? "None yet" : "\(items.count)")
                    .foregroundStyle(ClickColors.textSecondary)
                    .monospacedDigit()
            } else if tabs.isPending {
                ProgressView()
            } else {
                Text("—").foregroundStyle(ClickColors.textTertiary)
            }
        }
        .font(ClickTypography.body)
    }

    // MARK: - Actions

    private func loadTabs() async {
        tabs.begin()
        do {
            tabs.succeed(try await env.profiles.sharedTabs(chatID: chatID))
        } catch {
            tabs.fail(error)
        }
    }

    private func remove(_ member: GroupMember, from group: CliqueItem) async {
        pendingRemoval = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await env.groups.removeMember(groupID: group.id, userID: member.userID)
        } catch {
            notice = "Couldn't remove \(member.name). \(error.userFacingMessage)"
            return
        }
        let remaining = group.members.map(\.userID).filter { $0 != member.userID }
        await conversations.refresh()
        await reconcile(group, members: remaining, successNotice: "\(member.name) was removed.")
    }

    private func add(_ userIDs: [String], to group: CliqueItem) async {
        showingAddMembers = false
        guard !userIDs.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        var added: [String] = []
        var failures = 0
        for id in userIDs {
            do {
                try await env.groups.addMember(groupID: group.id, userID: id)
                added.append(id)
            } catch {
                failures += 1
            }
        }
        await conversations.refresh()
        guard !added.isEmpty else {
            notice = "Couldn't add people to this group. Try again."
            return
        }
        let suffix = failures > 0 ? " \(failures) couldn't be added." : ""
        await reconcile(
            group,
            members: group.members.map(\.userID) + added,
            successNotice: "Added \(added.count) \(added.count == 1 ? "person" : "people").\(suffix)"
        )
    }

    /// Rotates (or confirms) the E2EE epoch for the new member set. Membership is not reported
    /// as complete until this succeeds (spec §30).
    private func reconcile(_ group: CliqueItem, members: [String], successNotice: String? = nil) async {
        isWorking = true
        defer { isWorking = false }
        do {
            switch try await env.chat.reconcileMembershipEpoch(chatID: group.chatID, participantUserIDs: members) {
            case .current:
                unfinishedRotation = nil
                notice = successNotice.map { "\($0) New messages use a fresh encryption key." }
            case .notUpgraded:
                unfinishedRotation = nil
                notice = successNotice.map {
                    "\($0) This group still uses legacy encryption because not everyone has updated Click, so earlier group keys aren't rotated."
                }
            }
        } catch {
            unfinishedRotation = members
            notice = "The membership change was saved, but securing the group failed: \(error.localizedDescription)"
        }
    }

    private func leave(_ group: CliqueItem) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await conversations.leaveGroup(group)
            env.router.resetCurrentTabPath()
        } catch {
            notice = "Couldn't leave the group. \(error.userFacingMessage)"
        }
    }

    private func delete(_ group: CliqueItem) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await conversations.deleteGroup(group)
            env.router.resetCurrentTabPath()
        } catch {
            notice = "Couldn't delete the group. \(error.userFacingMessage)"
        }
    }

    private func rename(_ group: CliqueItem) async {
        guard let name = draftName.nonEmptyTrimmed, name != group.name else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await conversations.renameGroup(group, to: name)
        } catch {
            notice = "Couldn't rename the group. \(error.userFacingMessage)"
        }
    }

    private func removePhoto(_ group: CliqueItem) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await env.groups.removeAvatar(groupID: group.id)
            await conversations.refresh()
        } catch {
            notice = "Couldn't remove the group photo. \(error.userFacingMessage)"
        }
    }

    private func uploadPhoto(_ item: PhotosPickerItem, group: CliqueItem) async {
        photoItem = nil
        isWorking = true
        defer { isWorking = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let jpeg = try env.avatarService.prepareImageData(data)
            _ = try await env.groups.uploadAvatar(groupID: group.id, jpeg: jpeg)
            await conversations.refresh()
        } catch {
            notice = "Couldn't update the group photo. \(error.userFacingMessage)"
        }
    }
}

/// Eligible-member picker: only the viewer's active Clicks (the server re-validates the graph).
/// With `asksForName`, it also collects a group name (manual group creation).
struct GroupMemberPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let actionTitle: String
    let candidates: [ConnectionItem]
    var asksForName = false
    /// Explanatory copy shown above the list.
    var explanation: String? = nil
    let onDone: (_ name: String, _ userIDs: [String]) -> Void
    /// Why someone can't be added given the current selection (nil = eligible).
    var ineligibleReason: (_ userID: String, _ selected: Set<String>) -> String? = { _, _ in nil }
    var onSelectionChange: ((Set<String>) -> Void)?

    @State private var selected: Set<String> = []
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                if asksForName {
                    Section {
                        TextField("Group name (optional)", text: $name)
                    }
                }
                Section {
                    ForEach(candidates) { item in
                        let reason = ineligibleReason(item.userID, selected)
                        Button {
                            if selected.contains(item.userID) { selected.remove(item.userID) } else { selected.insert(item.userID) }
                            ClickHaptics.selection()
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(imageURL: item.avatarUrl, seed: item.userID, initials: item.initials, size: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.displayName).foregroundStyle(ClickColors.textPrimary)
                                    if let reason {
                                        Text(reason)
                                            .font(ClickTypography.supporting)
                                            .foregroundStyle(ClickColors.warning)
                                    } else if let detail = Self.detail(item) {
                                        Text(detail)
                                            .font(ClickTypography.supporting)
                                            .foregroundStyle(ClickColors.textSecondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: selected.contains(item.userID) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(item.userID) ? ClickColors.accentForeground : ClickColors.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(reason != nil && !selected.contains(item.userID))
                        .opacity(reason != nil && !selected.contains(item.userID) ? 0.55 : 1)
                    }
                } header: {
                    if let explanation {
                        Text(explanation)
                            .font(ClickTypography.supporting)
                            .foregroundStyle(ClickColors.textSecondary)
                            .textCase(nil)
                            .padding(.bottom, 4)
                    }
                }
            }
            .overlay {
                if candidates.isEmpty {
                    ContentUnavailableView("No one to add", systemImage: "person.2", description: Text("Only people you've Clicked with can join."))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: selected) { _, now in onSelectionChange?(now) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle) { onDone(name, Array(selected)) }
                        .disabled(selected.isEmpty || selected.contains { ineligibleReason($0, selected) != nil })
                }
            }
        }
    }

    static func detail(_ item: ConnectionItem) -> String? {
        if item.isCore { return "Core Click" }
        return item.encounterLocation.nonEmptyTrimmed.map { "Met at \($0)" }
    }
}
