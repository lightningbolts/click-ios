import SwiftUI

/// In-chat search over the decrypted, loaded timeline (spec §34). Stepping past the oldest match
/// loads the previous page and searches again.
struct ChatSearchBar: View {
    @Binding var query: String
    let matchCount: Int
    let position: Int?
    let canSearchOlder: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onDone: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(ClickColors.textSecondary)
            TextField("Search this chat", text: $query)
                .focused($focused)
                .submitLabel(.search)
                .onSubmit(onPrevious)
                .autocorrectionDisabled()
            Text(counter)
                .font(ClickTypography.caption)
                .foregroundStyle(ClickColors.textSecondary)
                .monospacedDigit()
                .fixedSize()
            Button(action: onPrevious) { Image(systemName: "chevron.up") }
                .disabled(matchCount == 0 && !canSearchOlder)
                .accessibilityLabel("Older match")
            Button(action: onNext) { Image(systemName: "chevron.down") }
                .disabled(position.map { $0 >= matchCount - 1 } ?? true)
                .accessibilityLabel("Newer match")
            Button("Done", action: onDone).font(ClickTypography.supportingEmphasized)
        }
        .font(ClickTypography.body)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ClickColors.surfaceElevated, in: RoundedRectangle(cornerRadius: ClickRadius.compact, style: .continuous))
        .onAppear { focused = true }
    }

    private var counter: String {
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else { return "" }
        if matchCount == 0 { return canSearchOlder ? "Not loaded" : "No results" }
        return position.map { "\(matchCount - $0) of \(matchCount)" } ?? "\(matchCount)"
    }
}

