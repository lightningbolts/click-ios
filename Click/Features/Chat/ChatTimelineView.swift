import SwiftUI
import UIKit

/// One row of the conversation timeline.
enum ChatTimelineRow: Hashable, Sendable {
    case dateHeader(Date)
    case unreadDivider
    case message(String)      // stableID
    case typing
}

/// Imperative handle ChatView uses to move the timeline (jump to latest, jump to a message).
///
/// Also publishes whether the reader is near the bottom. This lives here, not in `@State`,
/// because UIKit scroll callbacks can fire while SwiftUI is updating the view, and writing
/// `@State` then is undefined behavior.
@MainActor
@Observable
final class TimelineController {
    @ObservationIgnored fileprivate weak var coordinator: ChatTimelineView.Coordinator?

    /// True while the newest message is (nearly) in view.
    fileprivate(set) var isNearBottom = true

    func scrollToBottom(animated: Bool) {
        coordinator?.scrollToBottom(animated: animated)
    }

    /// Scrolls a message to the middle of the screen; false when it isn't in the timeline.
    @discardableResult
    func scrollTo(stableID: String, animated: Bool) -> Bool {
        coordinator?.scrollTo(row: .message(stableID), animated: animated) ?? false
    }

    /// Re-renders visible rows (highlight, lifted bubble) without touching the data.
    func refreshVisibleRows() {
        coordinator?.reconfigureVisible()
    }

}

