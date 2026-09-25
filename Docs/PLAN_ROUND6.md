# Click iOS — Round 6 fix plan

Scope: the five open bugs from device testing (items 3, 4, 5, 7, 10), plus deploying one server change. Items 1, 2, 6, 8, 9 and 11 are resolved. **Don't touch them.**

Follow the steps **in order**. Each step lists:
- the files to change,
- the exact change,
- what *not* to do,
- a **Done when** check you must confirm before moving on.

If a Done-when check fails, stop and fix it. Never mark a step done on the strength of a green build alone.

---

## 0. Ground rules (read first)

**Repos and branches**
- Create and switch to new branch `feat/ios-round6` from `main` in `click-ios`.
- Create and switch to new branch `feat/ios-round6` from `main` in `click-web` (incorporating server auth commit `7c28c9f`).
- Never commit to `main`.

**Build and test commands** (from `click-ios/`):
```
xcodegen generate
# unit tests (the iPhone 17 simulator hangs; use the iPhone 18 Pro simulator)
xcodebuild test -scheme ClickTests -destination 'platform=iOS Simulator,id=72F1B726-931E-4450-9617-919CEE1EFABA' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
  -derivedDataPath /tmp/claude-501/click-dd -collect-test-diagnostics never
# build + install on the owner's iPhone (cable)
xcodebuild build -scheme Click -configuration Debug -destination 'id=00008120-00025DA90E84C01E' \
  -derivedDataPath /tmp/claude-501/click-dd-dev -allowProvisioningUpdates
xcrun devicectl device install app --device 00008120-00025DA90E84C01E /tmp/claude-501/click-dd-dev/Build/Products/Debug-iphoneos/Click.app
# launch with console (prints [net] request timings and [auth] state changes in Debug builds)
xcrun devicectl device process launch --console --terminate-existing --device 00008120-00025DA90E84C01E compose.project.click.click
```
If the simulator is stuck "Shutting Down", run `xcrun simctl shutdown all` and `killall -9 com.apple.CoreSimulator.CoreSimulatorService`, then boot it again.

**Swift 6 rules this codebase already follows**
- Static helpers that tests or pure code call from inside `@MainActor` types must be `nonisolated`.
- Never pass `[String: Any]` into actors.
- iOS 26-only APIs go behind `#if compiler(>=6.2)` plus `#available`.
- The deployment target is iOS 18.2, so `UIGestureRecognizerRepresentable`, `onScrollGeometryChange` and `onScrollPhaseChange` are all available.

**Code rules**
- DRY: one implementation per behavior; delete code you replace.
- Match the surrounding comment density and naming.
- No new third-party dependencies in iOS.
- Tests: add **only** the tests named in each step. The owner asked for minimal testing this round.

**Ledger**
- Append one row per item to `Docs/PARITY_LEDGER.md`, before the `## Phase 4 Direct Chat merge gate` heading, in the same column format as rows F88–F111.
- Device-only checks stay "Pending" unless the owner confirmed them.

---

## Step 1 — Deploy the server auth speedup (click-web)

Branch `feat/ios-round6` in `click-web` (contains commit `7c28c9f`, "verify mobile bearer tokens locally against Supabase JWKS"):
- `lib/server/verifyBearerJwt.ts` verifies ES256 access tokens locally against `https://lrgcwnmcscimkmslihxp.supabase.co/auth/v1/.well-known/jwks.json`.
- `lib/server/supabaseRouteAuth.ts` uses that check first and falls back to `supabase.auth.getUser` only when it can't decide.

Remaining work:
1. Open a PR from `feat/ios-round6` to `main` in click-web and let the owner merge and deploy. **Don't merge it yourself.**
2. After deployment, measure on the phone: launch with `--console` and read the `[net]` lines.

**Done when:** authenticated `/api/...` calls in the console log average **< 600 ms**; before this change they took 1,000–1,900 ms. Record before and after numbers in the ledger row.

---

## Step 2 — Item 4: chat jumps to the top, laggy fast scrolling, and reloading on re-entry

All three symptoms have known root causes. Fix all of them in `Click/Features/Chat/ChatView.swift` and `Click/Features/Chat/ConversationModel.swift`, with one small new type.

### 2a. Jump to the top: root cause
Last round, `ChatView.timeline` switched to an **eager** `VStack` for chats of ≤150 messages (`TimelineStack(lazy: model.items.count > Self.eagerRowLimit)`).

