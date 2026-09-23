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

    @FocusState private var isFocused: Bool
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
        onTypingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
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

            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    editTarget == nil ? placeholder : "Edit message…",
                    text: $text,
                    axis: .vertical
                )
                .focused($isFocused)
                .lineLimit(1...5)
                .font(ClickTypography.bodyMedium)
                .foregroundStyle(ClickColors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(ClickColors.surfaceContainerLow)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(
                            isFocused ? ClickColors.primary.opacity(0.55) : ClickColors.quietBorder,
                            lineWidth: isFocused
                                ? ClickSpacing.borderFocusWidth
                                : ClickSpacing.borderQuietWidth
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
                        .font(ClickTypography.microcopy)
                        .foregroundStyle(
                            remainingCharacters < 20
                                ? ClickColors.error
                                : ClickColors.textSecondary
                        )
                        .padding(.bottom, 12)
                        .monospacedDigit()
                }

                Button {
                    guard canSend else { return }
                    ClickHaptics.impact(.light)
                    onSend()
                } label: {
                    Image(systemName: editTarget == nil ? "arrow.up" : "checkmark")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(
                            canSend ? ClickColors.onPrimary : ClickColors.tertiaryLabel
                        )
                        .frame(width: 40, height: 40)
                        .background(
                            canSend ? ClickColors.primary : ClickColors.surfaceContainerHigh
                        )
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel(editTarget == nil ? "Send message" : "Save edit")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(ClickColors.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ClickColors.quietBorder.opacity(0.65))
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
                .fill(ClickColors.primary)
                .frame(width: 3)

            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ClickColors.primary)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(ClickTypography.captionSmall)
                    .foregroundStyle(ClickColors.primary)
                    .lineLimit(1)

                Text(content)
                    .font(ClickTypography.bodySmall)
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
                    .background(ClickColors.surfaceContainerLow)
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
