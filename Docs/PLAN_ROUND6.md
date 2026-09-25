# Click iOS — Round 6 plan (revision 2: corrections after the first implementation)

The first implementation of this plan was commit `e45aace`, on the old `round5-parity` branch. It fixed the timeline and mostly fixed Nearby. It also caused these regressions:

| # | Symptom on the phone | Verified root cause in `e45aace` |
|---|---|---|
| R1 | Some Click Drops, photos and files never load, inconsistently | `ChatView` passes closures to rows through a `ChatRowActions` object that is only filled in `.onAppear` (`setupRowActions`), **after** the first render. `MessageBubbleView` reads `mediaLoader` at init, so it's `nil` on the first pass and the bubble renders as plain text. `MessageRow.==` ignores the actions object, so the row is **never re-rendered** afterwards. |
| R2 | Messages bounce on chat open | The same rows first render as text bubbles. Whenever a row does re-render later (any item change), it turns into a media bubble with a different height. The chat-wide `.transaction { disablesAnimations }` also fights the initial layout. |
| R3 | The tab bar shows inside chats | `.toolbar(.hidden, for: .tabBar)` was removed and replaced with a UIKit swizzle (`TabBarPushPolicy`). **Verified in the simulator:** SwiftUI's `NavigationStack` *does* call `pushViewController`, and the swizzle *did* set `hidesBottomBarWhenPushed = true`, but SwiftUI's `TabView` ignores that flag and keeps the bar visible. No UIKit-flag approach can work. |
| R4 | Choosing an emoji not in the bar opens two dialogs | The **+** button dismisses the full-screen overlay **and** presents a second `.sheet` from `ChatView` at the same moment: a clear 60 pt sheet plus the keyboard, or the fallback sheet. Two presentations race. |
| R5 | Nearby only "somewhat" fixed | The structure is right (lip plus native sheet). Missing pieces: list scrolling at medium resizes the sheet, search doesn't expand it, and there's no check for the lip's tap target or for re-opening. |

Follow the steps **in order**. Each step lists:
- the files to change,
- the exact change,
- what *not* to do,
- a **Done when** check.

**A green build proves nothing about these bugs.** Check every Done-when on the phone and report what you saw.

---

## 0. Ground rules

**Branches**
- `click-ios`: work on **`feat/ios-round6`**, which is `main` plus this plan. Never commit to `main`.
- `click-web`: branch **`feat/ios-round6`** already has the server auth commit (`d4d1e34`, "verify mobile bearer tokens locally against Supabase JWKS").

**Build, install and log commands** (from `click-ios/`):
```
xcodegen generate
xcodebuild test -scheme ClickTests -destination 'platform=iOS Simulator,id=72F1B726-931E-4450-9617-919CEE1EFABA' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
  -derivedDataPath /tmp/claude-501/click-dd -collect-test-diagnostics never
xcodebuild build -scheme Click -configuration Debug -destination 'id=00008120-00025DA90E84C01E' \
  -derivedDataPath /tmp/claude-501/click-dd-dev -allowProvisioningUpdates
xcrun devicectl device install app --device 00008120-00025DA90E84C01E /tmp/claude-501/click-dd-dev/Build/Products/Debug-iphoneos/Click.app
xcrun devicectl device process launch --console --terminate-existing --device 00008120-00025DA90E84C01E compose.project.click.click
```
- If the simulator is stuck "Shutting Down": `xcrun simctl shutdown all; killall -9 com.apple.CoreSimulator.CoreSimulatorService`, then boot it again.
- Simulator UI checks: install the build, then launch with `xcrun simctl launch 72F1B726-931E-4450-9617-919CEE1EFABA compose.project.click.click -preview-shell`. That argument shows the real tab shell without a session, which is enough for tab-bar checks.

**Never do these** (each one caused a regression above):
1. Never fill closures, loaders or any input a view needs for its **first** render in `.onAppear`, `.task` or `init` side effects of another view. Everything a row needs must be passed in the same `body` pass that creates it.
2. Never write an `Equatable` view whose `==` ignores an input the view renders with. Don't add `.equatable()` to chat rows at all in this round.
3. Never present a second sheet or cover while another presentation from the same screen is showing or being dismissed. One presented surface at a time.
4. Never swizzle UIKit methods. Never use `hidesBottomBarWhenPushed`; it doesn't work with SwiftUI's `TabView` (verified).
5. Never apply `.transaction { $0.disablesAnimations = true }` or a blanket `.animation(nil)` to the whole chat screen.
6. Never remove `.toolbar(.hidden, for: .tabBar)` unless step 5's replacement is in place in the same commit.
7. Don't delete or rewrite code outside the files a step names.