1. In an eager `VStack`, **every** row's `onAppear` fires immediately, including the top "older history" sentinel (the `ProgressView` with `.onAppear { isTopSentinelVisible = true; requestOlderHistory(proxy:) }`).
2. That loads older pages at once.
3. `requestOlderHistory` then calls `proxy.scrollTo(anchor, anchor: .top)`, where `anchor = topVisibleID ?? model.items.first?.stableID`. That is the **first (oldest) message**, so the chat jumps to months ago.

Fix:
1. **Delete** `TimelineStack` (the private struct at the bottom of `ChatView.swift`) and `eagerRowLimit`. Go back to a plain `LazyVStack(spacing: 2)`. Keep the photo aspect-ratio cache (`MediaAspectCache`); it stays useful.
2. **Delete** the sentinel's `onAppear` / `onDisappear` and the `isTopSentinelVisible` state. Keep the `ProgressView` row itself, shown only while `model.isLoadingOlder`.
3. Trigger older history from **scroll geometry**, and only after the user has scrolled:
   ```swift
   @State private var userHasScrolled = false
   // on the ScrollView:
   .onScrollPhaseChange { _, phase in
       if phase == .interacting { userHasScrolled = true }
   }
   .onScrollGeometryChange(for: Bool.self) { geometry in
       geometry.contentOffset.y + geometry.contentInsets.top < 600   // within 600 pt of the top
   } action: { _, nearTop in
       if nearTop, userHasScrolled { requestOlderHistory(proxy: proxy) }
   }
   ```
   Keep the existing near-bottom `onScrollGeometryChange` as a **separate** modifier.
4. In `requestOlderHistory`:
   - Remove the `isTopSentinelVisible` guard.
   - Keep the 300 ms debounce and the `hasMoreHistory` / `!isLoadingOlder` guards.
   - Take the anchor from the visible-rows box (2b). **Never** fall back to `model.items.first`. If no anchor is known, don't call `scrollTo` at all.
5. Delete the `.onAppear` of the "unread divider" scroll if any remains. The divider row stays; the chat must **always** open at the bottom.

### 2b. Laggy fast scrolling: root cause
`.scrollPosition(id: $topVisibleID, anchor: .top)` writes `@State topVisibleID` on every row change while scrolling. That re-runs the whole `ChatView.body`, including every `MessageBubbleView` and the `Canvas` in `ChatBackground`, many times per second.

Fix:
1. **Delete** `.scrollPosition(id: $topVisibleID, anchor: .top)` and `@State topVisibleID`.
2. Add a non-observed reference box, so writes never re-render:
   ```swift
   /// Rows currently on screen, updated while scrolling without invalidating the view.
   private final class VisibleRows { var topID: String? }
   @State private var visibleRows = VisibleRows()
   // on the ScrollView (the LazyVStack keeps .scrollTargetLayout()):
   .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.2) { ids in
       visibleRows.topID = ids.first
   }
   ```
   `requestOlderHistory` reads `visibleRows.topID` as its anchor.
3. Make each row equatable, so SwiftUI skips unchanged rows when `body` does re-run (new message, typing indicator, and so on):
   - Create `private struct MessageRow: View, Equatable` in `ChatView.swift`. It renders the date header (if any), the unread divider (if any), and the `MessageBubbleView`, with the highlight background and `.id(item.stableID)`.
   - **Stored value inputs:**
     - `item: ChatMessageItem`
     - `showsDateHeader: Bool`
     - `isFirstUnread: Bool`
     - `showsSenderName: Bool`
     - `showsReceipts: Bool`
     - `isHighlighted: Bool`
     - `replyTarget: ChatMessageItem?`
     - `canForward: Bool`
   - **Closures** go in one reference type created once per `ChatView`: `final class ChatRowActions`, holding `onReply`, `onEdit`, `onDelete`, and so on, assigned in `.onAppear`.
   - `static func ==` compares **only the value inputs**, never the actions object.
   - Use it as `MessageRow(...).equatable()` inside the `ForEach`.
4. Make the background static:
   - In `DesignSystem/Components/ChatBackground.swift`, conform `ChatBackground` to `Equatable` (compare `seed`).
   - Use `.equatable()` where `ChatView` builds it.
   - Add `.drawingGroup()` to the `Canvas`, so the dot pattern rasterizes once.
5. `ForEach(Array(model.items.enumerated()), …)` stays. The `byID` dictionary stays, but compute it once per `body`, not per row.

