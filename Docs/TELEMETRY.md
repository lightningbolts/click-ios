# Telemetry catalog (iOS)

Spec §71. Everything here is best-effort: it never blocks the UI, and it never carries user IDs, message content, tokens or raw coordinates. Events are queued in `TelemetryQueue` (persisted in `UserDefaults`, capped at 200, dropped after 7 days). The queue is flushed serially, at most 30 per flush, when the app becomes active or goes to the background. 4xx responses (other than 429) are dropped; transient failures stay queued. Sign-out clears the queue.

## Connection-flow funnel — `POST /api/telemetry/connection-flow`

Source: `ConnectionFlowTelemetry` (event names identical to KMP `ConnectionFlowTelemetry.kt`).

Payload: `{event, peer_count?, is_group?, is_reconnect?, selected_count?, candidate_count?, reason?}`.
- `reason` is a short machine code (`timeout`, `server_503`, `no_peers`, `dismissed`, …) cut to 128 characters.
- UUIDs and decimal coordinates are scrubbed from `reason` before it is queued.

| Event | Sent | iOS emitter |
|---|---|---|
| `proximity_handshake_started` | always | `TapConnectModel.run` (sensing begins) |
| `proximity_handshake_awaiting_selection` | always | `handle(.awaitingSelection)` |
| `proximity_handshake_failed` | always | bind error, no peers, ignored payload, confirm failure |
| `proximity_host_selection_abandoned` | always | `cancel()` while choosing people (`reason: dismissed`) |
| `proximity_reconnect_rate_limited` | always | matched reconnect the server declined to log |
| `proximity_recovery_poll_timeout` | always | recovery polling exhausted |
| `proximity_recovery_incomplete` | always | not emitted (no client path in KMP either) |
| `verified_clique_from_proximity_blocked` | always | not emitted (no client path in KMP either) |
| `proximity_at_event_attached` / `_skipped` | server | emitted server-side by `emitProximityAtEventOutcome` |
| `proximity_handshake_matched` | 10% | matched |
| `proximity_handshake_pending` | 10% | 202 pending |
| `proximity_handshake_offline_queued` | 10% | offline queue |
| `proximity_host_selection_confirmed` | 10% | confirm selection |
| `proximity_reconnect_encounter_saved` | 10% | matched reconnect |
| `proximity_recovery_poll_success` | 10% | recovery resolved |
| `verified_clique_from_proximity_created` | 10% | confirmed group |

## Map friction — `POST /api/telemetry/friction`

Source: `FrictionTelemetry` (rules identical to KMP `TelemetryBatcher.kt`).

Payload: `{event: "map_friction_anomaly", duration_sec, pan_count, action_taken: null, hexbin_id}`.
- A session starts when the Map appears or returns to the foreground.
- It ends when the Map disappears or the app goes to the background.
- It is queued only when it lasted at least 30 s and had at least one pan.
- `hexbin_id` is `AnonymizedHexbin.cell`: `floor(coord × 200)` buckets, then FNV-1a 64, then signed hex, first 12 chars. It is byte-identical to KMP `AnonymizedHexbin` (unit-tested against an independently computed value).
- The "grass nudge" shows after 240 s when the user panned within the last 45 s and took no meaningful action. It can be dismissed.

## Not implemented
- `/api/insights/widget-vibe`: no iOS widget ships.
