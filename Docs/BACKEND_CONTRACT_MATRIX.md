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