### 2c. "Loading conversation" on every re-entry: root cause
`AppEnvironment.conversationModel(for:)` builds a **new** `ConversationModel` for every push.

A new model starts with no decrypted media URLs, no `firstUnreadID`, `hasMoreHistory = true`, and a fresh `loadMessages()`. The timeline cache only keeps 80 messages, and `HubChatView` always shows "Opening hub…" while it re-resolves the hub over the network.

Fix: keep one live model per conversation for the session, the same pattern as `PeerProfileModel.registry` (`Click/Features/Profile/PeerProfileModel.swift`, lines 44–62).
1. In `AppEnvironment` (`Click/App/AppEnvironment.swift`):
   ```swift
   /// One live model per conversation for the session: re-entering a chat shows exactly what was
   /// on screen (timeline, decrypted media, older pages) and refreshes in place.
   private var conversationModels: [String: ConversationModel] = [:]

   public func conversationModel(for identity: ConversationIdentity) -> ConversationModel {
       let key = identity.hubID ?? identity.connectionID ?? identity.chatID
       if let existing = conversationModels[key] { return existing }
       let model = ConversationModel(/* existing arguments, unchanged */)
       conversationModels[key] = model
       return model
   }
   ```
   Also clear `conversationModels` in `clearSessionCaches()`.
2. In `ConversationModel`, make the lifecycle safe for reuse:
   - `onAppear`: if `phase == .loaded` and `items` isn't empty, **don't** set `phase = .loading`. Still re-subscribe realtime and call `loadMessages()`, which merges in place (it already does).
   - `onDisappear`: keep realtime teardown and `saveToCache()`. **Don't** clear `items`, `mediaURLs`, `hasMoreHistory` or `firstUnreadID`.
   - `firstUnreadID`: reset `hasCapturedUnread = false` and `firstUnreadID = nil` in `onDisappear`, so the next visit recomputes it.
   - The `reveal` / `isDetachedFromLatest` state: call `await returnToLatest()` at the start of `onAppear` if `isDetachedFromLatest`.
3. `HubChatView` (`Click/Features/Hubs/HubChatView.swift`):
   - Keep the resolved `HubInfo` in a static `[hubID: HubInfo]` cache.
   - When a cached `HubInfo` exists, set `phase = .ready(cachedHub, env.conversationModel(for: identity))` **immediately**, then re-resolve in the background and update only if something changed.
   - On a background failure with `.ended` or `.accessDenied`, fall back to the current failure UI.
4. `ChatView` initial scroll:
   - The existing `.onChange(of: model.phase)` scroll-to-bottom runs only when the phase *changes* to `.loaded`.
   - For a reused model that is already `.loaded`, rely on `.defaultScrollAnchor(.bottom)` and add **no** extra `scrollTo`.

**Tests (only these):** in `Tests/ClickTests/MessageOperationsTests.swift`, add one test: the same identity returns the same `ConversationModel` instance from `AppEnvironment.conversationModel(for:)`. Use `AppEnvironment(network: NetworkMonitor(start: false))`.

**Done when:** all of these pass on the phone:
1. Open a group with more than 150 messages 10 times: it opens at the latest message every time, with no visible jump.
2. Fling-scroll quickly from bottom to top and back in that chat: no visible stutter. Older pages load only when you get near the top.
3. Go back to the list and reopen the chat: messages and photos appear instantly, with no spinner and no "Loading conversation…".
4. Reopen a hub: no "Opening hub…" screen.

---

## Step 3 — Item 3: WhatsApp-style reactions (a separate bar above the message)

Target, from the owner's WhatsApp screenshot:
- On long-press, the background dims and blurs.
- The message is lifted and shown sharp.
- A **separate floating capsule** of reactions sits directly **above** the message: 👍 ❤️ 😂 😮 😢 🙏, then a round **+** button.
- The **action menu** is a separate rounded panel directly **below** the message: Reply, Forward, Copy, Edit, Save/Share, Delete in red.
- **+** opens a picker with the **entire** emoji set, including search, categories and skin tones.

SwiftUI's `.contextMenu` can't host a separate bar above the preview, so this replaces `.contextMenu` for message bubbles.

### 3a. Remove the old menu
In `Click/Features/Chat/MessageBubbleView.swift`:
- Delete the whole `.contextMenu { … }` block and its `ControlGroup` / `.controlGroupStyle(.palette)`.
- Keep the `.confirmationDialog("Delete for everyone?")`.
- Delete `EmojiPickerSheet` from `Click/Features/Chat/ChatMessageSheets.swift` and its `.sheet(item: $reactingTo)` in `ChatView`.

