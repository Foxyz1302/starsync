# ROADMAP — sync_relay_project (canonical phase tracker)

This is the durable source of truth for phases. Chat is ephemeral;
this file + `HANDOFF.md` (root) + `PROTOCOL.md` / `ARCHITECTURE.md`
carry state across sessions. Update this file when a phase changes
state. Proto bumps still require PROTOCOL.md same-commit.

Model: direct-serve (host opens ports, clients open nothing). The
brief's old WSS host-upload tunnel is obsolete unless a VPS tier
needs remote-host upload. Server = Relic, client WS =
web_socket_channel. Protocol still v4.

## Status legend

- DONE: exit criteria met, tests green at the time.
- PARTIAL: shipped + tested, exits still open.
- TODO: not started or explicitly deferred.

## Phase 0 — Scaffold (DONE)

Monorepo, path deps, CI (`dart analyze` + `dart test` on core/server),
logging/config/errors, Flutter-free enforcement tests, relay binary
binds/logs/exits, stub ARCHITECTURE.md.

## Phase 1 — mpv HTTP contract (DONE)

Relic `resolveMediaRequest` + `mountMediaRoute`, full Range table
(200 / 206×3 shapes / 416 / 401 / 403 / 410 / 503), byte-exact tests,
real mpv traces in `mpv-http-contract.md`, `tool/range_logger.dart`
+ `tool/shaper.dart` (KB/s cap, latency, --kill-after).

## Phase 2 — Sessions + media endpoint (DONE)

Secret → 128-bit token, 401/403/410 gates, kick kills WS+media,
byte counters, `tool/fake_viewer.dart` ALL PASS live. Proto v2→v3
for `kicked`/`kick`. Media: local-file relay SHIPPED
(`FileMediaSource` + token-gated Range route); links path SHIPPED
(server distributes shared URL, viewers stream direct);
`HttpSource` (server-side URL fetch) DEFERRED to Phase 8; WSS
upload tunnel NOT BUILT (spec reserved in ARCHITECTURE.md).

## Phase 3 — Sync engine + readiness (DONE)

`RoomEngine` (injectable clock): server-owned clock, reports never
move it, stale-eventId guard, free seeks, PLAYING/HELD gate, quorum
(in-set≥2 unless ≤1 fresh), swap reset, force with actor feed.
22+ engine tests, `tool/e2e_check.dart` 15/15 sim. Syncplay audit
done (conscious deviations documented in HANDOFF §2). Proto v4.
Follow-ups landed: NaN guards, name/chat caps, stale vs leave feed,
1 Hz feed flush, silent-drop (15 s stale / 30 s drop + close).

## Phase 4 — Desktop app (PARTIAL)

Shipped: SyncClient framing, RoomDiff (eventId diff, 0.95× latch),
media_kit wiring, Space=ready, avatars, toasts+sheet, health display,
reconnect loop. Counts at last green: core 42, server 40, desktop 17.
Late 09-12 session: internet test PASSED (WAN, port 6969, 2-client);
server logging wired into app (`initLogging` in `main.dart` + hello
join/reject logs in `room_hub.dart`); Cancel aborts a pending
connect (`SyncClient.disconnect` completes the welcome future);
first-join failure shows the dialog and stops (auto-reconnect only
after an established session drops).
Open exits (manual, user-driven): bisect flags REMOVED 09-12;
2-client LAN soak + 1.4 GB real-file test user-reports-done 09-12
(details pending). Still open: cache-exhaustion long outage.

## Phase 5 — Resilience (PARTIAL)

Shipped: isClosed sweep, onError forget, stop() closes sockets,
silence-timeout + reconnect loop. Never run: shaper chaos suite
(host drop 5 s / 30 s, viewer stall, 20-seek storm), OOM / stuck-room
/ drift-recovery assertions, CI wiring.

## Phase 6 — Identity & social (PARTIAL)

Shipped: names (32 cap), avatars (256 KiB cap, 128 px PNG picker, transparency kept), kick nudge
+ reason, feed attribution. Open: real chat pane/history (schema
only), sounds swap-in (wiring + NoopSfxService ready; pick
flutter_soloud or equivalent, Kenney/ObsydianX/akx sources in
HANDOFF §7).

## Phase 7 — Deployment & updates (TODO, deferred)

Thin `bin/server.dart` compiles; systemd unit exists. Missing:
Windows zip, Linux tar/AppDir, TLS/Caddy doc, update manifest +
verifier. Needs explicit user go + code-signing decision.

## Phase 8 — Optional quality (TODO, deferred)

Playlist (`queue-add`/`queue-skip`, shape reserved in PROTOCOL.md),
sidecar subtitles, local-file fallback (viewer plays matching
size+duration file locally, still synced — saves host uplink),
`HttpSource` (host pastes a direct-stream URL, server fetches +
re-serves — makes Jellyfin usable through the whitelist today, no
native integration). No code until approved.

## Deferred backlog (needs explicit approval)

Jellyfin native, P2P/WebRTC, multi-session, transcode, Android.
