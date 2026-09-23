Click iOS Prototype Reconciliation Audit

Claude Opus 5.5 artifact vs. current click-ios vs. native rebuild/refinement specifications

Date: 2026-09-23
Repository reviewed: lightningbolts/click-ios, main (GitHub results resolved to commit 54f5e2609177f14d22e9e0d04f8d4eb8be5797c4)
Prototype reviewed: uploaded Click prototype · dark-html.zip, 390×844 dark reference
Specifications reviewed: CLICK_NATIVE_IOS_REBUILD_SPEC.md and click_ui_refinement_spec_2026-09-21.md

1. Executive determination

The prototype is strong enough to become the canonical visual and interaction reference for the native Click iOS redesign, with one important qualification: it should not become the canonical source of product behavior or implementation architecture.

The correct hierarchy of authority is:

Product behavior, data semantics, privacy, security, parity, and edge cases: CLICK_NATIVE_IOS_REBUILD_SPEC.md, current backend contracts, and verified existing product behavior.

Visual hierarchy, density, proportions, tone, screen composition, and interaction intent: the Opus 5.5 prototype.

Cross-screen polish constraints and “what feels wrong today”: click_ui_refinement_spec_2026-09-21.md.

Implementation mechanism: native SwiftUI/UIKit/MapKit/AVFoundation/etc., using platform behavior rather than the prototype's HTML/CSS/JS mechanics.

Current click-ios code: implementation starting point, not visual authority where it conflicts with the prototype/refinement spec.

This matters because the prototype is unusually good at translating the September refinement goals into a coherent system. Its strongest qualities are systemic: it reduces saturated purple, uses neutral surfaces, separates brand typography from utility typography, makes controls and spacing feel related, gives the five roots distinct but coherent information architecture, and models navigation/sheets as a consistent spatial system.

The current native code is already structurally much healthier than the old KMP application. The TabView + per-tab NavigationStack architecture and AppRouter are fundamentally correct. The native rewrite therefore does not need another navigation architecture rewrite. It needs a disciplined design-system reconciliation and screen-composition pass.

The largest current mismatch is the design system. ClickColors, ClickTypography, and ClickSpacing still encode the earlier “Functional Clarity” visual direction, while individual views frequently bypass those tokens with one-off radii and dimensions. This produces exactly the inconsistency the prototype resolves. The fastest route to a commercial-quality result is to update the semantic primitives first and then make each screen conform to the prototype's hierarchy.

2. What the prototype actually establishes

The artifact is not just a collection of screenshots. Its source establishes a fairly complete UI system.

The dark theme uses:

pure black root/background;

#1C1C1E as the primary elevated/grouped surface;

neutral iOS-like grays for lower emphasis;

#7C3AED for strongly filled primary actions;

#A884FF / #C3A6FF for dark-mode accent foregrounds;

#24133F for low-emphasis purple tint;

neutral separators (rgba(84,84,88,.6)) rather than purple borders;

#232326 incoming chat bubbles;

#4A1FA6 outgoing chat bubbles;

#0B0B0D chat environment.

Typography is deliberately split. Manrope is used for major product/brand hierarchy such as 34 pt large titles, 22 pt section titles, and 28–30 pt identity/event titles. Most ordinary interface copy is system/SF Pro: 17 pt row text and buttons, 15 pt supporting text, 13–15 pt metadata, and 17 pt compact navigation titles. This split is one of the biggest reasons the artifact feels more native than the current implementation.

The primary geometry is also coherent:

44 pt circular or pill toolbar controls;

50 pt primary buttons;

42 pt search fields;

54 pt minimum grouped rows;

36 pt compact chips;

26 pt grouped-list/surface radii;

~18 pt message bubble radii;

~38 pt top sheet radius;

16–20 pt common screen gutters;

62 pt floating reference tab-bar height.

These values should be treated as optical references, not blindly hard-coded at every call site. Dynamic Type and content size still need to win when text grows.

The prototype also models a common spatial language:

root screens stay mounted;

each root has its own navigation stack;

pushed screens enter horizontally;

edge-back gestures reveal the underlying screen;

full sheets create depth by visually receding the root;

map discovery grows continuously from a compact lip;

tab chrome disappears only for appropriately immersive screens such as chat/QR;

compact titles appear as large content titles scroll under the top chrome;

the same toolbar-control dimensions recur everywhere.

That coherence is more important than any individual shadow or radius.

3. Where the prototype aligns with the September refinement spec

The alignment is unusually strong.

3.1 Fewer visible surfaces

The September refinement explicitly says ordinary metadata should stop becoming a card and that surfaces should be reserved for controls, manipulable objects, or meaningful semantic groups.

The prototype follows this well. Rows are usually grouped inside one 26 pt surface. The Clicks conversation list is largely allowed to read as a list rather than a wall of individual cards. Profile metadata is grouped. Event date/location/attendance becomes one information region. Settings uses grouped regions rather than a huge sequence of separate cards.

This is a direct improvement over many current native views, where the visual system still relies on bordered rounded rectangles to establish structure.

3.2 Purple becomes an accent

The current code's design token naming and usage still encourage ClickColors.primary to appear almost everywhere. The prototype separates several purple roles:

dark-mode accent foreground;

filled primary-action purple;

quiet purple-tinted backgrounds;

outgoing-message purple.

This is superior to one primary token being reused for CTA fills, message bubbles, borders, icons, selected segments, chips, and highlights.

The key lesson is not “change the brand purple.” It is “stop making one purple perform every semantic job.”

3.3 Text hierarchy is clearer

The prototype has a meaningful gap between identity, ordinary supporting copy, tertiary metadata, and disabled/incidental text.

The current ClickTypography implementation undermines some of this because Manrope is used for virtually all roles and many secondary labels remain fairly high-contrast. The artifact's Manrope/SF split and more aggressive tertiary gray make the screens scan more naturally.

3.4 Density is more disciplined

The prototype is not merely “more spacious.” In several places it is denser:

Clicks reaches conversation content faster.

grouped rows are only 54 pt minimum;

chips are 36 pt;

top controls are 44 pt;

recent connections are horizontally compact;