### 3b. The long-press trigger
In `MessageBubbleView`:
- Add `var onLongPress: ((ChatMessageItem, CGRect) -> Void)?`.
- Track the bubble's global frame: `.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { bubbleFrame = $0 }`, with `@State private var bubbleFrame: CGRect = .zero`.
- Add `.onLongPressGesture(minimumDuration: 0.35) { ClickHaptics.impact(.medium); onLongPress?(message, bubbleFrame) }`. Attach it to `content`, in the same place the context menu was.
- It must not break scrolling or the swipe gesture: `onLongPressGesture` fails as soon as the finger moves, so scrolling still wins.
- Accessibility: add `.accessibilityAction(named: "Message actions") { onLongPress?(message, bubbleFrame) }`.

### 3c. The overlay component
Create `Click/Features/Chat/MessageActionOverlay.swift`:
```swift
/// WhatsApp-style actions for one message: dimmed, blurred backdrop; the message lifted in place;
/// a reaction capsule above it; an action panel below it. Tapping the backdrop dismisses.
struct MessageActionOverlay: View {
    let message: ChatMessageItem
    let sourceFrame: CGRect          // bubble frame in global coordinates
    let bubble: AnyView              // a non-interactive copy of the bubble to show lifted
    let actions: [MessageAction]     // built by ChatView (only the ones that apply)
    let onReact: (String) -> Void
    let onMoreReactions: () -> Void
    let onDismiss: () -> Void
}

struct MessageAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var isDestructive = false
    let perform: () -> Void
}
```
Layout rules. Use a `GeometryReader` filling the screen and `.ignoresSafeArea()`:

1. **Backdrop:** `Rectangle().fill(.ultraThinMaterial)` plus `Color.black.opacity(0.35)`, full screen, `.onTapGesture(perform: onDismiss)`.
2. **Bubble copy:** placed at `sourceFrame` with `.position(x: sourceFrame.midX, y: clampedMidY)`, `.allowsHitTesting(false)`.
   - `clampedMidY` shifts the bubble so that reaction bar (56 pt) + 8 pt gap + bubble + 8 pt gap + menu height fits between the top safe area + 8 and the bottom safe area − 8.
   - If the bubble is taller than the available space, cap its visible height at 40% of the screen with `.frame(maxHeight:)` and `.clipped()`, as WhatsApp does with long messages.
3. **Reaction capsule:** directly above the bubble copy.
   - Width `min(screenWidth − 32, 7 × 48 + 56)`.
   - Aligned to the bubble's leading edge for incoming messages and trailing edge for outgoing, clamped inside the screen with 16 pt margins.
   - Contents: `HStack(spacing: 4)` of the six quick emojis (`["👍", "❤️", "😂", "😮", "😢", "🙏"]`) as `Button`s, each `Text(emoji).font(.system(size: 30))` in a 44×44 frame. Mark the emoji(s) the current user already reacted with using a `ClickColors.selectionTint` circle behind it (`message.reactions.first { $0.reactionType == emoji }?.userReacted`).
   - Last: a 40×40 circular **+** button (`Image(systemName: "plus")` on `ClickColors.fillStrong`).
   - Background: `.glassCircleBackground()`, the existing helper, which renders a capsule.
   - Tapping an emoji calls `onReact(emoji)` then `onDismiss()`. **+** calls `onMoreReactions()`.
4. **Action panel:** directly below the bubble copy.
   - Width 250, aligned like the capsule.
   - `VStack(spacing: 0)` of rows: `HStack { Image(systemName:) 22 pt wide; Text(title) }` in `ClickTypography.body`, 48 pt minimum height, 16 pt horizontal padding.
   - A `Divider` between rows.
   - Destructive rows use `ClickColors.destructive`.
   - Background: `RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial)`.
   - Each row calls `onDismiss()` **then** `perform()`.
5. **Appearance:** the backdrop fades in over 0.2 s; the capsule and panel scale from 0.9 to 1.0 anchored toward the bubble. With `accessibilityReduceMotion`, use opacity only.