/// The message timeline, on `UICollectionView` (like WhatsApp and Messages) rather than a
/// SwiftUI lazy stack, because only UIKit gives exact control of scroll position:
///
/// - **Opening** lands exactly on the newest message: rows are laid out and the offset set to
///   the true bottom before the first frame is shown.
/// - **Older history** is prefetched while the reader is still 2.5 screens away from the top,
///   and prepending keeps the visible rows exactly where they are (content-size delta applied to
///   the offset), so there is no jump and no spinner row.
/// - **Staying at the bottom**: while the reader is at the bottom, new messages, growing
///   bubbles (images decoding), composer/keyboard changes all keep the newest message visible.
///
/// Rows render the existing SwiftUI views through `UIHostingConfiguration`.
struct ChatTimelineView: UIViewRepresentable {
    let rows: [ChatTimelineRow]
    /// Changes whenever any row's content changes (so visible rows re-render).
    let contentVersion: Int
    let hasMoreHistory: Bool
    let isLoadingOlder: Bool
    let controller: TimelineController
    let rowContent: (ChatTimelineRow) -> AnyView
    let onNearTop: () -> Void
    let onUserScroll: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TimelineCollectionView {
        let layout = UICollectionViewCompositionalLayout { _, _ in
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(64))
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
            return section
        }
        let view = TimelineCollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.contentInsetAdjustmentBehavior = .always
        view.showsHorizontalScrollIndicator = false
        view.delaysContentTouches = false
        view.allowsSelection = false
        view.alpha = 0   // shown once positioned at the bottom (no visible jump on open)
        context.coordinator.attach(view, controller: controller)
        return view
    }

    func updateUIView(_ view: TimelineCollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.apply(rows: rows, contentVersion: contentVersion)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate {
        var parent: ChatTimelineView?
        private weak var collectionView: TimelineCollectionView?
        private weak var controller: TimelineController?
        private var dataSource: UICollectionViewDiffableDataSource<Int, ChatTimelineRow>?
        private var currentRows: [ChatTimelineRow] = []
        private var contentVersion = -1
        private var hasPositionedInitially = false
        private var lastNearBottom = true
        private var pendingNearBottom: Bool?
        private var nearBottomReportScheduled = false
        private var lastNearTopRequest = Date.distantPast

        func attach(_ view: TimelineCollectionView, controller: TimelineController) {
            collectionView = view
            self.controller = controller
            controller.coordinator = self
            view.delegate = self
            view.onLayout = { [weak self] in self?.afterLayout() }

            let registration = UICollectionView.CellRegistration<UICollectionViewCell, ChatTimelineRow> { [weak self] cell, _, row in
                guard let content = self?.parent?.rowContent(row) else { return }
                cell.contentConfiguration = UIHostingConfiguration { content }
                    .margins(.all, 0)
                    .minSize(width: nil, height: 0)
                cell.backgroundConfiguration = .clear()
            }
            dataSource = UICollectionViewDiffableDataSource(collectionView: view) { collectionView, indexPath, row in
                collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: row)
            }
        }

        // MARK: Data

        func apply(rows: [ChatTimelineRow], contentVersion version: Int) {
            guard let collectionView, let dataSource else { return }
            let rowsChanged = rows != currentRows
            let contentChanged = version != contentVersion
            contentVersion = version
            guard rowsChanged || contentChanged else {
                // State outside the rows (highlight, lifted bubble) may have changed.
                reconfigureVisible()
                return
            }

            let previousRows = currentRows
            currentRows = rows
            var snapshot = NSDiffableDataSourceSnapshot<Int, ChatTimelineRow>()
            snapshot.appendSections([0])
            snapshot.appendItems(rows)
            if !rowsChanged || !previousRows.isEmpty {
                // Rows that exist on both sides may have new content (receipts, reactions, edits).
                let kept = Set(previousRows).intersection(rows)
                let visible = Set(collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) })
                snapshot.reconfigureItems(Array(kept.intersection(visible)))
            }

            let prepended = Self.isPrepend(old: previousRows, new: rows)
            let wasAtBottom = collectionView.stickToBottom
            if prepended, hasPositionedInitially {
                // Keep the reader's rows exactly in place while older history lands above.
                let distanceFromBottom = collectionView.contentSize.height - collectionView.contentOffset.y
                collectionView.isPreservingPosition = true
                dataSource.apply(snapshot, animatingDifferences: false)
                collectionView.layoutIfNeeded()
                collectionView.contentOffset.y = collectionView.contentSize.height - distanceFromBottom
                collectionView.isPreservingPosition = false
            } else if hasPositionedInitially, wasAtBottom, let tail = Self.tailChange(old: previousRows, new: rows) {
                applyAnimated(snapshot, added: tail.added, removed: tail.removed, pinToBottom: true)
            } else if hasPositionedInitially, !rowsChanged {
                // Same rows, new content (a reaction, an edit, a receipt): rows that resize or
                // move glide to their new places instead of jumping, wherever they are.
                applyAnimated(snapshot, added: [], removed: [], pinToBottom: wasAtBottom)
            } else {
                dataSource.apply(snapshot, animatingDifferences: false)
                if !hasPositionedInitially {
                    positionInitially()
                } else if wasAtBottom {
                    collectionView.layoutIfNeeded()
                    scrollToBottom(animated: false)
                }
            }
            requestOlderIfNeeded()
        }

        /// Rows added or removed at the end only (a message sent or received, typing shown or
        /// hidden), or nil for any other change.
        nonisolated static func tailChange(old: [ChatTimelineRow], new: [ChatTimelineRow]) -> (added: [ChatTimelineRow], removed: [ChatTimelineRow])? {
            guard !old.isEmpty, old != new else { return nil }
            let shared = zip(old, new).prefix { $0 == $1 }.count
            let added = Array(new.dropFirst(shared))
            let removed = Array(old.dropFirst(shared))
            // Only the few newest rows may change; a larger change is a reload, not a message.
            guard added.count <= 4, removed.count <= 1, removed.allSatisfy({ $0 == .typing }) else { return nil }
            return (added, removed)
        }

        /// Applies a snapshot and animates the visible rows from where they were on screen to
        /// where they land (FLIP), so nothing jumps:
        /// - a message arriving while at the bottom rises from the composer as the rows above
        ///   glide up by its height, and a departing typing bubble fades;
        /// - a row resizing in place (a reaction added or removed, an edit) pushes its
        ///   neighbours smoothly, above or below, pinned to the bottom or not.
        private func applyAnimated(_ snapshot: NSDiffableDataSourceSnapshot<Int, ChatTimelineRow>,
                                   added: [ChatTimelineRow], removed: [ChatTimelineRow], pinToBottom: Bool) {
            guard let collectionView, let dataSource else { return }
            // Where each visible row sits on screen now.
            var before: [ChatTimelineRow: CGFloat] = [:]
            for indexPath in collectionView.indexPathsForVisibleItems {
                guard let row = dataSource.itemIdentifier(for: indexPath),
                      let cell = collectionView.cellForItem(at: indexPath) else { continue }
                before[row] = cell.frame.minY - collectionView.contentOffset.y
            }
            let departing = removed.compactMap { row -> UIView? in
                guard let indexPath = dataSource.indexPath(for: row), let cell = collectionView.cellForItem(at: indexPath),
                      let copy = cell.snapshotView(afterScreenUpdates: false) else { return nil }
                copy.frame = cell.frame
                return copy
            }
            let oldOffset = collectionView.contentOffset.y

            dataSource.apply(snapshot, animatingDifferences: false)
            // Let reconfigured SwiftUI rows measure their new content now (not on a later
            // pass, which would move them after the animation was set up).
            collectionView.visibleCells.forEach { $0.layoutIfNeeded() }
            collectionView.layoutIfNeeded()
            if pinToBottom {
                scrollToBottom(animated: false)
                collectionView.layoutIfNeeded()
            }

            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            let shift = collectionView.contentOffset.y - oldOffset
            let arriving = Set(added)
            var moved = false
            for indexPath in collectionView.indexPathsForVisibleItems {
                guard let cell = collectionView.cellForItem(at: indexPath),
                      let row = dataSource.itemIdentifier(for: indexPath) else { continue }
                let content = cell.contentView
                if arriving.contains(row) {
                    // From just below its resting place (behind the composer).
                    let rise = max(shift, cell.bounds.height * 0.6)
                    content.transform = reduceMotion ? .identity : CGAffineTransform(translationX: 0, y: rise).scaledBy(x: 0.96, y: 0.96)
                    content.alpha = 0
                    moved = true
                } else if !reduceMotion, let oldY = before[row] {
                    let delta = oldY - (cell.frame.minY - collectionView.contentOffset.y)
                    if abs(delta) > 0.5 {
                        content.transform = CGAffineTransform(translationX: 0, y: delta)
                        moved = true
                    }
                }
            }
            for copy in departing {
                // Content coordinates: offset by the scroll change so it stays where it was on screen.
                copy.frame.origin.y += shift
                collectionView.addSubview(copy)
            }
            guard moved || !departing.isEmpty else { return }

            UIView.animate(withDuration: reduceMotion ? 0.2 : 0.42, delay: 0, usingSpringWithDamping: 0.86,
                           initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                for cell in collectionView.visibleCells {
                    cell.contentView.transform = .identity
                    cell.contentView.alpha = 1
                }
                for copy in departing {
                    copy.alpha = 0
                    copy.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
                }
            } completion: { _ in
                departing.forEach { $0.removeFromSuperview() }
            }
        }

        /// True when `new` is `old` with rows added only at the top.
        nonisolated static func isPrepend(old: [ChatTimelineRow], new: [ChatTimelineRow]) -> Bool {
            guard !old.isEmpty, new.count > old.count else { return false }
            // Ignore the typing row, which only ever sits at the end.
            let oldCore = old.filter { $0 != .typing }
            let newCore = new.filter { $0 != .typing }
            guard newCore.count > oldCore.count else { return false }
            return Array(newCore.suffix(oldCore.count)) == oldCore
                // A date header for the old first day can move below the new rows; allow it.
                || Array(newCore.suffix(oldCore.count - 1)) == Array(oldCore.dropFirst())
        }


        func reconfigureVisible() {
            guard let collectionView, let dataSource else { return }
            let visible = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
            guard !visible.isEmpty else { return }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(visible)
            dataSource.apply(snapshot, animatingDifferences: false)
        }

        // MARK: Position

        private func positionInitially() {
            guard let collectionView, !currentRows.isEmpty else { return }
            // Estimated heights settle as rows near the bottom are measured: repeat until stable.
            for _ in 0..<4 {
                collectionView.layoutIfNeeded()
                scrollToBottom(animated: false)
            }
            collectionView.stickToBottom = true
            hasPositionedInitially = true
            UIView.animate(withDuration: 0.12) { collectionView.alpha = 1 }
        }

        private func bottomOffset(_ view: UICollectionView) -> CGFloat {
            let inset = view.adjustedContentInset
            return max(-inset.top, view.contentSize.height - view.bounds.height + inset.bottom)
        }

        func scrollToBottom(animated: Bool) {
            guard let collectionView else { return }
            collectionView.stickToBottom = true
            collectionView.setContentOffset(CGPoint(x: 0, y: bottomOffset(collectionView)), animated: animated)
            reportNearBottom(true)
        }

        func scrollTo(row: ChatTimelineRow, animated: Bool) -> Bool {
            guard let collectionView, let dataSource, let indexPath = dataSource.indexPath(for: row) else { return false }
            collectionView.stickToBottom = false
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: animated)
            return true
        }

        /// Called after every layout pass: keeps the newest message in view while pinned
        /// (bubbles resizing, composer growing, keyboard) and before the first reveal.
        private func afterLayout() {
            guard let collectionView, hasPositionedInitially, !collectionView.isPreservingPosition else { return }
            if collectionView.stickToBottom, !collectionView.isTracking, !collectionView.isDecelerating {
                let target = bottomOffset(collectionView)
                if abs(collectionView.contentOffset.y - target) > 0.5 {
                    collectionView.contentOffset.y = target
                }
            }
        }

        private func reportNearBottom(_ near: Bool) {
            guard near != lastNearBottom else { return }
            lastNearBottom = near
            pendingNearBottom = near
            guard !nearBottomReportScheduled else { return }
            nearBottomReportScheduled = true

            // UIKit can invoke scroll delegates while SwiftUI is synchronously updating this
            // representable. Task.yield() is not a sufficient boundary because the task may
            // resume in the same update cycle. Queue the callback to the next main run-loop turn
            // and coalesce any intermediate values.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.nearBottomReportScheduled = false
                guard let pending = self.pendingNearBottom else { return }
                self.pendingNearBottom = nil
                guard let controller = self.controller, controller.isNearBottom != pending else { return }
                withAnimation(ClickMotion.selection) { controller.isNearBottom = pending }
            }
        }

        private func requestOlderIfNeeded() {
            guard let collectionView, let parent, hasPositionedInitially,
                  parent.hasMoreHistory, !parent.isLoadingOlder else { return }
            let distanceFromTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
            guard distanceFromTop < collectionView.bounds.height * 2.5 else { return }
            // One request per moment; the model also guards against overlap.
            guard Date().timeIntervalSince(lastNearTopRequest) > 0.25 else { return }
            lastNearTopRequest = Date()
            parent.onNearTop()
        }

        // MARK: UIScrollViewDelegate

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let collectionView, hasPositionedInitially else { return }
            let distanceFromBottom = bottomOffset(collectionView) - scrollView.contentOffset.y
            if scrollView.isTracking || scrollView.isDecelerating {
                collectionView.stickToBottom = distanceFromBottom < 24
            }
            reportNearBottom(distanceFromBottom < 120)
            requestOlderIfNeeded()
        }

        func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            // Scroll callbacks can be sparse while self-sizing SwiftUI cells settle. Treat
            // displaying one of the leading rows as an independent pagination sentinel.
            guard indexPath.item <= 3 else { return }
            requestOlderIfNeeded()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            parent?.onUserScroll()
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            guard let collectionView else { return }
            collectionView.stickToBottom = bottomOffset(collectionView) - scrollView.contentOffset.y < 24
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            guard let collectionView else { return }
            collectionView.stickToBottom = bottomOffset(collectionView) - scrollView.contentOffset.y < 24
        }
    }
}

/// Collection view that reports each layout pass (to keep the bottom pinned).
final class TimelineCollectionView: UICollectionView {
    /// True while the reader is at the newest message; layout changes keep it there.
    var stickToBottom = true
    /// Set while a prepend restores the offset (layout must not re-pin in between).
    var isPreservingPosition = false
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