recap is visually lower priority;

map controls float without large surrounding cards.

This is closer to WhatsApp's information density while retaining Click's identity.

4. Authority model: preserve, adapt, reject

Prototype characteristic

Decision

Production interpretation

Neutral black / iOS-gray dark hierarchy

Preserve

Rework semantic colors toward neutral rather than green/purple-tinted dark surfaces.

Purple used selectively

Preserve

Split fill, foreground, tint, and outgoing-message semantic roles.

Manrope for major identity; SF/system for utility UI

Preserve

Change typography token architecture.

44 pt toolbar controls

Preserve

Use native controls with 44 pt minimum hit targets.

50 pt main CTAs

Preserve

Minimum height, not a text-clipping fixed height.

26-ish major grouped surfaces

Preserve semantically

Define surfaceRadius; do not set every rounded object to 26.

Per-tab navigation state

Preserve

Existing AppRouter already supports this.

Inline compact title after scrolling

Preserve intent

Prefer native navigation/toolbar behavior; avoid a second manual navigation hierarchy.

Floating glass tab bar

Adapt

Keep native TabView/platform tab bar. Reproduce tone, not DOM geometry.

HTML glass blur

Adapt

Use platform material/Liquid Glass APIs with fallbacks; no generic custom blur framework.

Custom JS push animation

Reject literally

Native NavigationStack owns push/pop and interactive back.

Custom 22 px edge gesture

Reject literally

Preserve system interactive-pop behavior.

Fake on-screen keyboard

Reject

System keyboard only.

Fake stylized map

Reject

MapKit is authoritative. Preserve overlay hierarchy and pin language.

Custom sheet translation physics

Adapt

Use native detents/system arbitration where possible; custom container only if needed for the lip interaction.

390×844 fixed layout

Reject

Use safe areas, Dynamic Type, and responsive constraints.

Hard-coded demo data

Reject

Only real supported data/categories.

Equal peer-profile action tiles

Modify

Keep identity composition, but Message must retain clear primary hierarchy.

Generic chat doodle only

Modify

Use it only as fallback/reference; September spec calls for encounter-derived ambient backgrounds.

5. Design-system reconciliation

5.1 Colors: the current dark palette is one of the largest visual mismatches

Current native dark tokens include approximately:

background #101212;

surface #1A1C1C;

low surface #1E2020;

container #242626;

high container #2A2C2C;

text #F0F1F1;

secondary #D6D9D9;

quiet border #4A3D5C.

The prototype instead centers on:

background #000000;

surface #1C1C1E;

secondary translucent fills derived from neutral gray;

primary text #FFFFFF;

secondary text around iOS secondary-label contrast;

tertiary #98989F;

neutral separator gray;

accent foreground #A884FF;

filled primary action #7C3AED;

subtle brand tint #24133F.

The current palette's subtle cyan/green cast (#101212, #1A1C1C) and purple-gray border (#4A3D5C) make the interface feel more custom-themed and less like premium native iOS. The prototype's neutral system-like foundation lets content and purple accents become the distinctive elements.

Recommended semantic roles

Do not replace ClickColors.primary with a single new magic hex and call this done. Restructure the roles:

background
plainBackground
surface
surfaceElevated
fillSubtle
fillStrong
separator
textPrimary
textSecondary
textTertiary

brand
accentForeground
primaryActionFill
primaryActionForeground
selectionTint

messageIncoming
messageOutgoing
chatBackground

success
warning
destructive
online

Where possible, semantic platform colors should back ordinary labels and fills. Exact prototype hex values should be used where they are intentionally brand-specific or necessary to reproduce the visual identity.

A particularly important change is to stop using the same brand token for outgoing chat bubbles and primary buttons. The artifact deliberately uses a darker outgoing bubble than the primary CTA.

5.2 Typography: current code overuses Manrope

ClickTypography currently returns Manrope for nearly every semantic role. The prototype does not.

Recommended split:

Role

Prototype reference

Native direction

Root large title

Manrope ExtraBold ~34/41

Manrope

Major identity/event title

Manrope ExtraBold 28–30

Manrope

Section headline

Manrope ExtraBold ~22/28

Manrope

Compact navigation title

SF/system 17 semibold

System

Primary/secondary button

SF/system 17 semibold

System

List row title

SF/system 17 regular/semibold

System

Body

SF/system 15–17 regular

System

Metadata

SF/system 12–15

System

Tab-label chrome

Native platform

Native

This would make Manrope a Click signature rather than the texture of every piece of text.

Do not remove Dynamic Type. The prototype's numbers are base optical targets, not permission to use unscaled fixed fonts.

5.3 Radii: current token definitions do not match current code or the prototype

ClickSpacing currently declares:

input radius 8;

button radius 8;

card radius 16.

But individual files already hard-code 12, 14, 15, 16, 18, 20, 22, etc. The result is that the radius “design system” is not actually authoritative.

Replace it with semantic geometry:

compactRadius        ~ 11–14     badges, compact auxiliary surfaces
controlRadius        capsule/half-height where appropriate
surfaceRadius        ~ 24–26     grouped semantic regions
prominentRadius      ~ 28–30     hero/connect surfaces
sheetTopRadius        platform / ~38 reference
messageBubbleRadius  ~ 18

Do not turn every surface into a 26 pt rounded rectangle. The September spec correctly says different roles should have different radii.

5.4 Control metrics

Create semantic metrics for:

toolbar hit target     44
standard row min       54
search min height      42
compact chip height    36
secondary control      44
primary action         50
large quick action     ~64 visual, >=44 hit target
screen gutter          ~16

Again, these should generally be minHeight, not text-clipping hard heights.

5.5 Borders and elevation

The native app currently uses many overlays such as:

.stroke(ClickColors.quietBorder.opacity(...), lineWidth: 1)

The prototype uses borders far less frequently. This is a major improvement.

Rules:

do not border a surface simply because it has a background;

incoming message bubbles should not need a bright purple-gray outline;

grouped list boundaries should normally come from background contrast;

use hairline separators inside groups;

reserve stronger elevation for navigation chrome, sheets, floating map controls, menus, and modal objects;