The overlay must present **above everything, including the nav bar and tab bar**:
- `ChatView` holds `@State private var actionTarget: (message: ChatMessageItem, frame: CGRect)?` (wrap it in a small `Identifiable` struct).
- Present it with `.fullScreenCover(item:)` using `.presentationBackground(.clear)`, wrapped in `withTransaction(Transaction(animation: nil))` so the system cover slide is disabled. The fade comes from step 5.
- **Alternative if the cover animation can't be suppressed:** attach it to `ChatView`'s outermost view as `.overlay { if let target = actionTarget { MessageActionOverlay(...) } }` with `.toolbar(actionTarget == nil ? .visible : .hidden, for: .navigationBar)`.

**Don't** reimplement bubble layout for the copy. Pass the same `MessageBubbleView(message:…)` with no-op closures, wrapped in `AnyView`.

### 3d. Actions list (built in `ChatView`)
Build the list in this order, including only the entries that apply:
- **Reply:** always.
- **Forward:** if `model.canForward(item)` and `conversations != nil`.
- **Copy:** if not media.
- **Edit:** if outgoing and not media.
- **Save to Photos / Share…:** if media and not locked. Reuse `saveOrShare`.
- **Delete:** if outgoing; destructive. Opens the existing delete confirmation, so move `confirmingDelete` up to `ChatView` state.

This reuses every existing closure; add **no new message operations**.

### 3e. The full emoji picker ("+")
Use the **system emoji keyboard**. It is the complete, current Unicode set with search, categories, skin tones and recents, and it is what the owner means by "the entire emoji list".

Create `Click/Features/Chat/EmojiKeyboardPicker.swift`:
```swift
/// Presents the system emoji keyboard; the first emoji typed becomes the reaction.
struct EmojiKeyboardPicker: UIViewRepresentable {
    let onPick: (String) -> Void

    func makeUIView(context: Context) -> EmojiTextField {
        let field = EmojiTextField()
        field.delegate = context.coordinator
        field.tintColor = .clear
        DispatchQueue.main.async { field.becomeFirstResponder() }
        return field
    }
    func updateUIView(_ uiView: EmojiTextField, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let onPick: (String) -> Void
        init(onPick: @escaping (String) -> Void) { self.onPick = onPick }
        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if let emoji = string.first, emoji.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0x238C }) {
                onPick(String(emoji))
            }
            return false
        }
    }
}

final class EmojiTextField: UITextField {
    // Opens straight to the emoji keyboard.
    override var textInputContextIdentifier: String? { "click.emoji" }
    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
    }
}
```
Present it from `ChatView` as a sheet with `.presentationDetents([.height(60)])` and `.presentationBackground(.clear)`, containing `EmojiKeyboardPicker { emoji in … toggleReaction … dismiss }` in a 1×1 frame. The keyboard rises from the bottom with the sheet.

**Fallback** when `UITextInputMode.activeInputModes` has no `"emoji"` mode, because the user removed the emoji keyboard:
- Show a sheet with a full emoji grid generated at runtime from Unicode:
  - Iterate scalars in `0x1F300...0x1FAFF`, `0x2600...0x27BF` and `0x1F000...0x1F2FF`.
  - Keep those where `scalar.properties.isEmojiPresentation`.
  - Build `String(Character(scalar))`.
  - Include a `.searchable` field that filters by `scalar.properties.name?.lowercased()`.
- Put the generator in a `nonisolated static func allEmoji() -> [(emoji: String, name: String)]`, computed once and cached in a `static let`.

**Tests (only these):** in `Tests/ClickTests/MessageOperationsTests.swift`:
- `EmojiKeyboardPicker`'s fallback list has more than 1,000 entries.
- It contains "👍", "🫶" and "🙏".

**Done when:** all of these pass on the phone:
1. Long-press a message: the backdrop dims, the message stays sharp, the reaction capsule sits **above** it as a separate element, and the action panel sits **below** it, matching the screenshot's arrangement.
2. Tapping 😂 adds the reaction and dismisses.
3. **+** opens the system emoji keyboard; choosing any emoji (for example a flag) reacts with it.
4. Long-press still doesn't block scrolling, and swipe-to-reply still works.

---

## Step 4 — Item 7: tab bar must slide back with the pop, like WhatsApp

Current behavior: `ChatView` uses `.toolbar(.hidden, for: .tabBar)`. SwiftUI hides the bar on push, but on pop it re-shows the bar **only after** the transition, with no animation.

Last round's attempt, `DesignSystem/Components/HidesTabBarWhenPushed.swift`, set `hidesBottomBarWhenPushed` after the push had already begun, so UIKit ignored it. **Delete that file and its `.hidesTabBarWhenPushed()` call** in `ChatView`.