/// WhatsApp-style reaction details. Tapping a reaction chip opens this sheet; removing an
/// existing reaction is an explicit action on the current user's row rather than the chip itself.
struct ReactorsSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let reactions: [ReactionSummary]
    let initial: String
    let currentUserID: String
    let onRemoveOwnReaction: (String) -> Void
    let onAddReaction: () -> Void

    @State private var people: [String: UserIdentity] = [:]
    @State private var selected: String

    init(
        reactions: [ReactionSummary],
        initial: String,
        currentUserID: String,
        onRemoveOwnReaction: @escaping (String) -> Void,
        onAddReaction: @escaping () -> Void
    ) {
        self.reactions = reactions
        self.initial = initial
        self.currentUserID = currentUserID
        self.onRemoveOwnReaction = onRemoveOwnReaction
        self.onAddReaction = onAddReaction
        _selected = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ClickColors.textPrimary)
                .padding(.top, 24)
                .padding(.bottom, 18)

            reactionTabs
                .padding(.horizontal, 16)
                .padding(.bottom, 14)

            Divider()
                .overlay(ClickColors.separator)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(selectedUserIDs, id: \.self) { id in
                        reactorRow(id)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(ClickColors.surface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            let ids = Set(reactions.flatMap(\.userIDs))
            people = await env.identities.resolve(Array(ids))
        }
    }

    private var totalCount: Int {
        reactions.reduce(0) { $0 + $1.count }
    }

    private var title: String {
        "\(totalCount) \(totalCount == 1 ? "Reaction" : "Reactions")"
    }

    private var selectedReaction: ReactionSummary? {
        reactions.first { $0.reactionType == selected }
    }

    private var selectedUserIDs: [String] {
        guard let reaction = selectedReaction else { return [] }
        var ids = reaction.userIDs
        if !currentUserID.isEmpty, let ownIndex = ids.firstIndex(of: currentUserID) {
            ids.remove(at: ownIndex)
            ids.insert(currentUserID, at: 0)
        } else if reaction.userReacted, !currentUserID.isEmpty {
            ids.insert(currentUserID, at: 0)
        }
        return ids
    }

    private var reactionTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button {
                    ClickHaptics.impact(.light)
                    dismiss()
                    DispatchQueue.main.async { onAddReaction() }
                } label: {
                    ZStack {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 20, weight: .medium))
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .offset(x: 10, y: -8)
                    }
                    .foregroundStyle(ClickColors.textSecondary)
                    .frame(width: 54, height: 38)
                    .background(ClickColors.fillSubtle, in: Capsule())
                    .overlay {
                        Capsule().stroke(ClickColors.separator, lineWidth: ClickMetrics.strokeWidth)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add reaction")

                ForEach(reactions) { reaction in
                    Button {
                        withAnimation(ClickMotion.selection) {
                            selected = reaction.reactionType
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Text(reaction.reactionType)
                                .font(.system(size: 20))
                            Text("\(reaction.count)")
                                .font(ClickTypography.supportingEmphasized)
                                .monospacedDigit()
                        }
                        .foregroundStyle(ClickColors.textPrimary)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(
                            selected == reaction.reactionType
                                ? ClickColors.selectionTint
                                : ClickColors.fillSubtle,
                            in: Capsule()
                        )
                        .overlay {
                            Capsule().stroke(
                                selected == reaction.reactionType
                                    ? ClickColors.accentForeground.opacity(0.5)
                                    : ClickColors.separator,
                                lineWidth: ClickMetrics.strokeWidth
                            )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func reactorRow(_ id: String) -> some View {
        let isCurrentUser = id == currentUserID
        Button {
            guard isCurrentUser else { return }
            ClickHaptics.impact(.light)
            let reaction = selected
            dismiss()
            DispatchQueue.main.async { onRemoveOwnReaction(reaction) }
        } label: {
            HStack(spacing: 12) {
                AvatarView(
                    imageURL: people[id]?.avatarURL,
                    seed: id,
                    initials: String((people[id]?.name ?? "?").prefix(1)),
                    size: 42
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(isCurrentUser ? "You" : people[id]?.name ?? "Click user")
                        .font(ClickTypography.bodyEmphasized)
                        .foregroundStyle(ClickColors.textPrimary)

                    if isCurrentUser {
                        Text("Tap to remove")
                            .font(ClickTypography.supporting)
                            .foregroundStyle(ClickColors.textSecondary)
                    }
                }

                Spacer()

                Text(selected)
                    .font(.system(size: 24))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(isCurrentUser ? "Removes your reaction" : "")
    }
}

/// "New messages" divider above the first message that was unread when the chat opened.
struct UnreadDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(ClickColors.accentForeground.opacity(0.4)).frame(height: 1)
            Text("New messages")
                .font(ClickTypography.metadataEmphasized)
                .foregroundStyle(ClickColors.accentForeground)
                .fixedSize()
            Rectangle().fill(ClickColors.accentForeground.opacity(0.4)).frame(height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityAddTraits(.isHeader)
    }
}

/// New-Click panel: the 48-hour "say hi" warning (server deadline, never a local expiry) plus
/// icebreakers that send as ordinary messages (spec §42–43).
struct SayHiPanel: View {
    let deadline: Date?
    let context: String?
    let seed: String
    let onSend: (String) -> Void
    @State private var shuffle = 0
    @State private var cooldownUntil: Date?
    @State private var dismissed = false

    var body: some View {
        if !dismissed {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    if let deadline, let remaining = InboxFormatting.sayHiRemaining(until: deadline) {
                        Label("Say hi · \(remaining) before this Click moves to Archived", systemImage: "hourglass")
                            .font(ClickTypography.metadataEmphasized)
                            .foregroundStyle(ClickColors.warning)
                    } else {
                        Label("Break the ice", systemImage: "sparkles")
                            .font(ClickTypography.metadataEmphasized)
                            .foregroundStyle(ClickColors.textSecondary)
                    }
                    Spacer()
                    Button { withAnimation(ClickMotion.subtleFade) { dismissed = true } } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ClickColors.textSecondary)
                    .accessibilityLabel("Hide icebreakers")
                }
                ForEach(prompts, id: \.self) { prompt in
                    Button {
                        ClickHaptics.impact(.light)
                        cooldownUntil = .now.addingTimeInterval(Icebreakers.cooldown)
                        onSend(prompt)
                    } label: {
                        Text(prompt)
                            .font(ClickTypography.supporting)
                            .foregroundStyle(ClickColors.textPrimary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(ClickColors.fillSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Sends this message")
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let wait = cooldownUntil.map { Int($0.timeIntervalSince(context.date).rounded(.up)) } ?? 0
                    Button(wait > 0 ? "New ideas in \(wait)s" : "New ideas", systemImage: "arrow.triangle.2.circlepath") {
                        shuffle += 1
                        cooldownUntil = .now.addingTimeInterval(Icebreakers.cooldown)
                    }
                    .font(ClickTypography.supportingEmphasized)
                    .disabled(wait > 0)
                }
            }
            .padding(14)
            .background(ClickColors.surfaceElevated, in: RoundedRectangle(cornerRadius: ClickRadius.compact, style: .continuous))
            .transition(.opacity)
        }
    }

    private var prompts: [String] {
        Icebreakers.prompts(context: context, seed: "\(seed)#\(shuffle)")
    }
}

/// Small visual for the message a reply quotes: the photo itself, the event image, or a kind
/// icon for voice notes and files. Shared by bubble quotes and the composer's reply strip.
/// The chat's pinned message, above the timeline: tap to jump to it (then to the next pin).
struct PinnedMessageBanner: View {
    /// The pinned text when it's in the loaded timeline.
    let text: String?
    let position: Int
    let count: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ClickColors.accentForeground)
                    .rotationEffect(.degrees(45))
                VStack(alignment: .leading, spacing: 1) {
                    Text(count > 1 ? "Pinned · \(position + 1) of \(count)" : "Pinned")
                        .font(ClickTypography.metadataEmphasized)
                        .foregroundStyle(ClickColors.accentForeground)
                        .contentTransition(.numericText())
                    Text(text?.nonEmptyTrimmed ?? "Pinned message")
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanelBackground(cornerRadius: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pinned message\(count > 1 ? " \(position + 1) of \(count)" : ""): \(text ?? "")")
        .accessibilityHint("Shows it in the chat")
    }
}

/// A conversation's pinned messages, for its profile: tap one to see it in the chat.
struct PinnedMessagesList: View {
    @Environment(AppEnvironment.self) private var env
    let model: ConversationModel
    @State private var messages: [ChatMessageItem]?

    var body: some View {
        Group {
            if let messages, model.hasLoadedPins || !messages.isEmpty {
                if messages.isEmpty {
                    Text("Nothing pinned yet. Touch and hold a message in the chat to pin it.")
                        .font(ClickTypography.supporting)
                        .foregroundStyle(ClickColors.textTertiary)
                        .padding(.vertical, 6)
                }
                ForEach(messages) { message in
                    Button {
                        env.router.navigate(to: .conversation(chatID: message.chatID, messageID: message.id))
                    } label: {
                        row(message)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Unpin", systemImage: "pin.slash") { Task { await model.togglePin(message) } }
                    }
                }
            } else {
                ClickLoadingView(size: 26, fillsSpace: false)
            }
        }
        .task { await model.loadPins() }
        .task(id: model.pins) { messages = await model.pinnedMessages() }
    }

    private func row(_ message: ChatMessageItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "pin.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ClickColors.accentForeground)
                .rotationEffect(.degrees(45))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(message.isOutgoing ? "You" : message.senderName)
                        .font(ClickTypography.supportingEmphasized)
                        .foregroundStyle(ClickColors.textPrimary)
                    Spacer()
                    Text(message.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(ClickTypography.metadata)
                        .foregroundStyle(ClickColors.textTertiary)
                }
                Text(ConversationModel.quoteText(message))
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows it in the chat")
    }
}

struct ReplyThumbnail: View {
    let target: ChatMessageItem
    var load: ((ChatMessageItem) async throws -> URL)?
    var size: CGFloat = 36
    @State private var image: UIImage?

    init(target: ChatMessageItem, load: ((ChatMessageItem) async throws -> URL)? = nil, size: CGFloat = 36) {
        self.target = target
        self.load = load
        self.size = size
        // The quoted photo is usually decoded already (its own bubble, an earlier render).
        _image = State(initialValue: (DecodedMediaCache.entry(Self.cacheKey(target)) ?? DecodedMediaCache.entry(target.id))?.image)
    }

    private static func cacheKey(_ target: ChatMessageItem) -> String { target.id + "#reply" }

    var body: some View {
        Group {
            if let beacon = target.beacon {
                EventVisual(seed: beacon.beaconID, imageURL: beacon.imageURL, symbol: beacon.kind.systemImage, cornerRadius: 6)
            } else if let media = target.media {
                switch media.kind {
                case .image:
                    if let image, !media.isLocked() {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        icon(media.isLocked() ? "hourglass" : "photo")
                    }
                case .audio: icon("mic.fill")
                case .file: icon("doc.fill")
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
        .task(id: target.id) {
            guard target.media?.kind == .image, target.media?.isLocked() == false, image == nil else { return }
            let url = target.localMediaURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            var file = url
            if file == nil, let load { file = try? await load(target) }
            guard let file else { return }
            image = await DecodedMediaCache.thumbnail(of: file, side: size * 3, key: Self.cacheKey(target))
        }
    }

    /// Whether the quoted message has anything visual to show.
    static func applies(to target: ChatMessageItem?) -> Bool {
        target?.beacon != nil || target?.media != nil
    }

    private func icon(_ name: String) -> some View {
        ZStack {
            ClickColors.fillSubtle
            Image(systemName: name).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(ClickColors.textSecondary)
        }
    }
}

/// Horizontal-only pan for swipe-to-reply.
///
/// - Begins only when the first movement is sideways *in the reply direction*; anything else
///   fails immediately so the timeline scrolls and the back-swipe works untouched.
/// - Once it begins, it cancels the enclosing scroll view's pan (so the timeline doesn't drift
///   vertically mid-swipe) and cancels touches underneath (a swipe never opens a photo).
/// - The navigation back-swipe waits for it to fail, so a rightward swipe on an incoming bubble
///   replies instead of popping the chat. Touches in the leading 24 pt stay with the edge swipe.
/// Blocks the taps a press-and-hold would otherwise trigger on release. SwiftUI buttons inside a
/// bubble (photo, Click Drop, file, event card, play, retry) ignore UIKit touch cancellation,
/// so every tap action inside a bubble asks `allowsTap` first. Global because only one finger
/// can hold a bubble at a time.
@MainActor
enum BubbleTapGate {
    private static var holdID = 0
    private static var isHolding = false
    private static var heldSince = Date.distantPast

    /// A hold whose end never arrived (its cell was recycled mid-press) stops blocking taps
    /// after a few seconds.
    static var allowsTap: Bool { !isHolding || Date().timeIntervalSince(heldSince) > 5 }

    static func beginHold() {
        holdID += 1
        isHolding = true
        heldSince = Date()
    }

    /// The release's tap lands at about the same moment as the recognizer's end; stay closed
    /// briefly so it is swallowed whichever arrives first.
    static func endHold() {
        let id = holdID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if holdID == id { isHolding = false }
        }
    }

    /// Wraps a tap action so it is ignored when it is the release of a press-and-hold.
    static func gated(_ action: @escaping () -> Void) -> () -> Void {
        { if allowsTap { action() } }
    }
}

/// Press-and-hold that fires while the finger is still down, on every bubble kind. A SwiftUI
/// long press on the bubble loses to child buttons (photos, event cards) and waits for the
/// swipe-to-reply pan to fail, which only happens on release.
struct PressAndHoldGesture: UIGestureRecognizerRepresentable {
    var minimumDuration: TimeInterval = 0.3
    var allowableMovement: CGFloat = 12
    let onBegan: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = minimumDuration
        recognizer.allowableMovement = allowableMovement
        // Once held, the press owns the touch: the photo/card under it must not open on release.
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began:
            BubbleTapGate.beginHold()
            onBegan()
        case .ended, .cancelled:
            BubbleTapGate.endHold()
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

struct HorizontalSwipeGesture: UIGestureRecognizerRepresentable {
    var isEnabled = true
    /// Incoming bubbles swipe right (+1), outgoing swipe left (-1).
    var direction: CGFloat = 1
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false
        recognizer.maximumNumberOfTouches = 1
        recognizer.isEnabled = isEnabled
        context.coordinator.direction = direction
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
        context.coordinator.direction = direction
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began:
            context.coordinator.cancelEnclosingScroll(from: recognizer.view)
            onChanged(recognizer.translation(in: recognizer.view).x)
        case .changed: onChanged(recognizer.translation(in: recognizer.view).x)
        case .ended, .cancelled, .failed: onEnded()
        default: break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var direction: CGFloat = 1

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let window = touch.window else { return true }
            let x = touch.location(in: window).x
            // Leave the screen edges to the system back gesture.
            return x > 24 && x < window.bounds.width - 12
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            let translation = pan.translation(in: pan.view)
            // Velocity is noisy on the first sample; fall back to the translation so far.
            let dx = abs(velocity.x) + abs(velocity.y) > 1 ? velocity.x : translation.x
            let dy = abs(velocity.x) + abs(velocity.y) > 1 ? velocity.y : translation.y
            return dx * direction > 0 && abs(dx) > abs(dy)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Only the timeline's own pan may run alongside until this one takes over.
            other.view is UIScrollView && other is UIPanGestureRecognizer && !Self.isPopGesture(other, near: gestureRecognizer.view)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            Self.isPopGesture(other, near: gestureRecognizer.view)
        }

        func cancelEnclosingScroll(from view: UIView?) {
            var current = view?.superview
            while let candidate = current {
                if let scroll = candidate as? UIScrollView, scroll.panGestureRecognizer.state != .possible {
                    // Toggling cancels an in-flight pan without disabling future scrolling.
                    scroll.panGestureRecognizer.isEnabled = false
                    scroll.panGestureRecognizer.isEnabled = true
                    return
                }
                current = candidate.superview
            }
        }

        private static func isPopGesture(_ recognizer: UIGestureRecognizer, near view: UIView?) -> Bool {
            var responder: UIResponder? = view
            while let current = responder {
                if let navigation = current as? UINavigationController {
                    if recognizer === navigation.interactivePopGestureRecognizer { return true }
                    if #available(iOS 26.0, *),
                       navigation.responds(to: NSSelectorFromString("interactiveContentPopGestureRecognizer")),
                       let contentPop = navigation.value(forKey: "interactiveContentPopGestureRecognizer") as? UIGestureRecognizer,
                       recognizer === contentPop {
                        return true
                    }
                    return false
                }
                responder = current.next
            }
            return false
        }
    }
}


/// "Send Later": picks when the composer's text goes out (long-press the send button).
struct ScheduleSendSheet: View {
    let text: String
    let onSchedule: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Self.defaultDate

    /// The next quarter hour at least 15 minutes out.
    private static var defaultDate: Date {
        let soon = Date.now.addingTimeInterval(15 * 60)
        let minute = Calendar.current.component(.minute, from: soon)
        return Calendar.current.date(byAdding: .minute, value: (15 - minute % 15) % 15, to: soon) ?? soon
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(text)
                        .lineLimit(4)
                        .foregroundStyle(ClickColors.textSecondary)
                }
                DatePicker("Send at", selection: $date, in: Date.now.addingTimeInterval(60)...Date.now.addingTimeInterval(365 * 86_400))
                    .datePickerStyle(.graphical)
            }
            .navigationTitle("Send Later")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") {
                        onSchedule(date)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
    }
}

/// Compact bar above the composer: "2 scheduled messages · next Tue 9:00 AM".
struct ScheduledMessagesBar: View {
    let scheduled: [ScheduledMessage]
    let onOpen: () -> Void

    var body: some View {
        if let next = scheduled.first {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                    Text(scheduled.count == 1 ? "1 scheduled message" : "\(scheduled.count) scheduled messages")
                        .fontWeight(.semibold)
                    Text("· next \(next.sendAt.formatted(.relative(presentation: .named)))")
                        .foregroundStyle(ClickColors.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .font(ClickTypography.supporting)
                .foregroundStyle(ClickColors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(ClickColors.fillSubtle, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// This user's scheduled messages in the chat; swipe (or tap the button) to cancel one.
struct ScheduledMessagesSheet: View {
    let model: ConversationModel

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.scheduled) { message in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.sendAt.formatted(date: .abbreviated, time: .shortened))
                            .font(ClickTypography.caption)
                            .foregroundStyle(ClickColors.textSecondary)
                        Text(message.content)
                            .foregroundStyle(ClickColors.textPrimary)
                    }
                    .swipeActions {
                        Button("Cancel", systemImage: "trash", role: .destructive) {
                            Task { await model.cancelScheduled(message) }
                        }
                    }
                }
            }
            .overlay {
                if model.scheduled.isEmpty {
                    ContentUnavailableView("Nothing scheduled", systemImage: "clock")
                }
            }
            .navigationTitle("Scheduled")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

/// Instagram-style read receipts in groups: tiny avatars of the members whose latest read
/// message this is, trailing under it.
struct SeenByAvatars: View {
    let userIDs: [String]
    @Environment(AppEnvironment.self) private var env
    @State private var people: [String: UserIdentity] = [:]

    private static let size: CGFloat = 16
    private static let maxShown = 6

    var body: some View {
        HStack(spacing: -4) {
            ForEach(userIDs.prefix(Self.maxShown), id: \.self) { id in
                AvatarView(imageURL: people[id]?.avatarURL, seed: id,
                           initials: String((people[id]?.name ?? "?").prefix(1)), size: Self.size)
                    .overlay(Circle().stroke(ClickColors.background, lineWidth: 1.5))
                    .transition(.scale.combined(with: .opacity))
            }
            if userIDs.count > Self.maxShown {
                Text("+\(userIDs.count - Self.maxShown)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ClickColors.textSecondary)
                    .padding(.leading, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Seen by \(userIDs.compactMap { people[$0]?.name }.joined(separator: ", "))")
        .task(id: userIDs) { people = await env.identities.resolve(userIDs) }
    }
}