no full-screen stacks of blur layers.

5.6 Icons

Use SF Symbols/native iconography where it covers the product need. Standardize optical weight, not only nominal frame size. Most ordinary toolbar glyphs in the artifact are visually around 18–24 pt inside a 44 pt target.

Avoid custom icon libraries unless an actual product symbol cannot be represented correctly.

6. Navigation and app shell

6.1 Current native architecture: keep it

MainTabShellView already uses one NavigationStack per tab, with independent paths in AppRouter:

homePath
addClickPath
connectionsPath
mapPath
settingsPath

This is exactly the right conceptual model for the prototype's “each tab remembers its own stack” behavior.

Do not replace this with the prototype's hand-built .slot stack or JS transitions.

6.2 Preserve native interactive back

The prototype manually implements a 22 px edge zone and horizontal translation. In production, SwiftUI/UIKit navigation should own interactive back. A manually competing full-screen drag would reintroduce the gesture conflicts that previously damaged chat/media behavior.

If a particular destination breaks native interactive pop, fix that destination's gesture arbitration rather than creating another app-wide back gesture.

6.3 Tab bar

The prototype's 62 pt floating glass capsule is an excellent visual reference, but the rebuild specification correctly calls for native tab interaction.

Keep TabView.

The production goals should be:

visually neutral glass/material;

compact;

active tab identified with a quiet selection treatment and purple foreground;

no saturated purple pill behind every active tab;

tab state preserved;

reselect active tab returns to root;

hidden only for immersive/pushed flows where appropriate;

the Me tab uses the user's actual avatar.

Current MainTabShellView still uses person.crop.circle.fill for Me. This should be changed. The spec explicitly requires the signed-in avatar with a fallback.

If SwiftUI's current tab item API cannot directly host an asynchronously loaded avatar without destabilizing the native tab bar, generate/cache a small UIImage for the tab item or bridge only the tab-item image. Do not build a custom tab bar to solve this single problem.

6.4 Route coverage is currently incomplete

AppRouter already defines:

chat;

user profile;

group profile;

event;

beacon;

hub;

QR/tap routes;

saved events.

But destination coverage is uneven.

Current Clicks navigation handles user profile and direct chat, but groupProfile is not handled in the shown switch.

Map routes event and beacon to the same generic MapRouteDetailView(kind: .beacon) rather than a canonical event-detail feature.

The settings stack receives .savedEvents from the router, but the root shell does not visibly define an AppRoute navigation destination for the settings stack.

Before visual polish is declared complete, every typed route should have exactly one canonical destination implementation.

6.5 Root and pushed chrome

The prototype's pattern is correct:

root screens have a large content title;

top controls remain in stable positions;

after scrolling, a compact centered title appears;

pushed screens use stable back/trailing action slots.

Production should reproduce this with native navigation chrome wherever possible. Avoid a second overlay navigation hierarchy whose title and buttons animate independently from the destination; that was a major source of KMP-era flicker.

7. Home

7.1 Current native hierarchy is wrong relative to the latest design direction

Current HomeView orders roughly:

greeting;

search;

availability;

recap;

featured event;

nearby;

recent connections;

stats.

That puts analytics before immediate social activity.

The rebuild spec says Home should read roughly as:

greeting/search;

current availability;

one highest-relevance social prompt;

recap/recent activity;

saved/upcoming events;

nearby discovery;

lower-priority insights.

The September refinement further says historical analytics should be visually quieter than immediate relationship actions.

The prototype solves this much better:

greeting/search;

“I'm down for…”;

“Happening now” event hero;

recent connections plus reconnect affordance;

recap;

saved/upcoming events;

explore nearby;

insights.

I would adopt the prototype ordering.

7.2 Availability

Current native UI uses intent pills followed by a full-width 48 pt purple “Manage what you're down for” button. That gives availability management too much CTA weight.

The prototype instead treats the active intent as a row/grouped state and exposes add/manage as a quieter row/action. This is better.

Recommendation:

active intent gets a concise state row;

add/manage stays obvious but does not compete with the screen's primary social opportunity;

editing remains a native sheet;

availability sheet retains one primary “Share availability” action.

7.3 Featured event / social prompt

The artifact's “Happening now” block should be the reference for a high-priority Home module:

meaningful visual;

live/status label;

title;

date/place;

mutual people;

attendance context;

exactly one strong local primary action;

secondary map action.

Do not represent each metadata field as its own card.

The backend/product should decide whether this module is an event, reconnect prompt, archive warning, etc. The visual slot should be capable of presenting the most relevant item without several equally dominant hero modules appearing simultaneously.

7.4 Recent connections

The prototype's horizontal avatar strip is much better suited to “recent people” than the current full-width row list. It communicates people as a lightweight social layer rather than another inbox.

Use:

cached common avatar component;

first name;

quiet recency metadata;

optional online state;

optional reconnect prompt integrated beneath the strip.

Do not add encounter-count badges such as 3x unless they communicate a meaningful current product state. They increase telemetry-like visual noise.

7.5 Recap

Current code has a correctness problem as well as a hierarchy problem:

displayedRecap ?? snapshot.recap ?? .init()

If recap is unavailable, .init() risks rendering a fake all-zero recap. The rebuild spec explicitly says backend failure must not render a fake zero-stat recap.

The prototype's visual treatment is also better:

lower in the page;

compact segmented Day/Week control;

grouped rows;

no extra border around an already visible surface.

Implement explicit recap states:

cached
loading refresh
fresh
confirmed empty
failure/stale
unavailable/hidden

7.6 Loading

Current Home still gates the main body on one snapshot.

The specification calls for a stable scaffold with independently loadable modules. This does not necessarily mean every card needs its own network endpoint. It means the presentation model cannot allow one slow subresource to prevent or shift the whole page.

Create a Home presentation model with stable keyed section state. Seed cached data immediately. Refresh compatible modules concurrently. Reserve geometry for important first-viewport modules where appropriate. Never replay entrance animations because a recap request finished.

7.7 Home acceptance target

The first viewport should show, without feeling crowded:

greeting/identity;

search;

availability state;