Implement **Option A**. Do Option B only if A's Done-when check fails.

### Option A (keeps the native tab bar): set `hidesBottomBarWhenPushed` *before* UIKit pushes
Create `Click/App/TabBarPushPolicy.swift`:
```swift
import UIKit

/// Screens marked with `.hidesTabBarWhenPushed()` must hide the tab bar the UIKit way, set on
/// the pushed controller *before* the push begins. That's the only way UIKit animates the bar
/// out and back in with the navigation transition, including an interactive back swipe.
enum TabBarPushPolicy {
    static func install() {
        swap(#selector(UINavigationController.pushViewController(_:animated:)),
             #selector(UINavigationController.click_pushViewController(_:animated:)))
        swap(#selector(UINavigationController.setViewControllers(_:animated:)),
             #selector(UINavigationController.click_setViewControllers(_:animated:)))
    }

    private static func swap(_ original: Selector, _ replacement: Selector) {
        guard let a = class_getInstanceMethod(UINavigationController.self, original),
              let b = class_getInstanceMethod(UINavigationController.self, replacement) else { return }
        method_exchangeImplementations(a, b)
    }

    /// True when the controller hosts a view marked `.hidesTabBarWhenPushed()`.
    static func wantsHiddenTabBar(_ controller: UIViewController) -> Bool {
        controller.loadViewIfNeeded()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()   // builds the SwiftUI hierarchy so the marker exists
        return controller.view.containsTabBarHidingMarker
    }
}

extension UINavigationController {
    @objc func click_pushViewController(_ controller: UIViewController, animated: Bool) {
        if TabBarPushPolicy.wantsHiddenTabBar(controller) { controller.hidesBottomBarWhenPushed = true }
        click_pushViewController(controller, animated: animated)   // calls the original (swapped)
    }

    @objc func click_setViewControllers(_ controllers: [UIViewController], animated: Bool) {
        for controller in controllers where !viewControllers.contains(controller) {
            if TabBarPushPolicy.wantsHiddenTabBar(controller) { controller.hidesBottomBarWhenPushed = true }
        }
        click_setViewControllers(controllers, animated: animated)
    }
}
```
The marker is a tiny `UIViewRepresentable`:
- Its `UIView` subclass is `TabBarHidingMarkerView`, 0×0 with `isUserInteractionEnabled = false`.
- The view modifier `.hidesTabBarWhenPushed()` puts it in a `.background`.
- `UIView.containsTabBarHidingMarker` walks the subviews recursively looking for that class.

Wiring:
1. Call `TabBarPushPolicy.install()` **once** at launch (`ClickApp.init`).
2. In `ChatView`, **remove** `.toolbar(.hidden, for: .tabBar)` and add `.hidesTabBarWhenPushed()`.
3. Do the same for `HubChatView` and `EventChatView` if they don't go through `ChatView`. They do, so only `ChatView` needs it.

**Verification to run first:** in a Debug build, temporarily add
`print("[tabbar] push \(type(of: controller)) hide=\(controller.hidesBottomBarWhenPushed)")`
in both swizzled methods. Open a chat and confirm one line prints with `hide=true`. Then remove the print.

**Done when:** on the phone:
1. Opening a chat slides the tab bar away **with** the push.
2. Tapping Back slides the Clicks list and the tab bar back in **together**.
3. A **slow interactive back swipe** shows the tab bar tracking the finger. Cancel the swipe halfway: the tab bar hides again smoothly.

If any of these fail, revert Option A completely and do Option B.

### Option B (fallback, fully deterministic): the tab bar lives on each tab's root screen
1. In `MainTabShellView` (`Click/App/RootGateView.swift`), apply `.toolbar(.hidden, for: .tabBar)` to **every** tab's root view, so the system bar is never shown.
2. Create `Click/App/ClickTabBar.swift`: a `View` with the five items (Home, Add Click, Clicks, Map, Me).
   - Same SF Symbols as today.
   - The Me tab uses `meTabAvatar.image` like today.
   - Clicks shows an unread badge from `conversations.unreadTotal`.
   - Add Click is always purple, with the medium-impact haptic. Keep today's behavior.
   - Selection calls `env.router.selectTab(_:)`.
   - Style: 64 pt tall capsule, `.glassCircleBackground()`, 16 pt horizontal margins, sitting on the bottom safe area.
