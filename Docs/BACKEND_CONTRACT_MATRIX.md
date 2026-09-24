# Backend Contract Matrix

Authoritative ledger of backend HTTP endpoints, authorization requirements, and client mappings between `click-ios` and `click-web` / Supabase.

| Route | Method | Auth | Domain | Purpose |
|---|---|---|---|---|
| `/api/ping` | GET | None/Optional | Diagnostics | API health check |
| `/api/users/{id}/profile` | GET | Bearer JWT | Profile | Full user profile |
| `/api/users/{id}/public-profile` | GET | Bearer JWT | Profile | Public summary profile |
| `/api/user/preferences` | GET/PATCH | Bearer JWT | Settings | Notification & privacy preferences |
| `/api/user/push-tokens` | POST | Bearer JWT | Push | APNs device token registration |
| `/api/connections` | GET/POST | Bearer JWT | Connections | Connection list & manual save |
| `/api/connections/proximity` | POST | Bearer JWT | Connect | Tri-Factor proximity handshake submission |
| `/api/connections/proximity/confirm` | POST | Bearer JWT | Connect | Multi-Tap host peer confirmation |
| `/api/qr` | GET/POST | Bearer JWT | QR | Generate 90-second QR token / Redeem QR |
| `/api/chat/messages` | GET/POST | Bearer JWT | Chat | Fetch & send encrypted messages |
| `/api/chat/devices` | GET/POST | Bearer JWT | E2EE v2 | Device X25519 identity registration |
| `/api/chat/epochs` | GET/POST | Bearer JWT | E2EE v2 | Epoch key metadata and wrapped keys |
| `/api/beacons` | GET/POST | Bearer JWT | Map/Events | Beacon list and creation |
| `/api/beacons/{id}/rsvp` | POST/DELETE | Bearer JWT | Events | Event RSVP |
| `/api/beacons/{id}/check-in` | POST | Bearer JWT | Events | Geofence attendance check-in |
| `/api/beacons/{id}/event-chat` | GET | Bearer JWT | Events | Canonical event-chat resolver |
| `/api/hub/{id}` | GET | Bearer JWT | Hubs | Community hub detail & access check |
| `/api/beacons` | GET `?lat&lon&radius_meters` | Bearer JWT | Map/Home | Visible active beacons near a point (`{ beacons: [...] }`); `beacon_type` stored values (`recreation`, `hobby`, legacy `hazard_utility`) are mapped to canonical mobile kinds client-side |
| `/api/hub/nearby` | GET `?lat&lon&radius_meters` | Bearer JWT | Hubs | Active hubs near a point (`{ hubs: [...] }`) |
| `/api/me/event-bookmarks` | GET `?limit` | Bearer JWT | Events | Saved events, denormalized (`{ bookmarks, next_cursor }`); deleted beacons return `title: "Unavailable event"` and `created_at: null` |
| `/api/me/recap` | GET `?window=day\|week` | Bearer JWT | Home | `{ recap: {...counts} }`; client treats missing `recap` or any error as failure (never zeros) |
| `/api/me/nudges` | GET | Bearer JWT | Home/Inbox | Undismissed nudges (`reconnect_lull`, `shared_upcoming_event`) with server copy |
| `/api/me/nudges/{id}/dismiss`, `/acted` | POST | Bearer JWT | Home/Inbox | Resolve a nudge; client prunes its cache on success |
| `/api/user/availability-intents` | GET / POST `{intent_tag≤25, durationMs, timeframe}` / DELETE `?id` | Bearer JWT | Availability | Active intents; server owns expiry |
| `/api/users/{id}/profile` | PATCH `{first_name,last_name,tags,personality_tags}` | Bearer JWT | Profile | Self-only; `tags` upserts `user_interests` |
| `/api/user/availability` | PATCH `{is_free_this_week}` | Bearer JWT | Availability | Returns saved `availability` row; "Free currently" is read from `GET /api/users/{id}/profile` → `availability` |
| `/api/user/preferences` | PATCH (one or more `*_push_enabled`) | Bearer JWT | Settings | Returns `{ ok, ...fullRow }`; there is **no GET** — reads use RLS PostgREST `notification_preferences?user_id=eq.{id}` (KMP contract); absent row = server defaults (true) |
| `/rest/v1/users?id=eq.{id}` | GET / PATCH `location_*_enabled` | Bearer JWT + anon key (RLS) | Privacy | Existing KMP direct read/write of the caller's own row; native requests `Prefer: return=representation` and treats zero rows as failure |
| `/api/user/ghost-mode` | PATCH `{enabled}` | Bearer JWT | Privacy | Persists `users.ghost_mode` (event mutual-attendee privacy); native sets it with the session toggle and resets it once per launch |
| `/api/user/delete` | DELETE | **Web cookie session only** | Account | Not callable with the native bearer token; native opens `/?tab=settings` on the web |
| `/api/connections/proximity` | POST `{my_token, tokens, heard_tokens, detected_devices, latitude?, longitude?, timezone_offset_minutes, client_context_first, simulator_mock?}` | Bearer JWT | Connect | 200 match (`matches`, `connection_id`, `is_new_connection`, `is_group`, `group_clique_candidate`) · 200 `awaiting_selection` + `pending_handshake_id` · 200 `ignored_empty_payload` · 202 `pending_match` · 503 with `pending_handshake_id` (recover via GET) |
| `/api/connections/proximity` | GET `?pending_handshake_id` | Bearer JWT | Connect | Pending-tap recovery: 200 match or 202 still pending |
| `/api/connections/proximity/confirm` | POST `{pending_handshake_id, selected_member_ids(≤11), context_tags?}` | Bearer JWT | Connect | Host selection for first-time 3+ taps; creates the verified group |
| `/api/qr` | GET | Bearer JWT | QR | `{ data: { qrPayload, expiresAt(ms) } }` — 90 s single-use token |
| `/api/hub/messages` | GET `?hubId&limit≤120` | Bearer JWT | Hub chat | `{messages, reactions, participant_ids, sender_profiles_visible, occupant_count, channel}`; 403 `NOT_A_PARTICIPANT`/`EVENT_HUB_ACCESS_DENIED`, 410 `HUB_EXPIRED` |
| `/api/hub/messages` | POST `{hub_id, body, message_type, metadata, user_lat?, user_long?}` | Bearer JWT | Hub chat | 201 `{message}`; 400 `OUT_OF_BOUNDS` / coordinates required (standalone hubs); v2 body required once the hub is upgraded |
| `/api/hub/messages/{id}` | PATCH `{hubId, body, metadata, userLat?, userLong?}` · DELETE `{hubId, userLat?, userLong?}` | Bearer JWT | Hub chat | Edit / delete own hub message |
| `/api/hub/reactions` | POST/DELETE `{hubId, messageId, reactionType, userLat?, userLong?}` | Bearer JWT | Hub chat | Toggle reaction |
| `/api/hub/devices` · `/api/hub/epochs` | GET `?hub_id` · GET `?hub_id&device_id` / POST `{hub_id, epoch, sender_device_id, membership_fingerprint, envelopes}` | Bearer JWT | Hub E2EE v2 | Hub envelopes bind to the hub ID as `chatId` |
| `/api/hub/{id}` | GET · PATCH `{name?, category?}` · DELETE | Bearer JWT | Hub | Detail (participant-gated); owner edit/delete |
| `/api/hub/join` | POST `{hub_id}` | Bearer JWT | Hub | Event hubs (RSVP/check-in/host); standalone hubs answer "coordinates required" |
| `/functions/v1/verify-hub-proximity` | POST `{hub_id, user_lat, user_long}` | Bearer JWT + apikey | Hub | Standalone-hub geofence join (KMP `HubConnectionManager`) |
| `/api/hub/{id}/participants/me` | DELETE | Bearer JWT | Hub | Leave (event hub membership is server-managed) |
| `/api/beacons/{id}/event-chat` | GET | Bearer JWT | Event chat | 200 `{event_id, hub_id, title, creator_id}` · 403 RSVP required · 404 unavailable · 409 not ready · 410 ended |
| `rpc/create_verified_clique` | POST `{target_user_ids, encrypted_keys, initial_group_name}` | Bearer JWT + apikey | Groups | Returns group UUID; each key row sealed with the member↔wrap-peer pairwise v1 key |
| `/api/chat/media` | POST `{chat_id, mime_type, file_b64, e2ee_v2_envelope?, media_ciphertext_sha256?, epoch?, sender_device_id?, client_message_id?}` | Bearer JWT | Chat media | 201 `{url, path, ttl_seconds}`; ≤25 MiB; image/audio MIME allow-list; v2 authorization required once the chat is upgraded |
| `/api/chat/attachments` | POST `{chat_id, mime_type, file_name, file_b64, e2ee_v2_*?}` | Bearer JWT | Chat files | 201 `{path, url}`; ≤2 MiB plaintext; file MIME allow-list |
| `/api/chat/attachments/sign` | POST `{path}` | Bearer JWT | Chat media | `{url, ttl_seconds}` (10 min) for `chatId/userId/...` paths |
| `/api/beacons/{id}/rsvp` | GET · POST `{source, platform}` · DELETE | Bearer JWT | Events | `{current_user_signed_up, request_status, rsvp_count}`; POST → going or `{request_status: pending|waitlisted}`; 403 invite-only/closed, 409 full |
| `/api/beacons/{id}/engagement` | GET | Bearer JWT | Events | `{bookmarked, checked_in, check_in_count, hub_id}` (hub_id not trusted for chat) |
| `/api/beacons/{id}/bookmark` | PUT `{bookmarked}` | Bearer JWT | Events | `{ok, bookmarked}` |
| `/api/beacons/{id}/check-in` | POST `{latitude, longitude, accuracy_meters, source, platform}` · DELETE | Bearer JWT | Events | 400 location required · 403 `OUT_OF_BOUNDS` · 409 not live ("Check-in opens when the event starts") |
| `/api/beacons/{id}/attendees/directory` | GET | Bearer JWT | Events | `{attendees[{user_id, name, avatar_url, shared_interests, relationship, mutual_via, mutual_connection_count}], mutuals_section_unlocked}` |
| `/api/beacons/{id}` | DELETE | Bearer JWT | Beacons | Creator only |
| `/api/chat/search` | GET `?q` (≥2 chars) | Bearer JWT | Search | `{hits[{messageId, chatId, connectionId, chatName, snippet, timestamp, isHub, hubId?}]}` — plaintext bodies only |
