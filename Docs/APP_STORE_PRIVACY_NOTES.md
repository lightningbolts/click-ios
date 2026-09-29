# App Store privacy label and reviewer notes — post-9/29 features

Everything below ships dark behind server flags (`/api/me/features`). Update App Store Connect **before** the first build that can enable any of these reaches review, and keep the reviewer notes current.

## Privacy label ("App Privacy") changes

| Data type | Feature (flag) | Linked to user | Used for | Notes |
|---|---|---|---|---|
| Photos or Videos | Event drops (`event_drops`), shared drops (`shared_drops`) | Yes | App Functionality | Photos the user chooses to post. Stored on Click's servers (not end-to-end encrypted); visible only to the audience the server allows; the poster can delete anytime; deleted with the account. Chat Click Drops stay end-to-end encrypted. |
| Coarse Location | Reconnect near here (`reconnect_nearby`) | Yes (per request) | App Functionality | ~100 m position sent on app open, only when location is already allowed; used to find a past meeting place; **not stored**. |
| Precise Location | Alert confirmations (`alert_confirmations`), Listening now (`soundtrack_presence`) | Yes (per request) | App Functionality | Checked against the pin's radius and **not stored**. Precise location is already declared for Tap to Connect / check-in. |
| Product Interaction | Pilot analytics (`pilot_analytics`) | Yes | Analytics | Install, daily app open, recap opened, and server-side counts (drops posted, nudges shown/acted). No content, other people's IDs or coordinates. Not used for tracking or ads. |

No new permission prompts or purpose strings: the camera (`NSCameraUsageDescription`) and when-in-use location (`NSLocationWhenInUseUsageDescription`) strings already cover these uses. **No background location or new background modes were added**; reconnection pushes (spec 8b) are not built.

## Reviewer notes (add when a flag is enabled for review)

- **Click Drops develop:** photos in chat stay pixelated until they develop; after the timer, tap to develop. Originals are held on the server until then.
- **Event drops & recap:** only people checked in to an event can post; the recap unlocks at 10:00 the next morning in the event's time zone. Provide a demo event with check-in available and drops already revealed.
- **Shared drops:** a photo to all or core connections that develops after 24 hours; the share sheet states it is not end-to-end encrypted.
- **Alert confirmations / Listening now:** require being near the pin; the reviewer account needs a demo pin near the review location or a flag cohort without these features.
- **Reconnect near here:** appears only when location is already allowed and a past meeting place matches; it never shows where anyone is now.
- **Reporting:** beacons and all drop kinds have a quiet Report action; blocking hides a person's drops everywhere.