3. Attach it to each tab's **root** view only, the first view inside each `NavigationStack`, via `.safeAreaInset(edge: .bottom) { ClickTabBar() }`. Pushed screens don't have it, so it slides away and back with the root screen during push and pop, including interactive back, with WhatsApp's parallax.
4. Remove `.toolbar(.hidden, for: .tabBar)` from `ChatView` (no longer needed).

The same Done-when as Option A applies. Also check that the Map tab's Nearby lip (step 5) sits above the custom bar.

---

## Step 5 — Item 5: Nearby becomes a real bottom sheet (rounded, over the tab bar, half and full height)

Owner's requirement: it must behave like the app's other bottom dialogs (New Group, event detail):
- A native sheet, rounded, that rises **over** the tab bar.
- A half-height (medium) and a full-height (large) detent.
- No sharp edge anywhere.

Design:
- The **collapsed lip** stays an in-map floating card above the tab bar.
- Tapping it, or dragging it up, presents a **native `.sheet`** with the list.
- Dismissing the sheet returns to the lip.

The custom drag and offset code is deleted.

1. `Click/Features/Map/NearbySheet.swift`:
   1. Split the file into two views:
      - `NearbyLip`: the current `header` only. It shows "Nearby", the summary and the preview visuals, in a floating card with all four corners rounded:
        - 30 pt radius
        - `.padding(.horizontal, 8)` and `.padding(.bottom, 8)`
        - `.regularMaterial` background and the same shadow as today
      - `NearbyListView`: the current `content` (search field, chips, list). It gets **no** height or offset logic.
   2. `NearbyLip`: `.onTapGesture { model.isNearbyPresented = true }`, plus a `DragGesture(minimumDistance: 10, coordinateSpace: .global)` whose `.onEnded` presents the sheet when `translation.height < -30`.
   3. Delete all of the following:
      - `liveHeight`, `dragStartHeight`, `height(for:available:)`, `contentOpacity`, `settledDetent`
      - the `offset` / `frame(height:)` code
      - `availableHeight`
      - the clipped `Color.clear` host in `ClickMapView`
   4. `NearbyListView` keeps `@FocusState` for search. It must **not** force a detent change on focus; the sheet expands with the keyboard natively.
2. `MapFeatureModel` (`Click/Features/Map/MapFeatureModel.swift`):
   - Replace `sheetDetent` / `settledDetent` with:
     ```swift
     var isNearbyPresented = false
     var nearbyDetent: PresentationDetent = .medium
     ```
   - Update every use:
     - line 290 (`sheetDetent = .medium`) → `isNearbyPresented = true; nearbyDetent = .medium`
     - line 304 (`sheetDetent = .lip`) → `isNearbyPresented = false`
     - `ClickMapView` line 68 menu "Open Nearby list" → `isNearbyPresented = true`
     - the floating controls' `.opacity(model.settledDetent == .expanded ? 0 : 1)` → delete; the sheet covers them
     - the controls' `.padding(.bottom, NearbySheet.height(...) + 12)` → `.padding(.bottom, 84 + 12)`, the lip height plus spacing
3. `ClickMapView`:
   - Put `NearbyLip` at the bottom of the `ZStack`.
   - Present the list:
     ```swift
     .sheet(isPresented: $model.isNearbyPresented) {
         NearbyListView(model: model, pins: pins) { item in
             model.isNearbyPresented = false
             Task { try? await Task.sleep(for: .milliseconds(350)); open(item) }   // after the sheet leaves
         }
         .presentationDetents([.medium, .large], selection: $model.nearbyDetent)
         .presentationDragIndicator(.visible)
         .presentationBackgroundInteraction(.enabled(upThrough: .medium))   // map stays usable at half height
         .presentationBackground(.regularMaterial)
         .presentationCornerRadius(38)
     }
     ```
   - Dismiss the sheet when leaving the map: `.onDisappear { model.isNearbyPresented = false }` on the Map root, and when `env.router.selectedTab` changes away from `.map`.
4. `Tests/ClickTests/NearbyMapTests.swift`:
   - Delete the `contentOpacity` and `settledDetent` tests; those functions no longer exist.
   - Add no replacement tests.

**Done when:** on the phone:
1. The Map tab shows the rounded lip above the tab bar.
2. Tap it: a native sheet rises **over** the tab bar at half height, rounded, with a grabber.
3. Drag it up: full height. Drag it down: half, then dismissed back to the lip.
4. At half height the map can still be panned.
5. There's no flicker or sharp edge at any point; the motion is identical to the New Group sheet.

---