one obvious social opportunity.

It should not primarily read as an analytics dashboard.

8. Clicks inbox

This is one of the clearest wins in the prototype and should be an early calibration screen for the design system.

8.1 Current native screen is still too front-loaded

The current structure has:

large title;

active connection subtitle;

large three-way segment;

“Remember Me” heading;

avatar strip with encounter-count badges;

another “Clicks” section heading;

then conversations.

The September refinement says the conversation rows should begin sooner and remain the primary content.

The prototype does exactly that.

8.2 Adopt the prototype hierarchy

Recommended root structure:

large title;

inline inbox search;

compact Active / Groups / Archived filters;

optional compact Remember strip;

optional single nudge;

conversation list immediately.

Remove redundant textual hierarchy where the active filter already communicates it.

For example, if the page title says “Clicks” and the selected chip says “Active (23),” a second “23 active connections” subtitle and a later “Clicks” heading provide little additional value.

8.3 Search

The prototype's inline inbox search is appropriate for filtering the conversation list.

Separately, Click should have one global search feature. The current native implementation has a HomeSearchSheetView and a separate clicksSearchSheet, which risks duplicating search behavior. Consolidate global search.

A good division is:

inline Clicks search = local inbox filtering;

global toolbar search = canonical cross-domain search sheet.

Do not create two different cross-domain search implementations.

8.4 Filters

Current selected inbox tabs use a fully saturated purple capsule. The prototype uses quieter selection.

Change to:

neutral or low-tint active background;

accent foreground;

no strong border unless needed;

native-feeling compact dimensions.

Purple should indicate selection, not occupy a third of the viewport.

8.5 Conversation rows

The prototype's row density is closer to the desired commercial standard:

~56 pt avatar;

17 pt name;

lower-contrast timestamp;

one/two-line preview;

unread badge;

delivery state;

new/expiring context where applicable;

no enclosing card.

Current code already has a useful structural separation between avatar tap and row tap. Preserve it.

Add/complete:

unread badge;

mark-unread state;

Core state;

native swipe actions;

native context menu;

correct group/hub row variants;

realtime row reorder/update by stable identity.

8.6 Remember Me

Keep it compact and subordinate. It should disappear when irrelevant or when a search context makes it distracting.

Use the same shared avatar component as every other part of the app.

9. Add Click

The prototype gives Add Click a much clearer purpose than the current list-heavy implementation.

9.1 Current native problem

The current Tap-to-Connect affordance is a horizontal card with icon/text/chevron. My QR and Scan QR are plain list rows. Several unavailable functions are shown as dimmed rows.

This makes the most important product interaction feel like a settings menu.

9.2 Prototype direction

Adopt the prototype's interaction-led composition:

large centered Tap-to-Connect hero;

visible sensing/connection visual;

short explanation;

one Start action;

quick circular actions for QR/scan/group/hub;

lower-priority explanatory/community rows beneath.

Tap to Connect is Click's signature physical interaction. It should not visually resemble “open another settings screen.”

9.3 Do not fake readiness

The current native screen explicitly says the tri-factor BLE/ultrasonic engine is not yet ported. The prototype simulates a complete experience.

Do not ship the prototype's complete-looking Tap flow until the actual native handshake state machine is functional.

The final states should include:

idle
permission preparation
discovering/listening
candidate found
verification/proximity
success
already connected
expired/failed
retry/cancel

Visual polish should be layered onto real states.

9.4 QR

The prototype improves the QR screen significantly:

identity/avatar above the code;

clearer code hierarchy;

visible time/expiry state;

explicit single-use explanation;

Scan instead;

Share.

The current native QR implementation already has correct refresh logic and a clear white QR field. Retain the backend/timer behavior but adopt the stronger visual composition.

Do not implement refresh as a timer tied to view rendering. The current dedicated task approach is directionally correct.

10. Map and Nearby

This is the largest root-screen gap between current native code and the target.

10.1 Current implementation

ClickMapView currently contains:

MapKit map;

user annotation;

beacon annotations;

recenter control;

permanent bottom nearbyPanel;

horizontal beacon chips inside that card;

selected beacon presented in a separate medium/large sheet.

That is a functional prototype, not the intended final map experience.

10.2 Target composition

The artifact and rebuild specification agree on:

native MapKit map
top navigation/control chrome
layer/filter controls
recenter/create controls
stable connection/hub/beacon annotations
Nearby lip
expandable Nearby discovery sheet

The compact bottom object should be a lip, not a large always-visible information card.

10.3 Nearby sheet

The production state model should be explicit:

collapsed lip
medium discovery
large discovery

The sheet must:

track a vertical drag continuously;

settle based on position/velocity;

allow the internal list to scroll when expanded;

collapse on downward drag when the list is already at its top;

not steal a map pan that begins outside the sheet;

retain a stable search field size while typing;

keep map and list filtering coherent.

Prefer platform detents and system gesture arbitration. Only build a custom interactive container if native sheet behavior cannot preserve the required map/lip interaction.

10.4 One MapFeatureModel

The current view locally owns camera, userLocation, beacons, selectedBeacon, loading and errors.

The spec calls for a broader MapFeatureModel covering:

viewport;

location;

layers;

Ghost Mode;

connection pins;

beacons/events;

hubs;

discovery sections;

selection;

focus intents.

That model is justified because map and Nearby are two views of the same state. Do not let the map and sheet independently fetch and reconcile the same objects.

10.5 Beacon taxonomy mismatch

Current NativeMapBeacon.kindLabel includes values such as:

recreation;

hobby;

transit;

hazard_utility.

The rebuild specification says the canonical current beacon kinds are:

soundtrack
sos
hazard
utility
study
social_vibe
event
other

This should be reconciled with the actual backend before the visual pass hardens category-specific icons and colors.

10.6 Ghost Mode

The prototype gives Ghost Mode a first-class map presence. That is appropriate, but it cannot be a cosmetic grayscale toggle.

Production behavior must update the actual session privacy/sync semantics defined in the native spec. The visual state should be a reflection of product privacy state, never a substitute for it.

10.7 Pin language

The artifact usefully differentiates:

people;

event/beacon visuals;

live/status indicators.

Implement these through MapKit annotations with stable IDs and shared avatar/event visual components. Do not copy the fake SVG map.

11. Me / Settings

The prototype is much closer to the rebuild spec's concept of the fifth tab than the current native screen.

11.1 Current mismatch

The fifth tab is labeled Me in the tab bar, but its root view is SettingsView with:

.navigationTitle("Settings")
.navigationBarTitleDisplayMode(.large)

The spec says the fifth root is an identity/account home, with Settings as subpages.

This should change.

11.2 Root composition

Use the prototype's general direction:

large avatar;

display name;

account/relationship count context;

current availability;

quick QR/edit controls;

grouped account/preferences regions.

The root should feel like “this is me on Click,” not “here is a settings table.”

The prototype's Core horizontal strip is visually successful, but it is not a mandatory requirement in the rebuild spec. Keep it only if it has clear product value and real data; do not make it a P0 dependency.

11.3 Group settings regions

The September refinement says Settings should scan as grouped preference regions rather than one continuous divider list.

Current SettingsView places Availability, Alerts, Privacy & data, Interests, Personality, Saved events, and Appearance inside one continuous VStack separated by dividers.

Split them into meaningful grouped regions, for example:

Availability / social
Alerts
Privacy & data
Profile customization
Saved content
Appearance / web
Account

Do not create a card around every row. One grouped surface per semantic region is enough.

11.4 Functional gaps visible in current code

Current Settings implementation is materially behind the rebuild spec.

Examples:

Privacy currently exposes barometric context and a permissions link, but not the complete Ghost Mode / Location snap / Memory Map / Business insights model.

Alerts does not expose all current valid categories required by the spec.

Interests and personality are displayed as tags but the shown implementation is not a complete editor with persistence/rollback.

account deletion is not present in the reviewed root implementation despite being a release requirement in the spec.

the root remains “Settings,” not “Me.”

These should be resolved while adopting the new visual grouping rather than polished as-is.

12. Peer and group profiles

12.1 Identity

Current ProfileView uses a relatively compact left-aligned 82 pt avatar/header.

The prototype uses a centered ~112 pt avatar/group identity and a 28 pt Manrope name. This is more appropriate to the refinement requirement that identity dominate actions.

Adopt the stronger identity-first composition.

12.2 Actions: do not copy the prototype literally

This is one of the artifact's weaker choices.

The prototype presents four equal 74 pt action tiles. The September refinement explicitly says secondary actions should not visually equal the primary Message action.

Recommended reconciliation:

preserve the centered identity;

keep one clear primary Message affordance;

put Nudge, Drops/media, and other secondary actions in quieter compact controls or a secondary action row;

move destructive/safety actions into native menus/profile management.

12.3 Common ground

The prototype's one grouped region containing Common Ground and Personality is better than many separate cards. Use low-emphasis chips and avoid strong purple outlines.

12.4 Tabs

The prototype uses compact horizontally scrolling chips. Current native uses a four-column icon/text tab bar with an underline.

Either can satisfy the spec, but the chip approach scales better when the full parity set includes Timeline, Media, Links, Files, Beacons, and Members/group content.

Use a restrained active state: low tint + accent foreground, not saturated fill.

12.5 Timeline / journal

The current implementation places a large multiline note editor inside another bordered card. That consumes too much visual attention.

The prototype's “Add journal note” row followed by a chronological list is cleaner. Tapping the row can open a dedicated native sheet/editor.

Timeline items should read as shared history, not telemetry cards.

12.6 Group profile

AppRoute.groupProfile exists, but current Clicks destination handling does not yet expose a production group profile in the reviewed code.

The prototype includes:

group identity;

members;

add member;

member roles;

removal;

encryption-key rotation explanation.

This is a good visual/product reference, but successful membership mutation is not complete until backend membership and E2EE epoch state are both reconciled.

13. Chat

The current native chat architecture has several good foundations. The visual layer is still behind the prototype/refinement target.

13.1 Preserve current native architecture

Good existing choices:

one ConversationModel;

native ScrollView/lazy timeline;

stable message IDs;

composer via safe-area inset;

native toolbar principal;

tab bar hidden in chat;

direction-locked swipe-to-reply;

native context menus;

operation error state that does not discard the timeline;

near-bottom tracking.

These are worth retaining.

13.2 Conversation atmosphere

Current background is simply ClickColors.background.

The September refinement specifically calls for an ambient conversation background derived from the context of the most recent real-world encounter, with a deterministic low-contrast gradient/motif and a neutral fallback.

The prototype's #0B0B0D chat surface plus subtle doodle pattern is useful as the fallback visual density reference, but it should not replace the encounter-derived background requirement.

Implementation:

ChatBackgroundDescriptor
  fallback neutral
  encounter-derived deterministic atmosphere
  curated preset
  custom user image

Render it as a stationary layer behind the timeline. It must not animate during scroll and must be available by the first stable frame.

13.3 Bubble palette

Current incoming messages:

use ClickColors.surface;

add a visible quiet-border stroke.

Current outgoing messages use ClickColors.primary.

The prototype is more refined:

incoming #232326;

no bright outline;

outgoing #4A1FA6, darker than the primary action fill;

white outgoing content;

18 pt bubble radius with tighter tail corner.

This should become the reference.

Create explicit message colors instead of reusing generic brand/surface tokens.

13.4 Bubble width and typography

The artifact uses SF/system 17/22 for message text and a max text-bubble width around 272 pt in the 390 pt reference viewport.

Do not hard-code 272 globally, but reduce the current “almost full width” feel. Use a percentage/max-layout rule that leaves visible conversation environment around text clusters.

Message text should use system typography, not Manrope.

13.5 Composer

Current composer is structurally sound but visually generic:

bordered text field;

opaque surface bar;

send button;

no complete attachment/voice affordance in this component.

The prototype provides a better density target:

translucent bottom environment;

native-feeling message field;

attachment action;

circular send;

reply/edit strip above;

keyboard transition visually attached to composer.

Keep system keyboard and safe-area behavior. Do not reproduce its fake keyboard.

