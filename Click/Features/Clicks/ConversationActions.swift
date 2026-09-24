import SwiftUI

/// An action that needs confirmation or input before it runs.
enum PendingConversationAction: Identifiable {
    case remove(ConnectionItem)
    case block(userID: String, name: String, connectionID: String?)
    case report(connectionID: String, name: String)
    case renameGroup(CliqueItem)
    case leaveGroup(CliqueItem)
    case deleteGroup(CliqueItem)
    case leaveHub(JoinedHub)
    case deleteHub(JoinedHub)

    var id: String {
        switch self {
        case .remove(let item): "remove.\(item.id)"
        case .block(let userID, _, _): "block.\(userID)"
        case .report(let connectionID, _): "report.\(connectionID)"
        case .renameGroup(let group): "rename.\(group.id)"
        case .leaveGroup(let group): "leave.\(group.id)"
        case .deleteGroup(let group): "delete.\(group.id)"
        case .leaveHub(let hub): "leavehub.\(hub.hubID)"
        case .deleteHub(let hub): "deletehub.\(hub.hubID)"
        }
    }

    /// Leaving the conversation screen afterwards (block, remove, leave, delete).
    var endsConversation: Bool {
        switch self {
        case .report, .renameGroup: false
        default: true
        }
    }
}

/// Report reasons offered everywhere a report can be filed.
enum ReportReason: String, CaseIterable, Identifiable {
    case spam = "Spam"
    case harassment = "Harassment or bullying"
    case inappropriate = "Inappropriate content"
    case impersonation = "Fake profile or impersonation"
    case safety = "I feel unsafe"
    case other = "Something else"
    var id: String { rawValue }
}

/// Direct-conversation actions (1:1). Menu content only, so the same list serves the inbox
/// context menu and the chat header menu.
struct DirectConversationActions: View {
    let item: ConnectionItem
    let model: ConversationListModel
    @Binding var pending: PendingConversationAction?
    var includesProfile = true
    var onProfile: () -> Void = {}

    var body: some View {
        if item.awaitsPriorResponse {
            Section("\(item.displayName) says you already know each other") {
                Button("Accept", systemImage: "checkmark") {
                    Task { try? await model.respondToPrior(item, accept: true) }
                }
                Button("Decline", systemImage: "xmark", role: .destructive) {
                    Task { try? await model.respondToPrior(item, accept: false) }
                }
            }
        }
        if includesProfile {
            Button("View Profile", systemImage: "person.crop.circle", action: onProfile)
        }
        let isArchived = model.archived.contains { $0.id == item.id }
        if !isArchived {
            Button(item.isCore ? "Remove from Core" : "Add to Core", systemImage: item.isCore ? "star.slash" : "star") {
                Task { await model.setCore(item, isCore: !item.isCore) }
            }
        }
        if item.chatID?.isEmpty == false {
            Button("Mark Unread", systemImage: "envelope.badge") {
                Task { await model.markUnread(item) }
            }
        }
        Button(isArchived ? "Unarchive" : "Archive", systemImage: isArchived ? "tray.and.arrow.up" : "archivebox") {
            Task { await model.setArchived(item, archived: !isArchived) }
        }
        Section {
            Button("Report", systemImage: "exclamationmark.bubble") {
                pending = .report(connectionID: item.connectionID, name: item.displayName)
            }
            Button("Remove Connection", systemImage: "person.badge.minus", role: .destructive) {
                pending = .remove(item)
            }
            Button("Block", systemImage: "hand.raised", role: .destructive) {
                pending = .block(userID: item.userID, name: item.displayName, connectionID: item.connectionID)
            }
        }
    }
}

struct GroupConversationActions: View {
    let group: CliqueItem
    let model: ConversationListModel
    let currentUserID: String?
    @Binding var pending: PendingConversationAction?
    var onInfo: (() -> Void)?

    var body: some View {
        if let onInfo {
            Button("Group Info", systemImage: "info.circle", action: onInfo)
        }
        Button("Mark Unread", systemImage: "envelope.badge") {
            Task { await model.markUnread(group) }
        }
        let isCreator = group.createdBy != nil && group.createdBy == currentUserID
        if isCreator {
            Button("Rename", systemImage: "pencil") { pending = .renameGroup(group) }
        }
        Section {
            Button("Leave Group", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                pending = .leaveGroup(group)
            }
            if isCreator {
                Button("Delete Group", systemImage: "trash", role: .destructive) { pending = .deleteGroup(group) }
            }
        }
    }
}

struct HubConversationActions: View {
    let hub: JoinedHub
    let currentUserID: String?
    @Binding var pending: PendingConversationAction?

    var body: some View {
        Button(hub.isEvent ? "Leave Event Chat" : "Leave Hub", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
            pending = .leaveHub(hub)
        }
        if hub.creatorID != nil, hub.creatorID == currentUserID {
            Button("Delete Hub", systemImage: "trash", role: .destructive) { pending = .deleteHub(hub) }
        }
    }
}

