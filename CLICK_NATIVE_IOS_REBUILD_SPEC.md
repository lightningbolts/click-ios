# Click Native iOS Rebuild Specification

**Repository:** `click-ios`  
**Product:** Click Platforms / Click  
**Purpose:** Replace the existing Kotlin Multiplatform iOS presentation/client implementation with a clean native Swift iOS application while preserving the existing Click backend, user accounts, App Store identity, data model, encryption compatibility, deep links, App Clip, push behavior, and product semantics.  
**Status:** Implementation specification  
**Primary implementation target:** Native iOS, Swift + SwiftUI, with UIKit / native Apple frameworks only where SwiftUI does not expose the required platform behavior cleanly.  
**Existing Android client:** Remains in `click`; this project does not rewrite Android.  
**Existing web/backend:** Remains in `click-web` / Supabase and is the authoritative server/business-rule layer.  
**New repository:** `lightningbolts/click-ios`  
**Baseline reviewed:** `click`, `click-web`, `click-split-app`, and current mobile regression/UI documentation as of September 2026.

---

# 0. Executive directive

This is **not** a line-by-line port of the current KMP iOS code. It is a clean native client replacement.

The existing `click` repository serves as the **behavioral and compatibility reference**: it tells us what users can do today, which edge cases already exist, what data must remain readable, and which backend flows are already integrated.

The `click-web` repository and the Supabase schema/functions it owns serve as the **authoritative backend contract**. Server-authoritative rules must not be reimplemented independently in Swift when a server API, RPC, RLS policy, Edge Function, or shared backend rule already exists.

The `click-split-app` repository serves as a **native architecture reference**, not as a codebase to merge with. Its useful patterns include SwiftUI-first rendering, `Observation`, a small dependency environment, feature-local observable state, typed routing, Swift concurrency, native sheets/navigation, and thin repository layers. Do not create a shared Swift package between Click Split and Click merely because similar code exists. Duplication is preferable to an incorrect shared abstraction during the initial rebuild.

The new client must feel like a high-quality iOS application because it **is** an iOS application. Native navigation, native scrolling, native gestures, native keyboard behavior, native sheets, native presentation transitions, native haptics, native accessibility, native menus, native system material, native photo/camera/file pickers, and native lifecycle APIs are the default. Custom emulation of system interaction should be treated as an exception requiring justification.

The replacement must be releasable as an **update to the existing App Store product**, not as a second product.
