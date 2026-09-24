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
    /// Nil hides attachments and voice notes (hub chats).
    let onDraft: ((MediaDraft) -> Void)?
    let onAttachmentError: (String) -> Void

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
        onAttachmentError: @escaping (String) -> Void = { _ in }
    ) {
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

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && remainingCharacters >= 0
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let editTarget {
                contextStrip(
                    title: "Editing message",
                    content: editTarget.content,
                    icon: "pencil",
                    onCancel: onCancelEdit
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let replyTarget {
                contextStrip(
                    title: "Replying to \(replyTarget.senderName)",
                    content: replyTarget.content,
                    icon: "arrowshape.turn.up.left.fill",
                    onCancel: onCancelReply
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if case .recording(let startedAt) = recorder.state {
                VoiceRecordingBar(
                    startedAt: startedAt,
                    onCancel: { recorder.cancel() },
                    onSend: {
                        if let draft = recorder.finish() { onDraft?(draft) }
                        else { onAttachmentError("That voice note was too short.") }
                    }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
            HStack(alignment: .bottom, spacing: 8) {
                if let onDraft, editTarget == nil {
                    ComposerAttachmentButton(onDraft: onDraft, onError: onAttachmentError)
                }
                TextField(
                    editTarget == nil ? placeholder : "Edit message…",
                    text: $text,
                    axis: .vertical
                )
                .focused($isFocused)
                .lineLimit(1...5)
                .font(ClickTypography.body)
                .foregroundStyle(ClickColors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(ClickColors.surfaceElevated)
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

                if onDraft != nil, editTarget == nil, !canSend {
                    Button {
                        Task {
                            await recorder.start()
                            if recorder.state == .denied {
                                onAttachmentError("Allow microphone access in Settings to record voice notes.")
                            }
                        }
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(ClickColors.textSecondary)
                            .frame(width: 40, height: 40)
                            .background(ClickColors.fillStrong)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Record voice note")
                } else {
                Button {
                    guard canSend else { return }
                    ClickHaptics.impact(.light)
                    onSend()
                } label: {
                    Image(systemName: editTarget == nil ? "arrow.up" : "checkmark")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(
                            canSend ? ClickColors.primaryActionForeground : ClickColors.textTertiary
                        )
                        .frame(width: 40, height: 40)
                        .background(
                            canSend ? ClickColors.primaryActionFill : ClickColors.fillStrong
                        )
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel(editTarget == nil ? "Send message" : "Save edit")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            }
        }
        .onDisappear { recorder.cancel() }
        .background(ClickColors.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ClickColors.separator)
                .frame(height: 0.5)
        }
        .animation(ClickMotion.selection, value: replyTarget?.id)
        .animation(ClickMotion.selection, value: editTarget?.id)
    }

    private func contextStrip(
        title: String,
        content: String,
        icon: String,
        onCancel: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(ClickColors.accentForeground)
                .frame(width: 3)

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
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(ClickColors.surface)
    }
}