/// Confirmation dialogs, report reasons and rename input for `PendingConversationAction`.
/// Hosts: the inbox and the chat screen. `onEnded` runs after an action that removes the
/// conversation succeeded (the chat screen pops itself).
struct ConversationActionDialogs: ViewModifier {
    let model: ConversationListModel
    @Binding var pending: PendingConversationAction?
    var onEnded: () -> Void = {}

    @State private var renameText = ""
    @State private var renaming: CliqueItem?
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                title,
                isPresented: Binding(get: { pending != nil && !isRename }, set: { if !$0 { pending = nil } }),
                titleVisibility: .visible,
                presenting: pending
            ) { action in
                switch action {
                case .report:
                    ForEach(ReportReason.allCases) { reason in
                        Button(reason.rawValue) { run(action, reason: reason.rawValue) }
                    }
                default:
                    Button(confirmLabel(action), role: .destructive) { run(action) }
                }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: { action in
                Text(message(action))
            }
            .onChange(of: pending?.id) { _, _ in
                if case .renameGroup(let group)? = pending {
                    renameText = group.name
                    renaming = group
                    pending = nil
                }
            }
            .alert("Rename group", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Group name", text: $renameText)
                Button("Save") {
                    guard let group = renaming, let name = renameText.nonEmptyTrimmed else { return }
                    renaming = nil
                    Task {
                        do { try await model.renameGroup(group, to: name) } catch { failure = "Couldn't rename the group. \(error.userFacingMessage)" }
                    }
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .alert("That didn't go through", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
    }

    private var isRename: Bool {
        if case .renameGroup? = pending { return true }
        return false
    }

    private var title: String {
        switch pending {
        case .remove(let item)?: "Remove \(item.displayName)?"
        case .block(_, let name, _)?: "Block \(name)?"
        case .report(_, let name)?: "Report \(name)"
        case .leaveGroup(let group)?: "Leave \(group.name)?"
        case .deleteGroup(let group)?: "Delete \(group.name)?"
        case .leaveHub(let hub)?: "Leave \(hub.name)?"
        case .deleteHub(let hub)?: "Delete \(hub.name)?"
        case .renameGroup?, nil: ""
        }
    }

    private func confirmLabel(_ action: PendingConversationAction) -> String {
        switch action {
        case .remove: "Remove Connection"
        case .block: "Block"
        case .leaveGroup, .leaveHub: "Leave"
        case .deleteGroup, .deleteHub: "Delete for Everyone"
        case .report, .renameGroup: ""
        }
    }

    private func message(_ action: PendingConversationAction) -> String {
        switch action {
        case .remove: "They won't be notified. The conversation and map pin are removed for you."
        case .block: "They won't be able to message you, and this conversation is removed."
        case .report: "Reports are reviewed by Click's safety team. They won't know it was you."
        case .leaveGroup: "You'll stop receiving messages from this group."
        case .deleteGroup: "This deletes the group and its messages for every member."
        case .leaveHub: "You can rejoin while you're nearby."
        case .deleteHub: "This deletes the hub and its messages for everyone."
        case .renameGroup: ""
        }
    }

    private func run(_ action: PendingConversationAction, reason: String? = nil) {
        pending = nil
        Task {
            do {
                switch action {
                case .remove(let item): try await model.hideConnection(connectionID: item.connectionID)
                case .block(let userID, _, let connectionID): try await model.block(userID: userID, connectionID: connectionID)
                case .report(let connectionID, _): try await model.report(connectionID: connectionID, reason: reason ?? ReportReason.other.rawValue)
                case .leaveGroup(let group): try await model.leaveGroup(group)
                case .deleteGroup(let group): try await model.deleteGroup(group)
                case .leaveHub(let hub): try await model.leaveHub(id: hub.hubID)
                case .deleteHub(let hub): try await model.deleteHub(id: hub.hubID)
                case .renameGroup: return
                }
                if case .report = action { ClickHaptics.success() }
                if action.endsConversation { onEnded() }
            } catch {
                if !error.isCancellation { failure = error.userFacingMessage }
            }
        }
    }
}

/// Applies the dialogs only when the shell's inbox model is available (previews have none).
struct OptionalConversationActionDialogs: ViewModifier {
    let model: ConversationListModel?
    @Binding var pending: PendingConversationAction?
    var onEnded: () -> Void = {}

    func body(content: Content) -> some View {
        if let model {
            content.conversationActionDialogs(model: model, pending: $pending, onEnded: onEnded)
        } else {
            content
        }
    }
}

extension View {
    func conversationActionDialogs(model: ConversationListModel, pending: Binding<PendingConversationAction?>, onEnded: @escaping () -> Void = {}) -> some View {
        modifier(ConversationActionDialogs(model: model, pending: pending, onEnded: onEnded))
    }
}
