import SwiftUI

/// Chat message composer with reply preview, edit mode, 1000-character count, and haptic send.
public struct ChatComposerView: View {
    @Binding var text: String
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
        replyTarget: ChatMessageItem? = nil,
        editTarget: ChatMessageItem? = nil,
        isSending: Bool = false,
        onCancelReply: @escaping () -> Void,
        onCancelEdit: @escaping () -> Void,
        onSend: @escaping () -> Void,
        onTypingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self._text = text
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && remainingCharacters >= 0 && !isSending
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(ClickColors.outline.opacity(0.2))

            // Reply or Edit Banner
            if let edit = editTarget {
                contextBanner(
                    title: "Editing message",
                    content: edit.content,
                    icon: "pencil",
                    tint: ClickColors.primary,
                    onCancel: onCancelEdit
                )
            } else if let reply = replyTarget {
                contextBanner(
                    title: "Replying to \(reply.senderName)",
                    content: reply.content,
                    icon: "arrowshape.turn.up.left.fill",
                    tint: ClickColors.primary,
                    onCancel: onCancelReply
                )
            }

            // Input Bar
            HStack(alignment: .bottom, spacing: ClickSpacing.sm) {
                // Multiline text input
                TextField("Message…", text: $text, axis: .vertical)
                    .focused($isFocused)
                    .lineLimit(1...5)
                    .font(ClickTypography.bodyMedium)
                    .padding(.horizontal, ClickSpacing.sm)
                    .padding(.vertical, 8)
                    .background(ClickColors.surfaceContainerLow)
                    .clipShape(RoundedRectangle(cornerRadius: ClickSpacing.radiusInput))
                    .onChange(of: text) { oldValue, newValue in
                        if newValue.count > characterLimit {
                            text = String(newValue.prefix(characterLimit))
                        }
                        onTypingChanged(!newValue.isEmpty)
                    }

                // Character counter warning if low
                if remainingCharacters < 100 {
                    Text("\(remainingCharacters)")
                        .font(ClickTypography.labelSmall)
                        .foregroundStyle(remainingCharacters < 0 ? ClickColors.error : ClickColors.textSecondary)
                        .padding(.bottom, 8)
                }

                // Send Button
                Button {
                    ClickHaptics.selection()
                    onSend()
                } label: {
                    ZStack {
                        Circle()
                            .fill(canSend ? ClickColors.primary : ClickColors.outline.opacity(0.3))
                            .frame(width: 36, height: 36)

                        if isSending {
                            ProgressView()
                                .tint(ClickColors.onPrimary)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: editTarget != nil ? "checkmark" : "arrow.up")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(canSend ? ClickColors.onPrimary : ClickColors.textSecondary)
                        }
                    }
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, ClickSpacing.md)
            .padding(.vertical, ClickSpacing.sm)
            .background(ClickColors.background)
        }
    }

    private func contextBanner(
        title: String,
        content: String,
        icon: String,
        tint: Color,
        onCancel: @escaping () -> Void
    ) -> some View {
        HStack(spacing: ClickSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ClickTypography.labelSmall)
                    .fontWeight(.semibold)
                    .foregroundStyle(tint)

                Text(content)
                    .font(ClickTypography.bodySmall)
                    .lineLimit(1)
                    .foregroundStyle(ClickColors.textSecondary)
            }

            Spacer()

            Button {
                ClickHaptics.selection()
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(ClickColors.outline)
            }
        }
        .padding(.horizontal, ClickSpacing.md)
        .padding(.vertical, ClickSpacing.xs)
        .background(ClickColors.surfaceContainerLow)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