## Step 6 — Item 10: timeline encounters as colorful pills (KMP style)

Reference: KMP `ui/components/ProfileTimelineMetrics.kt`, lines 300–426 (`OurTimelineSection`), and `TimelineMetricPill` at line 219.

Each encounter row in KMP shows:
1. Small muted "when" line: `Tue, Sep 22, 2026 · 7:30 PM`.
2. Bold place line: `Place • Neighbourhood, City`, or "Unknown place".
3. (Event only) the event title in the accent color, the schedule line, and "View on map".
4. **Context tag pills:** sparkle icon tinted accent, label from `ContextTagTaxonomy`.
5. **Metric pills, each its own colorful pill with a symbol, in this order:**

   | KMP label function | SF Symbol | Icon tint | Label format |
   |---|---|---|---|
   | condition | `cloud` | `#B0BEC5` | e.g. "Clear" |
   | temperature | `thermometer.medium` | `#FFCC80` | `68°F (20°C)` |
   | wind | `wind` | `#81D4FA` | `12 km/h NE` |
   | noise | `waveform` | `#69F0AE` | "Quiet" (category only, no dB) |
   | elevation | `mountain.2` | `#90CAF9` | `Elevated · 12 m` |
   | compass | `safari` | `#B39DDB` | `45°` |

   Pill style:
   - Capsule; horizontal padding 8, vertical padding 4.
   - Background `ClickColors.fillSubtle`; stroke `ClickColors.separator`, 1 pt.
   - 14 pt icon in its tint, 4 pt spacing.
   - Text in `ClickTypography.caption.weight(.medium)`, `ClickColors.textPrimary`, `lineLimit(1)`.
   - Pills wrap using the existing `FlowLayout` (`DesignSystem/Components/FlowLayout.swift`) with 6 pt spacing.

   No lux, motion or battery (the owner asked for that last round).

Changes:
1. `Click/Core/Profile/ProfileRepository.swift`, in `enum EncounterLabels`:
   - Add `nonisolated static func metricPills(for encounter: Encounter) -> [MetricPill]`, returning the rows above in that order and skipping missing values.
   - `struct MetricPill: Hashable { let symbol: String; let tintHex: String; let text: String }`.
   - Reuse the existing `compass(_:)`, `noise(_:)` and `elevation(_:)` helpers. **Delete** `weatherLine`, `noiseLine` and `barometricLine` once nothing uses them.
   - Change `lines(for:)` to return only the "when" and "place" lines, which become the two text lines. Update `Tests/ClickTests/RevisionTests.swift` expectations for `lines` accordingly.
2. `Click/Features/Profile/ProfileView.swift`, in `TimelineRow.content`, `.encounter` case, replace the compact `details` `Text` from last round with:
   - `Text(whenLine)` in `ClickTypography.caption`, `ClickColors.textSecondary`.
   - The title: event title, or "First Clicked at …" / "Reconnected at …", as today.
   - `Text(placeLine)` if it differs from the title.
   - The context tag pills (sparkle, `ClickColors.accentForeground`), replacing the current `TagFlow` of chips.
   - `FlowLayout(spacing: 6) { ForEach(metricPills) { TimelineMetricPill(pill: $0) } }`.
   - The vibe quote and "Edit tags", unchanged.
   - Put `TimelineMetricPill` as a `private struct` in `ProfileView.swift`.

**Tests (only these):** in `RevisionTests.swift`, one test that an encounter with temperature, condition, wind, noise, elevation and compass produces 6 pills in the table order with the exact texts.

**Done when:** on the phone, a profile timeline encounter shows the when line, place, tag pills and colorful metric pills. Each value is fully readable, nothing is truncated into one crowded line, and it visually matches the KMP app's timeline.

---

## Step 7 — Wrap-up
1. Run the full unit suite once. Everything must pass; the 205 tests from last round, minus the deleted Nearby tests, plus the new ones.
2. Build Release: `xcodebuild build -scheme Click -configuration Release -destination 'generic/platform=iOS Simulator'` with the same signing flags.
3. Install on the phone and walk every Done-when list above. Report each one as confirmed, or not, with what you saw.
4. Add ledger rows (Step 0 format), one per item: 3, 4, 5, 7, 10, and the server change.
5. Commit on `feat/ios-round6` with a message listing the five items, ending with the attribution line required by the environment.
6. **Don't** push or open PRs for click-ios unless the owner asks. The click-web PR (step 1) is the only PR.
