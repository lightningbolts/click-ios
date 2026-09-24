# In-person connection test matrix (round 4 §8.4)

None of this can be verified in the simulator.
- Record each run in `PARITY_LEDGER.md` (F70–F75) only after it has actually been done on devices.
- Launch the iOS build with `-connection-log` (DEBUG) to get the on-screen request/response log (Copy button). Compare it with an Android capture of the same tap.

## Pairs
- iOS ↔ iOS
- iOS ↔ Android (both directions: iOS as BLE central talking to an Android peripheral, and the reverse)
- Three-device Multi-Tap, mixed platforms

## Scenarios (run for every pair)
1. New connection
2. Reconnect (same pair, later; ideally a different place)
3. Reconnect again within 50 m and the same 12-hour UTC block → expect "Extended Hangout"
4. Rapid second tap → rate-limit copy "You recently crossed paths…"
5. One phone offline, then back online (the offline queue replays within 48 h for the same user only)
6. Bluetooth off
7. Microphone denied
8. Location off
9. Location Snap on and off
10. At a live event (attach) versus not at an event
11. QR both directions
12. Expired QR → "This QR code has expired…"
13. Already-used QR → "This QR code was already used…"
14. A non-Click QR is rejected locally with no request

## Check each time
- [ ] Exactly one connection, one inbox row and one map pin
- [ ] Timeline entry correct: time, place, reconnect count
- [ ] Tags saved on `connection_encounters.context_tags`, visible on both phones
- [ ] The reveal appears only after the server confirmed
- [ ] Telemetry event received server-side
- [ ] iOS tokens never contain adjacent repeated digits or a leading 0; the Android side decodes them

## Known cross-platform risk (file against the KMP app)
**Title:** KMP ultrasonic decoder: repeated digits merge, leading 0 merges with the chirp, and the Goertzel recurrence is wrong.

`UltrasonicTokenCodec.kt` has three problems:
- **Repeated digits merge (lines 126–133):** the 90 ms window with a ~30 ms step never lets the 22 ms inter-tone gap fall below threshold, so repeated digits merge ("1122" is heard as "12").
- **Leading 0 (line 148):** digit 0 is the same frequency as the 18.5 kHz carrier, so a leading 0 merges with the chirp. `takeLast(4)` masks this.
- **Goertzel recurrence (lines 34–35):** `s = x + coeff*s - s2; s2 = s` drops the previous `s1`. The recurrence should be `s0 = x + coeff*s1 - s2; s2 = s1; s1 = s0`.

Until this is fixed, iOS emits only tokens without adjacent repeats or a leading 0 (`ProximityCodec.randomToken`).
