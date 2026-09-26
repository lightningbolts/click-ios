import SwiftUI

/// Native chat composer using Click's Functional Clarity surfaces and iOS keyboard behavior.
public struct ChatComposerView: View {
    @Binding var text: String
    let placeholder: String
    let replyTarget: ChatMessageItem?
    let editTarget: ChatMessageItem?
    let isSending: Bool
    let onCancelReply: () -> Void
    let onCancelEdit: () -> Void
    let onSend: () -> Void
    let onTypingChanged: (Bool) -> Void
    /// Nil hides attachments and voice notes.
    let onDraft: ((MediaDraft) -> Void)?
    /// Hubs take photos and Click Drops only (KMP parity): no voice notes or files.
    let photosOnly: Bool
    /// Loads a quoted photo for the reply strip's thumbnail.
    var replyMediaLoader: ((ChatMessageItem) async throws -> URL)?
    let onAttachmentError: (String) -> Void
    let onShareBeacon: (() -> Void)?
    /// Attachments waiting to be sent; the send button sends them, then the text as a caption.
    let staged: [StagedAttachment]
    let onUnstage: (UUID) -> Void
    /// Long-press on send offers "Send Later" (text only). Nil where scheduling isn't supported.
    let onScheduleSend: (() -> Void)?

    @FocusState private var isFocused: Bool
    @State private var recorder = VoiceNoteRecorder()
    private let characterLimit = 1000

    public init(
        text: Binding<String>,
        placeholder: String = "Message…",
        replyTarget: ChatMessageItem? = nil,
        editTarget: ChatMessageItem? = nil,
        isSending: Bool = false,
        onCancelReply: @escaping () -> Void,
        onCancelEdit: @escaping () -> Void,
        onSend: @escaping () -> Void,
        onTypingChanged: @escaping (Bool) -> Void = { _ in },
        onDraft: ((MediaDraft) -> Void)? = nil,
        onAttachmentError: @escaping (String) -> Void = { _ in },
        onShareBeacon: (() -> Void)? = nil,
        staged: [StagedAttachment] = [],
        onUnstage: @escaping (UUID) -> Void = { _ in },
        photosOnly: Bool = false,
        replyMediaLoader: ((ChatMessageItem) async throws -> URL)? = nil,
        onScheduleSend: (() -> Void)? = nil
    ) {
        self.onScheduleSend = onScheduleSend
        self.photosOnly = photosOnly
        self.replyMediaLoader = replyMediaLoader
        self.staged = staged
        self.onUnstage = onUnstage
        self.onShareBeacon = onShareBeacon
        self.onDraft = onDraft
        self.onAttachmentError = onAttachmentError
        self._text = text
        self.placeholder = placeholder
        self.replyTarget = replyTarget
        self.editTarget = editTarget
        self.isSending = isSending
        self.onCancelReply = onCancelReply
        self.onCancelEdit = onCancelEdit
        self.onSend = onSend
        self.onTypingChanged = onTypingChanged
    }

    private var remainingCharacters: Int {
        characterLimit - text.count
    }

    private enum TrailingMode: Equatable { case mic, send, save, disabled }

    private var trailingMode: TrailingMode {
        if editTarget != nil { return canSend ? .save : .disabled }
        if canSend { return .send }
        return onDraft != nil && !photosOnly ? .mic : .disabled
    }

