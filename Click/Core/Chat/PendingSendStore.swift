import Foundation

/// What a pending row needs to be (re)sent besides its text: a media draft or a shared beacon.
public enum PendingSendPayload: Sendable {
    case media(MediaDraft)
    case beacon(MapBeacon)
}

/// Receives pending-send changes for the conversation currently on screen.
@MainActor
public protocol PendingSendReceiver: AnyObject {
    func pendingSendChanged(_ item: ChatMessageItem)
    func pendingSendFinished(clientID: String, serverItem: ChatMessageItem)
}

/// Optimistic rows and their drafts, owned outside any one screen so a send (and its upload)
/// keeps going when the chat closes and its row is restored when the chat reopens.
///
/// Keyed by conversation and client message ID; a retry reuses the same client ID, so it can
/// never produce a duplicate row.
@MainActor
public final class PendingSendStore {
    private final class WeakReceiver {
        weak var value: (any PendingSendReceiver)?
        init(_ value: any PendingSendReceiver) { self.value = value }
    }

    private var rows: [String: [String: ChatMessageItem]] = [:]
    private var payloads: [String: PendingSendPayload] = [:]
    private var receivers: [String: WeakReceiver] = [:]

    public init() {}

    /// The screen showing `chatID`; returns the rows it should restore.
    /// Makes `receiver` the target without restoring rows (used right before a send).
    public func ensureAttached(_ receiver: any PendingSendReceiver, chatID: String) {
        if receivers[chatID]?.value !== receiver { receivers[chatID] = WeakReceiver(receiver) }
    }

    public func attach(_ receiver: any PendingSendReceiver, chatID: String) -> [ChatMessageItem] {
        receivers[chatID] = WeakReceiver(receiver)
        return (rows[chatID] ?? [:]).values.sorted { $0.createdAt < $1.createdAt }
    }

    public func detach(_ receiver: any PendingSendReceiver, chatID: String) {
        if receivers[chatID]?.value === receiver { receivers[chatID] = nil }
    }

    public func add(_ item: ChatMessageItem, chatID: String, payload: PendingSendPayload?) {
        rows[chatID, default: [:]][item.id] = item
        if let payload { payloads[item.id] = payload }
        receivers[chatID]?.value?.pendingSendChanged(item)
    }

    public func update(clientID: String, chatID: String, _ change: (inout ChatMessageItem) -> Void) {
        guard var item = rows[chatID]?[clientID] else { return }
        change(&item)
        rows[chatID]?[clientID] = item
        receivers[chatID]?.value?.pendingSendChanged(item)
    }

    public func finish(clientID: String, chatID: String, serverItem: ChatMessageItem) {
        rows[chatID]?[clientID] = nil
        payloads[clientID] = nil
        receivers[chatID]?.value?.pendingSendFinished(clientID: clientID, serverItem: serverItem)
    }

    /// Drops a failed row the user removed.
    public func discard(clientID: String, chatID: String) {
        rows[chatID]?[clientID] = nil
        payloads[clientID] = nil
    }

    public func item(clientID: String, chatID: String) -> ChatMessageItem? {
        rows[chatID]?[clientID]
    }

    public func payload(for clientID: String) -> PendingSendPayload? {
        payloads[clientID]
    }

    public func removeAll() {
        rows.removeAll()
        payloads.removeAll()
    }
}