**Tests:** add only the tests named in a step; the owner asked for minimal testing.

**Ledger:** one row per item in `Docs/PARITY_LEDGER.md`, before `## Phase 4 Direct Chat merge gate`, in the format of rows F88–F111. Device checks stay "Pending" unless the owner confirmed them.

---

## Step 1 — Bring in the first implementation, then remove its broken parts

1. From `feat/ios-round6`: run `git cherry-pick e45aace`. It applies cleanly (verified).
2. Delete these files and every reference to them:
   - `Click/App/TabBarPushPolicy.swift`
   - The line `TabBarPushPolicy.install()` in `Click/App/ClickApp.swift`
   - Every `.hidesTabBarWhenPushed()` call (it's defined in `TabBarPushPolicy.swift`; search the project with `grep -rn "hidesTabBarWhenPushed" Click`)
3. In `Click/Features/Chat/ChatView.swift`, delete the `.transaction { transaction in if actionTarget != nil { transaction.disablesAnimations = true } }` modifier.
4. Run `xcodegen generate` and build. Fix only compile errors caused by these removals.

**Done when:** it builds, and `grep -rn "TabBarPushPolicy\|hidesTabBarWhenPushed\|disablesAnimations = true" Click/Features/Chat Click/App` returns nothing.

---

## Step 2 — R1 and R2: chat rows render media on the first pass and never bounce

File: `Click/Features/Chat/ChatView.swift`.

1. **Delete** the `private final class ChatRowActions`, the `private struct MessageRow`, the `rowActions` state, `setupRowActions(proxy:)` and the `.onAppear { setupRowActions(proxy: proxy) }` call.
2. Replace the `ForEach` body in `timeline(proxy:)` with the inline row below. It is the row from `main` (commit `58c6d15`, `ChatView.swift` lines 241–303) minus the old `onMoreReactions` argument and plus `onLongPress`. Keep the `byID` dictionary computed once at the top of `timeline(proxy:)`.
   ```swift
   ForEach(Array(model.items.enumerated()), id: \.element.stableID) { index, item in
       if shouldShowDateHeader(at: index) {
           Self.dateHeader(item.createdAt)
       }
       if item.id == model.firstUnreadID {
           UnreadDivider().id("unread-divider")
       }
       MessageBubbleView(
           message: item,
           onReply: { target in
               withAnimation(ClickMotion.selection) {
                   model.editTarget = nil
                   model.replyTarget = target
               }
           },
           onEdit: { target in
               withAnimation(ClickMotion.selection) {
                   model.replyTarget = nil
                   model.editTarget = target
                   model.composerText = target.content
               }
           },
           onDelete: { target in Task { await model.deleteMessage(item: target) } },
           onToggleReaction: { target, emoji in Task { await model.toggleReaction(item: target, reactionType: emoji) } },
           onRetrySend: { target in Task { await model.retrySend(item: target) } },
           showsSenderName: !model.identity.isDirect && startsSenderRun(at: index),
           showsReceipts: model.identity.supportsReceipts,
           mediaLoader: { message in try await model.mediaURL(for: message) },   // never nil
           onOpenMedia: { url, kind in
               if kind == .image { viewerURL = ViewerURL(url: url) } else { quickLookURL = url }
           },
           onOpenBeacon: { beacon in
               env.router.navigate(to: beacon.isEvent ? .event(beaconID: beacon.beaconID) : .beacon(beaconID: beacon.beaconID))
           },
           onDiscardFailed: { target in withAnimation(ClickMotion.content) { model.discardFailed(item: target) } },
           onForward: conversations != nil && model.canForward(item) ? { forwarding = $0 } : nil,
           onSaveMedia: { target in Task { await saveOrShare(target) } },
           onShowReactions: { target, reaction in reactorsFor = ReactorsTarget(message: target, reaction: reaction) },
           replyTarget: item.replyToID.flatMap { byID[$0] },
           onTapReplyQuote: { id in Task { await jump(to: id, proxy: proxy) } },
           onLongPress: { message, frame in actionTarget = ActionTarget(message: message, frame: frame) }
       )
       .background {
           if highlightedID == item.stableID {
               ClickColors.accentForeground.opacity(0.14).transition(.opacity)
           }
       }
       .id(item.stableID)
       .transition(.asymmetric(
           insertion: .move(edge: .bottom).combined(with: .scale(scale: 0.92, anchor: item.isOutgoing ? .bottomTrailing : .bottomLeading)).combined(with: .opacity),
           removal: .opacity
       ))
   }
   ```
3. **Keep** from `e45aace` (these are correct and fix the lag):
   - the plain `LazyVStack(spacing: 2)`
   - the removal of `.scrollPosition(id:)`
   - the `VisibleRows` reference box with `.onScrollTargetVisibilityChange`
   - the `userHasScrolled` + `onScrollGeometryChange` near-top trigger
   - `ChatBackground(...).equatable()` with the `Canvas` `.drawingGroup()`
   - the per-conversation model registry in `AppEnvironment`
4. `MessageBubbleView.swift`: change `mediaLoader` from optional to **required** (`let mediaLoader: (ChatMessageItem) async throws -> URL`, no default). The media branch becomes `else if let media = message.media { … MessageMediaContent(…, load: { try await mediaLoader(message) }, …) }`. The compiler then shows every call site that could render media without a loader. Fix each by passing `{ try await model.mediaURL(for: $0) }`, including the lifted copy in `MessageActionOverlay` (step 4). Where no model exists, pass `{ _ in throw ChatRepositoryError.mediaUnavailable }`.
5. Opening a chat must never move the timeline:
   - Keep `.defaultScrollAnchor(.bottom)`.
   - The only programmatic scroll on open is the existing `.onChange(of: model.phase)` handler, and it must run **only** when the phase changes *to* `.loaded` from `.initial`/`.loading`. Guard it with `guard oldPhase != .loaded, newPhase == .loaded`, using the two-parameter `onChange` closure.
   - A reused model that is already `.loaded` doesn't scroll at all.
   - Don't add any other `scrollTo` on appear.

**Tests (only this one):** none new. Run the existing suite.

**Done when:** on the phone, check each of these message types in a direct chat, a group and a hub (hub: photo and Click Drop only):
- text
- photo
- locked Click Drop (pixelated with the "develops in" label)
- developed Click Drop
- voice note (plays)
- file (opens Quick Look)
- event card
- a reply quoting a photo (thumbnail shows)

Each must render correctly on **every** one of 10 consecutive opens of the same chat. On each open, the timeline appears at the latest message with **no visible movement**. Record a screen capture of 3 opens and confirm frame by frame that nothing shifts.

---

## Step 3 — Scroll performance check (no new code unless it fails)

After step 2, fling-scroll a group with 150+ messages from bottom to top and back.
- **Done when:** there's no visible stutter, and older pages load only near the top.
- **If it stutters:** attach Instruments ("SwiftUI" template) and report the top body-evaluation counts. **Don't** reintroduce `Equatable` rows.

---

## Step 4 — R4: reactions bar with a full emoji picker on ONE surface

Keep `MessageActionOverlay` from `e45aace`: the blurred backdrop, the lifted bubble, the capsule above and the action panel below. The owner confirmed the separate bar is right. Change only how **+** works.

### 4a. Remove the second presentation
In `ChatView.swift`, delete:
- `@State private var moreReactionsTarget`
- the whole `.sheet(item: $moreReactionsTarget) { … }`
- the `onMoreReactions:` argument passed to `MessageActionOverlay`

### 4b. Pick emoji inside the overlay
In `Click/Features/Chat/MessageActionOverlay.swift`:
1. Remove the `onMoreReactions` property and its init parameter.
2. Add `@State private var pickingEmoji = false`.
3. The **+** button sets `pickingEmoji = true`. It **must not** call `onDismiss()`.
4. When `pickingEmoji` is true:
   - Hide the action panel (`.opacity(0)` and `.allowsHitTesting(false)`).
   - Move the bubble copy and reaction capsule to the top: bubble center y = `safeAreaTop + 16 + 56 + 8 + bubbleHeight / 2`, so they stay visible above the keyboard.
   - Add, inside the overlay's `ZStack`:
     ```swift
     if EmojiKeyboardPicker.hasSystemEmojiKeyboard {
         EmojiKeyboardPicker { emoji in
             onReact(emoji)
             onDismiss()
         }
         .frame(width: 1, height: 1)
         .opacity(0.01)                 // invisible field; the system emoji keyboard is the picker
     } else {
         EmojiFallbackPanel { emoji in   // see 4c
             onReact(emoji)
             onDismiss()
         }
         .frame(maxHeight: geometry.size.height * 0.45)
         .frame(maxHeight: .infinity, alignment: .bottom)
         .transition(.move(edge: .bottom))
     }
     ```
5. Tapping the backdrop while picking dismisses everything:
   - Call `onDismiss()`.
   - The keyboard resigns automatically when the overlay's view is removed. If it doesn't, call `UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)` first.

### 4c. Fallback panel and emoji filter
In `Click/Features/Chat/EmojiKeyboardPicker.swift`:
- Rename `EmojiFallbackSheet` to `EmojiFallbackPanel`.
- Make it a plain `View`, not something that's presented: a rounded-top `.regularMaterial` panel with a `.searchable`-style `TextField` at the top and a `LazyVGrid` of every entry from `EmojiKeyboardPicker.allEmoji()`.
- Replace the coordinator's emoji check with:
  ```swift
  /// Any emoji the keyboard can produce: single emoji, flags, keycaps, ZWJ sequences, skin tones.
  nonisolated static func isEmoji(_ character: Character) -> Bool {
      character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
          || character.unicodeScalars.contains { $0.value == 0xFE0F }
  }
  ```
  Use it as `if let first = string.first, Self.isEmoji(first) { onPick(String(first)) }`.

**Tests (only these):** in `Tests/ClickTests/MessageOperationsTests.swift`:
- `isEmoji` is true for "👍", "🇺🇸", "1️⃣", "👩🏽‍💻" and false for "a" and "1".
- `allEmoji().count > 1000`.

**Done when:** on the phone:
1. Long-press a message: one overlay appears.
2. Tap **+**: the action panel hides, the message and bar move up, and the **system emoji keyboard** rises. There's **exactly one** surface; no sheet slides up.
3. Pick "🇺🇸": the reaction is added and everything closes in one motion.
4. Repeat, but tap the backdrop instead: everything closes and the keyboard goes away.
5. Quick reactions (👍 and so on) still work with one tap.

---

## Step 5 — R3: tab bar slides away and back with chats (WhatsApp parallax)

**Verified in the simulator** with a prototype on the Me tab:
- `.toolbar(.hidden, for: .tabBar)` applied to the **`NavigationStack`** hides the system bar on the root *and* on every pushed screen.
- A bar placed in the **root view's** `.safeAreaInset(edge: .bottom)` belongs to the root screen. It leaves with the root when a screen is pushed and returns with it on pop, including the interactive back swipe.

That is WhatsApp's behavior. Implement it for all five tabs.

### 5a. The bar
Create `Click/App/ClickTabBar.swift`:
```swift
import SwiftUI

/// The app's tab bar, attached to each tab's *root* screen so it slides out and back in with
/// navigation pushes and pops (including interactive back), like WhatsApp. The system tab bar
/// is hidden; `TabView` still owns tab state and per-tab navigation stacks.
struct ClickTabBar: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(ConversationListModel.self) private var conversations
    @Environment(MeTabAvatarModel.self) private var meTabAvatar
    @State private var keyboardVisible = false

    var body: some View {
        Group {
            if !keyboardVisible {
                HStack(spacing: 0) {
                    item(.home, title: "Home") { Image(systemName: "house.fill") }
                    item(.addClick, title: "Add Click") {
                        Image(systemName: "plus.circle.fill").foregroundStyle(ClickColors.accentForeground)   // always purple
                    }
                    item(.connections, title: "Clicks", badge: conversations.unreadTotal) { Image(systemName: "person.2.fill") }
                    item(.map, title: "Map") { Image(systemName: "location.fill") }
                    item(.settings, title: "Me") {
                        if let avatar = meTabAvatar.image {
                            Image(uiImage: avatar).resizable().scaledToFill().frame(width: 26, height: 26).clipShape(Circle())
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                        }
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 64)
                .glassCircleBackground()
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
    }

    private func item<Icon: View>(_ tab: MainTab, title: String, badge: Int = 0, @ViewBuilder icon: () -> Icon) -> some View {
        let selected = env.router.selectedTab == tab
        return Button {
            if tab == .addClick { ClickHaptics.impact(.medium) } else { ClickHaptics.selection() }
            env.router.selectTab(tab)   // re-tapping the current tab pops to its root
        } label: {
            VStack(spacing: 3) {
                icon()
                    .font(.system(size: 21, weight: .semibold))
                    .frame(height: 26)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text(badge > 99 ? "99+" : "\(badge)")
                                .font(.caption2.weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                                .background(Color.red, in: Capsule())
                                .offset(x: 12, y: -6)
                        }
                    }
                Text(title).font(.caption2.weight(.medium))
            }
            .foregroundStyle(selected ? ClickColors.accentForeground : ClickColors.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(title), \(badge) unread" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
```
Check that `MeTabAvatarModel` is injected with `.environment(meTabAvatar)` in `MainTabShellView` (it is) and that it's `@Observable`. If it isn't observable, pass `meTabAvatar.image` in as a parameter instead.

### 5b. Wire it into the shell
In `Click/App/RootGateView.swift` → `MainTabShellView`, for **each** of the five tabs:
1. Add `.toolbar(.hidden, for: .tabBar)` to the `NavigationStack`, next to the existing `.tabFadeIn(…)`.
2. Add `.safeAreaInset(edge: .bottom, spacing: 0) { ClickTabBar() }` to the tab's **root view**, the first view inside the `NavigationStack` (`HomeView()`, `AddClickView()`, `ClicksView(model:)`, `ClickMapView()`, `MeView()`). Put it right after that root view, **before** `.appRouteDestinations()`.
3. Keep the `Tab(...)` labels; they're harmless and keep VoiceOver tab semantics for the hidden bar.
4. Delete the now-unused `addClickIcon` static and the haptic in the `selection` binding setter. The bar does both now.

### 5c. Screens
- `ChatView`: remove any `.toolbar(.hidden, for: .tabBar)` or `.toolbar(.visible, …)`. Pushed screens never show a bar.
- `ClickMapView`: its `GeometryReader` now sits above the custom bar via the safe-area inset, so `NearbyLip` automatically sits above the bar. Don't add manual offsets.
- Any other screen that calls `.toolbar(... for: .tabBar)`: find them with `grep -rn "for: .tabBar" Click`. Remove every call except the five `NavigationStack` ones from 5b.

**Done when:**
- *In the simulator with `-preview-shell`:* the system bar is never visible; the custom bar shows on all five tab roots; the Clicks badge shows; the Me avatar shows.
- *On the phone:*
  1. Opening a chat slides the bar left and away **with** the Clicks list.
  2. Tapping Back slides the list **and** the bar back in together.
  3. A slow interactive back swipe shows the bar tracking the finger. Cancel the swipe halfway: the bar goes back smoothly.
  4. Re-tapping Clicks while in a chat pops to the list.
  5. Add Click is purple with a haptic.
  6. Typing in Home search or the Nearby search hides the bar while the keyboard is up.

---

## Step 6 — R5: Nearby polish

Keep `NearbyLip`, `NearbyListView` and the native `.sheet` from `e45aace`. Add the following to the `.sheet` in `Click/Features/Map/ClickMapView.swift`:
1. `.presentationContentInteraction(.scrolls)`, so scrolling the list at half height scrolls the list instead of resizing the sheet.
2. In `NearbyListView`, when the search field gains focus, set `model.nearbyDetent = .large`: `.onChange(of: isSearchFocused) { _, focused in if focused { model.nearbyDetent = .large } }`.
3. `NearbyLip`:
   - The whole card is the tap target: `.contentShape(RoundedRectangle(cornerRadius: 30, style: .continuous))` **before** the tap and drag gestures.
   - Minimum height 64.
   - Accessibility: `.accessibilityAddTraits(.isButton)` and `.accessibilityHint("Opens the Nearby list")`.
4. When the sheet is dismissed by dragging down, `model.nearbyDetent` resets to `.medium`, so the next open starts at half height: `.onChange(of: model.isNearbyPresented) { _, open in if !open { model.nearbyDetent = .medium } }`.

**Done when:** on the phone:
1. Tapping anywhere on the lip opens the sheet at half height, rounded, over the tab bar.
2. At half height, the list scrolls without the sheet moving; dragging the grabber changes the height.
3. Tapping search goes to full height with the keyboard.
4. Tapping a place closes the sheet and shows its callout on the map.
5. Reopening starts at half height.
6. Switching tabs while it's open closes it.

**If the owner reports a different Nearby problem, fix that and add it to this list.**

---

## Step 7 — Server auth speedup (click-web)

1. Open a PR from click-web `feat/ios-round6` to `main`. **Don't merge**; the owner merges and deploys.
2. After deployment: launch the app on the phone with `--console` and read the `[net]` lines.

**Done when:** authenticated `/api/...` calls average **< 600 ms** (they were 1,000–1,900 ms). Record the numbers in the ledger.

---

## Step 8 — Wrap-up
1. Run the full unit suite once; everything passes.
2. Build Release (`-configuration Release -destination 'generic/platform=iOS Simulator'`, same signing flags).
3. Install on the phone and walk **every** Done-when above. Report each one as ✅ or ❌ with what you saw. Don't summarize without the list.
4. Ledger rows: one each for R1–R5 and the server change.
5. Commit on `feat/ios-round6`, ending the message with the attribution line required by the environment. Don't push unless the owner asks.
