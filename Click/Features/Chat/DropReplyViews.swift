import SwiftUI

/// The shared drop a chat message answers, story-reply style: "Replied to your drop" over the
/// photo, with a reaction's emoji pinned to its corner. Tapping it opens the drop while it's still
/// in the strip; a deleted or expired drop shows as unavailable.
struct DropReplyHeader: View {
    @Environment(AppEnvironment.self) private var env
    let reply: ChatDropReply
    let isOutgoing: Bool
    /// A reaction's emoji (the message text), pinned to the photo.
    let emoji: String?

    @State private var image: UIImage?
    @State private var viewing: SharedDropsStrip.ViewerStart?
    @State private var tileFrames = DropTileFrames()

    private static let size = CGSize(width: 96, height: 128)

    var body: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 6) {
            Text(label)
                .font(ClickTypography.metadata)
                .foregroundStyle(ClickColors.textSecondary)
                .padding(.horizontal, 4)
            Button {
                if env.sharedDropsStore.drop(reply.dropID) != nil { SharedDropsStrip.ViewerStart.open(reply.dropID, in: $viewing) }
            } label: {
                thumbnail.dropTileSource(reply.dropID, in: tileFrames)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        }
        .task(id: reply.dropID) { await load() }
        .dropViewer($viewing, sources: tileFrames)
    }

    private var label: String {
        switch (reply.isReaction, isOutgoing) {
        case (true, true): "You reacted to their drop"
        case (true, false): "Reacted to your drop"
        case (false, true): "You replied to their drop"
        case (false, false): "Replied to your drop"
        }
    }

    private var unavailable: Bool { DropReplyThumbnails.missing.contains(reply.dropID) }

    private var thumbnail: some View {
        ZStack {
            if let image {
                Color.clear.overlay { Image(uiImage: image).resizable().scaledToFill() }
            } else if unavailable {
                ClickColors.fillSubtle.overlay {
                    VStack(spacing: 4) {
                        Image(systemName: "photo")
                        Text("Drop no longer available").font(ClickTypography.caption).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(ClickColors.textSecondary)
                    .padding(8)
                }
            } else {
                MediaLoadingPlaceholder()
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: isOutgoing ? .bottomLeading : .bottomTrailing) {
            if let emoji {
                Text(emoji)
                    .font(.system(size: 40))
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    .offset(x: isOutgoing ? -12 : 12, y: 12)
            }
        }
        .padding(.bottom, emoji == nil ? 0 : 10)
    }

    /// The strip's copy, then the disk cache, then (once) the server, which checks access.
    private func load() async {
        let id = reply.dropID
        guard image == nil, !unavailable else { return }
        if let tile = env.sharedDropsStore.originals[id] {
            image = tile
            return
        }
        guard let userID = env.session.currentSession?.userId else { return }
        let pixels = Self.size.height * 3
        if let cached = await Task.detached(priority: .userInitiated, operation: {
            DropPhotoCache.load(id, userID: userID, maxPixels: pixels)
        }).value {
            image = cached
            return
        }
        guard let url = try? await env.drops.develop([ClickDropRef(kind: .shared, id: id)]).first?.originalURL,
              let data = try? await ClickDropService.loadOriginalData(url) else {
            DropReplyThumbnails.missing.insert(id)
            return
        }
        let decoded = await Task.detached(priority: .userInitiated) {
            DropPhotoCache.save(data, dropID: id, userID: userID)
            return ClickDropService.thumbnail(data, maxPixels: pixels)
        }.value
        withAnimation(ClickMotion.subtleFade) { image = decoded }
    }
}

/// Drops a reply points at that can't be loaded (deleted, or no longer shared with you), so
/// scrolling a chat doesn't ask the server again for each bubble.
@MainActor
enum DropReplyThumbnails {
    static var missing: Set<String> = []
}