    /// One control that morphs between mic, send and save, so it keeps its identity (and
    /// position) instead of one button being swapped for another. In mic mode it is a
    /// hold-to-record control: hold to talk, slide left to cancel, slide up (or tap) to lock.
    @ViewBuilder
    private var trailingButton: some View {
        let mode = trailingMode
        let label = ComposerCircleLabel(
            systemImage: mode == .mic ? "mic.fill" : (mode == .save ? "checkmark" : "arrow.up"),
            isProminent: mode == .send || mode == .save,
            foreground: mode == .disabled ? ClickColors.textTertiary : ClickColors.textSecondary
        )
        if mode == .mic {
            label
                .scaleEffect(isRecording ? 1.25 : 0.96)
                .gesture(holdToRecordGesture)
                .accessibilityLabel("Record voice note")
                .accessibilityHint("Hold to record, or double-tap to record hands-free.")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { beginRecording(locked: true) }
        } else {
            Button {
                guard mode == .send || mode == .save else { return }
                ClickHaptics.impact(.light)
                onSend()
            } label: {
                label
            }
            .buttonStyle(.plain)
            .disabled(mode == .disabled)
            .accessibilityLabel(mode == .save ? "Save edit" : "Send message")
            .contextMenu {
                if mode == .send, staged.isEmpty, let onScheduleSend {
                    Button("Send Later", systemImage: "clock", action: onScheduleSend)
                }
            }
        }
    }