13.6 Gestures

Keep the current directional intent logic for swipe-to-reply.

Acceptance is behavioral:

horizontal reply gesture cannot steal vertical scroll;

edge-back wins where appropriate;

attachment/audio sliders get their own gesture ownership;

only one threshold haptic;

failed gesture returns smoothly;

reply-state insertion does not jump the timeline.

13.7 Performance

Do not add decorative effects that reintroduce the existing KMP-era stutter.

Profile in Release on device for:

first open;

repeat open;

rapid scroll;

keyboard;

reaction;

message insertion;

back gesture;

media;

voice slider.

If SwiftUI anchoring remains unstable, isolate the timeline behind one UIKit collection implementation. Do not build app-wide gesture hacks.

14. Event and beacon details

The current native repository does not expose a complete canonical EventDetailView in the reviewed code. Event and beacon routes currently land in a generic MapRouteDetailView or a simple local beacon sheet.

That is far below the parity/visual target.

14.1 Event detail prototype

The artifact has a strong event structure:

200 pt visual;

live/category state;

30 pt title;

host identity;

one dominant RSVP/check-in state action;

neutral secondary action tiles;

date/location/attendance as one grouped information system;

About;

People here;

attendee directory;

bookmark/share/close chrome.

This aligns well with the September event refinement because only one action is strongly filled at a time.

14.2 Canonical implementation

Create one event-detail content/model feature. It may be hosted:

in a sheet from Map;

in a push/cover from Home;

from Saved Events;

from notifications.

But the event business logic and content implementation should not fork into multiple separate detail screens.

14.3 Beacon details

Non-event beacon detail should be a separate canonical presentation using the actual beacon taxonomy. Do not force event metadata/actions onto every beacon type.

15. Search

The prototype's global search is notably more complete than current native search.

It includes:

one search field;

domain filters;

grouped results;

people/event/etc. rows;

no-result state;

explicit note that encrypted message search is local.

This matches the rebuild spec's architecture.

Recommended:

GlobalSearchModel
GlobalSearchView

Root screens call the same feature.

Clicks can still have an inline local filter without creating a second global search stack.

Search must distinguish:

initial
searching
results
no results
backend error

A backend failure must not be presented as “No results.”

16. Shared components: what to actually extract

The current repository already duplicates avatar rendering in Clicks, Chat, Profile, and Settings. This should be corrected before final visual polish, because avatar inconsistency has repeatedly surfaced as a product bug.

Recommended genuinely shared primitives:

Component

Responsibility

UserAvatar

Image/fallback generation, online indicator, sizing, accessibility

GroupAvatar

Generated/custom group identity

ClickAsyncImage

caching/downsampling/error/fallback

PrimaryAction

canonical primary action metrics and state

StatusPill

small state indicator

AvailabilityChip / row

consistent intent appearance

GroupedSurface

only the neutral visual grouping shell, no information semantics

PersonRow

repeated identity list geometry

ConversationRow

inbox-specific row

EventVisual

deterministic visual rendering

ToolbarIconControl

shared hit target/icon metrics using native material

EmptyState / ErrorState / OfflineBadge

consistent states

MessageBubble

chat-specific geometry

AttachmentBubble

file/photo/video states

AudioMessageBubble

native slider/playback UI

ChatBackground

deterministic atmosphere/fallback

NearbySheet

map discovery presentation

Do not create:

a universal ClickCard;

a universal GlassView;

a custom navigation framework;

a custom animation framework;

a “one component fits all rows” abstraction.

The rebuild specification is correct to insist that reuse follow genuine semantic repetition.

17. Concrete file-level implementation plan

17.1 Click/DesignSystem/Colors.swift

Refactor first.

Changes:

neutralize dark backgrounds/surfaces;

add explicit text tertiary role;

replace purple-tinted general separators with neutral separators;

split brand/accent/action roles;

add chat-specific colors;

keep status colors semantic;

reduce generated-content palette bleed into chrome.

Do not remove light-mode support. The dark artifact is the current visual reference, but semantic tokens must remain valid in light mode.

17.2 Click/DesignSystem/Typography.swift

Refactor from “Manrope for everything” to:

Manrope brand/display roles;

system fonts for navigation, list, body, metadata, controls;

Dynamic Type relative styles retained.

Remove backward aliases where they encourage ambiguous use once call sites are migrated.

17.3 Click/DesignSystem/Spacing.swift

Replace radiusInput/radiusButton/radiusCard as the main geometry API with semantic radius/control metrics.

Add screen gutter, row min height, toolbar target, primary action min height, chip height.

Then migrate hard-coded geometry in feature files.

17.4 Click/DesignSystem/Motion.swift

Keep only non-system semantic motion.

Do not try to reproduce cubic-bezier(.32,.72,0,1) globally.

Use native push/pop, keyboard, menu and sheet transitions. Keep small selection/press/reveal animations where they do not compete with the platform.

17.5 Click/App/RootGateView.swift / MainTabShellView

Retain the architecture.

Change:

Me tab image to cached user avatar/fallback;

verify selected-tab accent tone;

ensure native tab bar remains mounted/stable;

ensure route destination coverage exists for all tab stacks;

do not recreate the tab bar after avatar updates.

17.6 Click/App/AppRouter.swift

Keep typed paths.

Audit:

group profile destination;

event destination;

beacon destination;

hub destination;

saved events;

global search presentation;

deep-link focus into Map/Detail.

Centralize destination construction enough that a valid AppRoute cannot silently fall into EmptyView.

17.7 Click/Features/Home/HomeView.swift

Structural rewrite, not full backend rewrite.

Change ordering to prototype/refinement hierarchy.

Replace:

full-width availability-management CTA;

early recap;

vertical recent list;

bordered recap style.

Introduce stable module-state rendering and explicit recap failure/empty semantics.

17.8 Click/Features/Clicks/ClicksView.swift

High-priority refinement.

Change:

add inline local search;

reduce title/subtitle redundancy;

restyle segments;

compact Remember strip;

add optional nudge slot;

upgrade conversation row states;

add native swipe/context actions;

wire group row to group chat/profile.