    private var canSend: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || (!staged.isEmpty && editTarget == nil)) && remainingCharacters >= 0
    }

    private var isRecording: Bool {
        if case .recording = recorder.state { return true }
        return false
    }

    // MARK: Hold to record

    @State private var holdStartedAt: Date?
    @State private var holdTranslation: CGSize = .zero
    @State private var holdResolved = false

    private var holdToRecordGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if holdStartedAt == nil {
                    holdStartedAt = .now
                    holdResolved = false
                    beginRecording(locked: false)
                }
                guard !holdResolved else { return }
                holdTranslation = value.translation
                if value.translation.width < -90 {
                    holdResolved = true
                    ClickHaptics.impact(.medium)
                    recorder.cancel()
                } else if value.translation.height < -70 {
                    holdResolved = true
                    ClickHaptics.impact(.light)
                    recorder.isLocked = true
                }
            }
            .onEnded { _ in
                defer {
                    holdStartedAt = nil
                    holdTranslation = .zero
                    holdResolved = false
                }
                guard !holdResolved else { return }
                // A quick tap starts hands-free recording instead of a too-short clip.
                if let started = holdStartedAt, Date.now.timeIntervalSince(started) < 0.35 {
                    recorder.isLocked = true
                } else {
                    finishRecording()
                }
            }
    }

    private func beginRecording(locked: Bool) {
        Task {
            await startRecording()
            if locked { recorder.isLocked = true }
        }
    }

    /// Stops and stages the clip for review (play or discard) before it is sent.
    private func finishRecording() {
        guard isRecording else { return }
        Task {
            if let draft = await recorder.finish() {
                onDraft?(draft)
            } else {
                onAttachmentError("That voice note was too short.")
            }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            contextArea

            if !staged.isEmpty, editTarget == nil {
                StagedAttachmentTray(items: staged, onRemove: onUnstage)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if case .recording(let startedAt) = recorder.state, recorder.isLocked {
                VoiceRecordingBar(
                    startedAt: startedAt,
                    levels: recorder.levels,
                    onCancel: { recorder.cancel() },
                    onSend: { finishRecording() }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                inputRow
            }
        }
        .onDisappear { recorder.cancel() }
        .animation(ClickMotion.press, value: trailingMode)
        .animation(ClickMotion.content, value: staged.map(\.id))
        .animation(ClickMotion.selection, value: recorder.isLocked)
    }

    /// What the strip above the field shows: the message being edited, else the one being
    /// replied to.
    private struct ComposerContext: Equatable {
        let item: ChatMessageItem
        let isEdit: Bool
    }

    private var activeContext: ComposerContext? {
        editTarget.map { ComposerContext(item: $0, isEdit: true) } ?? replyTarget.map { ComposerContext(item: $0, isEdit: false) }
    }

    /// The last context shown, kept while the strip collapses so it doesn't blank mid-animation.
    @State private var lastContext: ComposerContext?

    /// The reply/edit strip is always in the hierarchy and collapses to zero height when
    /// unused. An inserted/removed strip relied on a removal transition, which could be left
    /// stuck on screen after a send (the composer's safe-area inset resizing at the same
    /// moment as the keyboard and the timeline); a collapse can't be.
    private var contextArea: some View {
        let isOpen = activeContext != nil
        return Group {
            if let shown = activeContext ?? lastContext {
                if shown.isEdit {
                    contextStrip(title: "Editing message", content: shown.item.content, icon: "pencil", onCancel: onCancelEdit)
                } else {
                    contextStrip(
                        title: "Replying to \(shown.item.senderName)",
                        content: ConversationModel.quoteText(shown.item),
                        icon: "arrowshape.turn.up.left.fill",
                        onCancel: onCancelReply,
                        thumbnail: ReplyThumbnail.applies(to: shown.item)
                            ? AnyView(ReplyThumbnail(target: shown.item, load: replyMediaLoader)) : nil
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: isOpen ? nil : 0, alignment: .bottom)
        .clipped()
        .opacity(isOpen ? 1 : 0)
        .allowsHitTesting(isOpen)
        .accessibilityHidden(!isOpen)
        .animation(ClickMotion.selection, value: activeContext)
        .onChange(of: activeContext, initial: true) { _, context in
            if let context { lastContext = context }
        }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isRecording {
                // Holding: the field becomes the live recording strip; the mic stays in place
                // so the gesture keeps tracking the finger.
                VoiceHoldStrip(
                    startedAt: { if case .recording(let at) = recorder.state { return at } else { return .now } }(),
                    levels: recorder.levels,
                    slideProgress: min(1, max(0, -holdTranslation.width / 90)),
                    lockProgress: min(1, max(0, -holdTranslation.height / 70))
                )
            } else {
                if let onDraft, editTarget == nil {
                    ComposerAttachmentButton(
                        onDraft: onDraft,
                        onError: onAttachmentError,
                        onVoice: photosOnly ? nil : { beginRecording(locked: true) },
                        onShareBeacon: onShareBeacon,
                        allowsFiles: !photosOnly
                    )
                }
                textField
                if remainingCharacters < 80 {
                    Text("\(remainingCharacters)")
                        .font(ClickTypography.caption)
                        .foregroundStyle(
                            remainingCharacters < 20
                                ? ClickColors.destructive
                                : ClickColors.textSecondary
                        )
                        .padding(.bottom, 12)
                        .monospacedDigit()
                }
            }
            trailingButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var textField: some View {
        TextField(
            editTarget == nil ? (staged.isEmpty ? placeholder : "Add a caption…") : "Edit message…",
            text: $text,
            axis: .vertical
        )
        .focused($isFocused)
        .lineLimit(1...5)
        .font(ClickTypography.body)
        .foregroundStyle(ClickColors.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: ClickRadius.messageBubble, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ClickRadius.messageBubble, style: .continuous)
                .stroke(
                    isFocused ? ClickColors.accentForeground.opacity(0.55) : ClickColors.separator,
                    lineWidth: isFocused
                        ? ClickMetrics.focusStrokeWidth
                        : ClickMetrics.strokeWidth
                )
        }
        .submitLabel(.send)
        .onSubmit {
            guard canSend else { return }
            ClickHaptics.impact(.light)
            onSend()
        }
        .onChange(of: text) { _, newValue in
            if newValue.count > characterLimit {
                text = String(newValue.prefix(characterLimit))
            }
            onTypingChanged(!newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func contextStrip(
        title: String,
        content: String,
        icon: String,
        onCancel: @escaping () -> Void,
        thumbnail: AnyView? = nil
    ) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(ClickColors.accentForeground)
                .frame(width: 3, height: 36)

            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ClickColors.accentForeground)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(ClickTypography.metadata)
                    .foregroundStyle(ClickColors.accentForeground)
                    .lineLimit(1)

                Text(content)
                    .font(ClickTypography.supporting)
                    .foregroundStyle(ClickColors.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let thumbnail { thumbnail }

            Button {
                ClickHaptics.selection()
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ClickColors.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(ClickColors.fillSubtle)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func startRecording() async {
        await recorder.start()
        if recorder.state == .denied {
            onAttachmentError("Allow microphone access in Settings to record voice notes.")
        }
    }
}