This screen should become the density benchmark for the rest of the app.

17.9 Click/Features/AddClick/AddClickView.swift

Change root presentation to signature-action first.

Retain the existing QR implementation logic.

Do not present unavailable capabilities as finished production functionality.

17.10 Click/Features/Map/ClickMapView.swift

This needs a deeper feature refactor.

Create MapFeatureModel.

Replace permanent nearbyPanel with lip + discovery sheet.

Integrate:

layers;

Ghost Mode;

connection pins;

hubs;

beacons/events;

selection/focus;

create beacon.

Keep MapKit.

17.11 Click/Features/Profile/SettingsView.swift

Reframe root from Settings to Me.

Keep preferences as pushed subpages.

Group semantic settings regions.

Add missing product controls and account deletion path required by the spec.

17.12 Click/Features/Profile/ProfileView.swift

Adopt centered identity-first header.

Maintain Message priority rather than equalizing all actions.

Simplify Common Ground/Personality.

Move journal authoring behind a focused action/sheet.

Expand tab parity.

17.13 Click/Features/Chat/ChatView.swift

Keep current architecture.

Add stationary ChatBackground.

Review initial scroll behavior and operation states.

Unify avatar component.

Ensure first frame already has cached/fallback background and conversation identity.

17.14 ChatComposerView.swift

Restyle, then complete attachment/voice integration.

Reduce border emphasis.

Use system typography.

Ensure the composer and keyboard remain one native layout system.

17.15 MessageBubbleView.swift

Change semantic colors/radius/typography.

Remove ordinary incoming border.

Reserve geometry for replies/reactions/media so mutation does not shift unrelated messages.

Preserve direction-locked reply behavior.

17.16 Event / beacon features

Introduce canonical feature files rather than growing ClickMapView.swift into a monolith:

Features/Event/EventDetailView.swift
Features/Event/EventDetailModel.swift
Features/Map/BeaconDetailView.swift
Features/Map/MapFeatureModel.swift
Features/Map/NearbySheetView.swift

Exact naming is flexible; ownership boundaries are not.

18. Recommended implementation sequence

The order matters because changing individual screens before the tokens would create another layer of inconsistency.

Pass A — lock the reference

Add a short design-reference document to the repository containing:

prototype source/archive identity;

reference screenshots;

authority rules from this audit;

“do not port HTML literally” warning;

exact visual tokens that are intentionally authoritative;

screen capture list.

Pass B — semantic primitives

Implement:

color roles;

typography split;

geometry/control metrics;

avatar/image primitives;

primary/secondary control treatment.

Do not touch every feature simultaneously yet.

Pass C — shell/chrome

Verify:

native TabView;

per-tab state;

Me avatar;

root/pushed title behavior;

stable toolbar controls;

tab hiding rules;

sheets.

Pass D — calibration roots

Implement in this order:

Clicks — establishes list density, avatar, search, filters, unread states.

Home — establishes hierarchy and mixed-module rhythm.

Me — establishes identity + grouped settings.

Add Click — establishes signature-action/quick-action pattern.

Map — establishes floating controls and sheet/lip behavior.

Pass E — high-value pushed surfaces

Then:

peer/group profile;

direct/group/hub chat;

event detail;

beacon detail;

global search;

QR/scanner/connect states;

media viewer.

Pass F — consistency sweep

Search for:

direct Color(hex:) in feature views;

direct custom Manrope body use;

arbitrary .cornerRadius / RoundedRectangle(cornerRadius:);

duplicate avatar implementations;

.overlay(...stroke...);

custom blur/material;

one-off control heights;

duplicate search;

duplicate event detail;

EmptyView() route fallthrough;

user-facing placeholder/unavailable copy.

Pass G — regression and performance

Capture the fixed visual set and test Release builds on physical hardware.

No feature is accepted solely because snapshots/unit tests pass if interaction visibly stutters.

19. Screen-specific acceptance criteria

Home

first viewport has one obvious social priority;

recap does not outrank current relationships/events;

no async module visibly pushes settled first-viewport content;

unavailable recap never appears as fake zeros;

recent people use the shared avatar pipeline;

purple is not the dominant surface color.

Clicks

first conversation row appears materially sooner;

local search filters immediately;

active/group/archive selector does not dominate;

unread/core/presence states are clear but compact;

swipe actions use native interaction;

avatar tap and row tap have distinct canonical destinations;

realtime insert/reorder does not rebuild the entire list.

Add Click

Tap to Connect reads as the primary purpose within one glance;

QR/scan remain immediately discoverable;

unavailable functions are not presented as functional;

permission state is contextual;

QR expiry is visible and correct.

Map

collapsed Nearby state reads as a lip, not a card;

upward drag is reliable;

map remains pannable outside the sheet;

map/list share state;

annotation refresh does not flash/reinsert everything;

Ghost Mode has real product semantics;

layers/filters update map and feed coherently.

Me

root title/identity is Me, not generic Settings;

avatar/name dominate;

preferences are grouped;

account deletion is discoverable;

privacy toggles reflect actual persisted/session state;

Me tab avatar updates without rebuilding tab chrome.

Profile

identity visually dominates;

Message is the primary relationship action;

timeline looks like history, not analytics;

profile tabs use a restrained active state;

one avatar algorithm everywhere.

Chat

shell/header/composer appears promptly;

neutral/encounter background exists on first stable frame;

rapid scrolling remains smooth;

keyboard transition has no second corrective jump;

message reactions/status updates do not shift unrelated rows;

incoming bubbles do not have unnecessary bright outlines;

outgoing bubble is distinct from generic CTA purple;

reply/scroll/back/media gestures do not fight.

Event

one primary state-dependent action;

date/place/host read as one information system;

chat/check-in/directions are discoverable secondary actions;

one canonical detail implementation;

map/home/saved routes resolve to it.

20. Visual regression reference set

Use one fixed device class and consistent appearance for comparison.

Minimum set:

Home — stable first viewport
Home — mid-scroll / compact title
Clicks — active conversations
Clicks — groups
1:1 chat — text/reply/reactions
1:1 chat — media/file/audio
Group chat
Event/community hub chat
Add Click root
Tap to Connect — active state
My QR
Peer profile — timeline
Peer profile — media
Group profile — members
Map — Nearby collapsed
Map — Nearby medium
Map — Nearby large
Map — Ghost Mode
Event detail
Beacon detail
Me root
Privacy settings
Interests/personality editor
Global search
Fullscreen media

For chat, include:

neutral fallback background;

at least one encounter-derived background;

media;

reply;

reaction;

voice;

failed/pending state.

21. Anti-regression rules for the implementation agents

This design pass should not be allowed to “simplify” the product by deleting hard features.

The coding agent must not:

remove working product behavior because it is inconvenient to fit visually;

alter backend/auth/E2EE semantics as part of pure visual work;

replace native navigation with a custom router animation layer;

build a custom tab bar solely to match the HTML;

create another global glass abstraction;

add full-screen animated blur;

create per-row timers;

introduce multiple global search implementations;

duplicate event detail;

duplicate avatar generation;

hard-code prototype demo categories when the backend does not provide them;

use index identity for dynamic lists;

show fake empty/zero data when a request failed;

implement Ghost Mode as a visual-only map toggle;

ship unimplemented Tap/group/hub affordances as if functional;

use arbitrary new radii/colors in individual screens;

disable system interactive back to make a custom gesture easier;

add broad withAnimation around data refreshes;

remount tab/navigation chrome because a state/icon changed.

22. Specific current-code concerns to fix while doing this pass

These are not all purely visual, but they directly affect whether the artifact can be implemented cleanly.

Design tokens are not authoritative. The token file says 8 pt buttons/inputs and 16 pt cards, while feature files hard-code many other values. Reconcile the system before further polish.

Typography is too globally branded. Manrope is applied to ordinary UI text, reducing native texture.

Dark palette is too tinted. Neutralize generic backgrounds/separators.

Avatar rendering is duplicated. Clicks, Chat, Profile and Settings all implement their own fallback/image code.

Home hierarchy is stale. Recap appears too early and the monolithic snapshot/loading model does not match the current spec.

Home can fabricate zero recap state. Remove the .init() fallback for unavailable recap.

Clicks local structure is too tall before the list.

Clicks lacks complete row interaction/state parity in the reviewed view.

Global search is duplicated between Home and Clicks rather than centralized.

Map Nearby is still a permanent panel, not the required lip/sheet.

Map model is incomplete for connections, hubs, Ghost Mode and unified discovery.

Beacon kinds should be reconciled with the canonical backend taxonomy.

Me is still implemented as Settings, contrary to the native spec.

Settings feature parity is incomplete, including privacy/notification/account controls.

Group-profile routing exists but destination coverage is incomplete.

Event routing uses a generic map detail, not canonical event detail.

Chat visual atmosphere is absent.

Chat bubbles still reuse generic brand/surface roles instead of conversation-specific semantic roles.

Profile identity is too visually modest relative to the new direction.

Profile journal authoring is too card-heavy compared with the desired history-first presentation.

23. What I would preserve almost exactly from the artifact

Visually, these are the highest-confidence reference decisions:

pure black dark root;

neutral #1C1C1E grouped surfaces;

subtle tertiary grays;

separated purple fill/foreground/tint roles;

Manrope only where Click needs a recognizable editorial/product voice;

SF/system for most controls and dense information;

44 pt top controls;

50 pt primary CTA scale;

42 pt search scale;

54 pt grouped-row baseline;

26 pt major grouped surfaces;

16-ish root gutters;

compact muted segmented controls;

Home's social-first ordering;

Clicks inline search and fast path to conversation rows;

horizontal people strips;

Add Click's centered signature interaction;

Nearby lip;

floating map controls;

identity-first Me;

identity-first peer profile;

low-contrast chat environment;

darker outgoing message purple;

one-primary-action event hierarchy.

24. What I would deliberately change from the artifact

Even though the artifact is excellent, production should improve these points:

Native tab bar instead of custom floating DOM tab bar

Keep the appearance as a calibration target, not the implementation.

Native push/pop instead of the custom .slot and 22 px edge-zone system

The prototype is demonstrating spatial intent.

Profile primary-action hierarchy

The equal four-action tile grid should be revised so Message remains the obvious primary relationship action.

Chat background

The generic doodle is a good fallback, but the September encounter-context atmosphere remains the richer Click-specific direction.

Accessibility sizing

Fixed 44/50/54 heights become minimums where Dynamic Type needs expansion.

Sheet implementation

Prefer native detents/system gesture ownership instead of reproducing the CSS translation math.

Map visual

Use MapKit and real coordinates, not the prototype's handcrafted visual map.

Product-state fidelity

Only show categories/actions supported by real data and current backend semantics.

25. Final assessment

The artifact succeeds because it does something the previous iterations did not: it defines a single coherent UI grammar.

The current native rewrite already has most of the architectural prerequisites to implement that grammar correctly. It should therefore not be treated as another redesign from scratch.

The core strategy should be:

KEEP
native SwiftUI architecture
typed routing
per-tab navigation stacks
native gestures/keyboard/sheets/map
current backend/session/E2EE models

REPLACE / RECONCILE
visual tokens
typography roles
surface hierarchy
screen composition
duplicate avatars/search/detail flows
root Me interpretation
Map/Nearby presentation

USE THE ARTIFACT AS REFERENCE FOR
proportion
density
hierarchy
visual tone
interaction intent
screen-to-screen consistency

DO NOT PORT
HTML layout
absolute geometry
JS routing
fake keyboard
fake map
custom push physics
global CSS blur mechanics
demo data

If this hierarchy is followed, the artifact can materially accelerate the native redesign rather than becoming another source of drift.

The most important implementation principle is that the prototype should constrain agent discretion. Codex/Claude should not be asked to “make it more premium” screen by screen. It should be given explicit visual roles, canonical components, screen hierarchy, and acceptance captures from this reference. The remaining agent discretion should mostly concern correct native implementation—not aesthetic invention.

That is the path most likely to produce a Click iOS client that feels internally consistent, native, and commercially finished without another cycle of broad regressions.