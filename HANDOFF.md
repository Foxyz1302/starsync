# HANDOFF — sync_relay_project (watch-together app)

Date: 2026-09-12. Phases 0–4 + presence hardening + UI redesigns done,
all green (core 42, server 40, desktop 17). Black screen (§8)
DIAGNOSED + FIXED (avatar-texture teardown race; Visibility keep-
mounted). Bisect flags (legacy/minimal/nosheet) still in app.dart —
remove once stable. Prior chat may be unreliable; this file plus
`docs/` is the full state.

## 1. What this is

Private watch-together desktop app (Windows + Linux). Host serves a file
or shared link from their own machine; 4–8 friends watch in sync.
One binary, three modes: Client (Join), Server+Client (Host, opens
ports, self-plays via loopback), `--headless` (server only, no window).
North star: <1.5 s drift, seeks settle ~2 s, cache rides short drops,
kick kills sync+video, no relay memory growth.

## 2. Locked architecture (do not reopen without the user)

- `packages/core`: protocol, sync engine, media abstractions. ZERO Flutter
  imports (enforced by test). `packages/server`: Relic-based room + media
  server, also zero Flutter imports. `apps/desktop`: the ONE Flutter
  binary embedding both. Direct-serve model: host opens ports, clients
  open nothing. NO host-upload tunnel (the brief's WSS chunk protocol is
  obsolete unless a VPS tier ever needs remote-host upload).
- Server HTTP+WS: **Relic ^1.2.0**. Client WS: **web_socket_channel**.
  Server lib also uses **web_socket** for event types.
- PACKAGES ARE NOT LOCKED (user decision 09-11, overrides the old brief
  list): pick on merit, no churn where the stack works. Current desktop
  additions: media_kit_video + media_kit_libs_video (required),
  file_picker (avatar/media picking), hive_ce + hive_ce_flutter
  (connect-form persistence), image (avatar shrink). signals + media_kit
  + Relic stay (load-bearing).
- Sync: heavily Syncplay-inspired + original readiness design, NOT 1:1.
  Reference clone (scratch, may be gone — re-clone shallow):
  `git clone --depth 1 https://github.com/Syncplay/syncplay.git /tmp/opencode/syncplay-ref`
  Audit already done; conscious deviations: clock never moves from
  reports (theirs follows slowest watcher), no pause-on-leave,
  force-for-all instead of operator-only setOthersReadiness, and
  QUORUM gate (09-12, user found solo-play meaningless): HELD→PLAYING
  needs in-set size ≥ 2 unless ≤1 member is fresh — lone watcher plays
  alone, second watcher present ⇒ one Space waits. Late joiners outside
  the set never block.
- Single room password (one secret, persisted in Hive on the user's own
  box — accepted). No op roles (deferred: op flag + second hello
  secret). Kick = transient nudge: revoke + close + `kicked` reason,
  instant rejoin with fresh token.
- Deferred, do not build: TLS/Caddy, Jellyfin native, auto-updater,
  playlist (extension shape reserved in PROTOCOL.md), op roles, sounds
  (researched, wired, no assets — see §7).
- Standing rules: health reporting (every failure displays, nothing
  stalls silently); proto bump + PROTOCOL.md same-commit on ANY
  wire change (still v4 — quorum/timeouts are server policy, no bump).

## 3. Repo map (root: Flutter/sync_relay_project/)

- `packages/core/lib/src/`: constants.dart (tuning: seek 300 ms,
  drift 5 s, slow 1.5 s @0.95, min_buffer 4 s, heartbeat 1 s, ping 5 s,
  avatar 64 KiB, name 32, chat 500; dropAfter lives as RoomEngine ctor
  default, now 30 s), errors.dart, logging.dart, config.dart,
  protocol.dart (v4 schemas), media_source.dart, sync_engine.dart
  (RoomEngine + quorum in evaluate's HELD branch; PLAYING branch
  unchanged).
- `packages/server/lib/src/`: session.dart, media_endpoint.dart,
  room_hub.dart (forgetSocket, sweepClosedSockets via `isClosed` poll,
  closeAllSockets, onError→forgetSocket), room_server.dart (1 Hz
  heartbeat: sweepStale + sweepClosedSockets + dropSilentSockets +
  broadcast; stop() closes client sockets first). `bin/server.dart`.
- `apps/desktop/lib/src/`: sync/ (sync_client.dart: hello/intents/
  fan-out/match-by-`t`; room_diff.dart: diff + debounce + play gate),
  playback/ (media_kit Player, 64 MB cache, pin props, 0.5 s seek
  deadband, stop() on leave, SYNC_RELAY_VO/HWDEC env overrides),
  session/ (session_coordinator.dart: THE brain — room→player,
  reports, scrub/nudge→seek intents incl. HELD, seek-land retry,
  idle 8/10 min, reconnect loop, 5 s silence timeout; health.dart),
  sfx/ (SfxKind/Cue/Service + NoopSfxService — sounds deferred),
  state/ (session_state.dart: route/mode/lastForm/prefs/host/join/
  leave; connect_prefs.dart), screens/ (welcome/connect/session),
  widgets/ (user_section.dart: ConnectProfileCard; member_avatar.dart:
  THE avatar — memoized, no bg on images, dark ring+fallback;
  dialogs.dart: kick confirm; media_input.dart: parseMediaInput).
- `apps/desktop/test/`: room_diff_test (9), media_input_test (6),
  sync_playback_e2e_test (quorum: solo Space holds, both ready plays;
  needs mpv + ~/Videos/chiyo.mp4), coord_presence_test (dead server
  clears + reconnects; needs mpv).
- `tool/`: range_logger, shaper (chaos: KB/s cap, latency,
  --kill-after), fake_viewer, e2e_check (sim timeline, still ALL PASS
  post-quorum).
- `docs/`: PROTOCOL.md (v4 + quorum + 15/30 s timeouts + isClosed note,
  normative), ARCHITECTURE.md (+health rule), mpv-http-contract.md.
- `deploy/`: systemd unit. No git repo anywhere (recommending `git
  init` was never approved — ask before creating one; bisection is
  currently impossible, which hurt on §8).

## 4. Protocol v4 + policy (see PROTOCOL.md for normative detail)

hello→welcome(token, memberId, mediaUrl?, room-state); intents:
ready{ready,source}/force{target:all|memberId,ready}/seek/seek-swap/
report{position,buffered,eventId}/chat/kick{memberId}. Broadcasts:
room @1 Hz + on change (diff by eventId), feed{actor,action,…}
(toasts/log/sounds), kicked{reason}, err. Media:
GET /m/<sid>/<token>/<name> (200/206×3 shapes/416/401/403/410/503).
Transport PLAYING/HELD; gate = non-empty set AND all in-set ready +
buffered≥4 s + fresh AND quorum (in-set≥2 unless ≤1 fresh).
Stale >15 s ⇒ out of gate; silent >30 s ⇒ closed + removed.
Closed sockets swept every second; socket errors remove immediately.
Client: 5 s room-silence ⇒ dead (clear room, warn, reconnect loop
1.5 s polite infinite + manual cancel/retry, prior-flag restore).

## 5. Phase log (all exits met, all green as stated above)

- P0 scaffold + CI + Flutter-free tests; binary binds/logs/exits.
- P1 Range table byte-exact, real mpv traces, shaper built. 503 tested.
- P2 sessions: secret→128-bit token, 401/403/410 gates, kick kills WS+
  media, byte counters, fake_viewer ALL PASS live, proto→3.
- P3 engine + readiness: engine tests (fake clock), e2e 15/15 sim,
  Syncplay audit. Sanity: NaN guards, caps, stale/leave feeds,
  1 Hz flush, token redaction.
- P4 desktop shell→app: SyncClient framing, RoomDiff (eventId diff,
  slowdown latch 0.95×/0.1 reset, seek-land check), media_kit wiring
  (pinned buffer props, buffered from demuxer), Space=ready, avatars,
  toasts+sheet, health display, reconnect loop. Sounds WIRED ONLY
  (NoopSfxService) — see §7.
- P5 presence+sync hardening (user-reported, all reproduced live
  first): stop() closes sockets; isClosed sweep (~1 s graceful);
  onError forget (~2–4 s kill -9, was 56 s ghost); drop 60→30 s;
  client silence-timeout + stuck-reconnect-flag fix + ready-future
  leak fix; seek race fixed (2 s same-event debounce both
  transports, edge-aware detector 1 s guard, 0.5 s apply deadband);
  HELD seeks send intents (paused frame moves for all); arrows
  nudge ∓10 s; local play gate (in-set+ready); autoplay off;
  leave() stops player (was leaking audio); kick confirm; Cancel
  connect; connect-form memory→Hive persistence; file/media
  Browse buttons.
- P6 UI redesigns (two subagents, disjoint files — repeat this
  pattern): full-bleed video + overlays, controls never autohide
  (24 h hover) + Ready/Mark-everyone-ready IN the controls bar
  (intents only, zero local transport buttons), center avatars-only
  64 px, slide-in toasts, animated right sheet (users/log/chat/swap/
  Leave w/ confirm), health pill only-when-unwell, ESC closes/
  asks-leave, global focus-proof keys (Space/Tab/arrows/ESC,
  350 ms throttle, ignored while typing), single media field
  (parseMediaInput + tests), avatar pipeline (128 px JPEG, tap to
  pick, no path fields), Discord-like corner profile (connect only;
  welcome is title+Host/Join; edits apply next join — no rename
  intent on the wire), dialogs for terminal states.
- UX decisions locked along the way: Space flips self-ready only;
  free seeks any transport (no flag churn); join catch-up never
  halts; idle 8-min warn + 10-min auto-unready; reconnect = re-hello
  with flag restore; kick → dialog + connect screen; fixed 1.5 s
  reconnect + cancel/retry; GMod toasts (social only) + side sheet;
  avatar fallback = initial circle; "waiting for X (n/m ready)".
- Open user questions for later: warning-tone timing; bar width at
  minimum window; second-ESC on leave dialog (re-asks vs cancel);
  cancel-stops-host-server (kept: idle means no bound port).

## 6. Gotchas (learned the hard way)

1. Relic gives Range as TYPED RangeHeader — convert via unit+first.
2. Relic server-side onDone DOES NOT fire for dead peers (proven
  live both directions: clean close AND kill -9 both ghosted to
  timeout). Presence = isClosed heartbeat sweep + socket-onError
  forget + lastSeen timeouts. NEVER depend on onDone. (Docs pattern
  confirms CloseReceived is a data event.)
3. Welcome races room broadcasts — match WS messages by `t`, never
  by index.
4. web_socket_channel streams are single-subscription — one listener
  per socket (test double-listens throw "already been listened to").
5. `sub.asFuture()` can resolve before `onDone` — poll with
  deadlines in tests.
6. Comma-form mpv reconnect flags work here; colon-form rejected
  (re-verify via set_property if touched).
7. Numeric literals corrupted once by tooling — verify with rg after
  writes touching ports/consts.
8. Tool `bash` `&`-backgrounding is unreliable; use nohup + log file
  in its OWN call, poll in later calls, kill via `fuser -k
  PORT/tcp` (never `pkill -f`). Chain small calls, never long
  `&`-chains (they hang the runner past timeout with zero output).
9. Tests must not assume threat model beyond trust-basis.
10. web_socket_channel 3.x: `channel.ready` errors unhandled on
  refused connections — eat it (`unawaited(ch.ready.then(...,
  onError: ...))`); stream onError is the reporting path.
11. MediaKit has NO public Player.setProperty — runtime props go via
  guarded dynamic call on player.platform; cache size via public
  PlayerConfiguration(bufferSize:).
12. NEVER `flutter test`-pump the session screen: media_kit Video
  hangs the runner (a hung flutter_tester must be kill -9'd by PID;
  pgrep carefully). Sync-path coverage lives in room_diff (pure),
  lifecycle (server, raw WS), coord_presence + e2e (real mpv,
  no widgets). Deleted session_overlays_test.dart for this reason.
13. No `flutter analyze` unless asked (IDE covers it) — except
  deliberate per-change checks; kept clean throughout.
14. New `MediaDesktopVideoControlsThemeData` per build is fine
  (stock guards subscriptions) but wasteful; leave it.
15. Env overrides for mpv experiments (no rebuild to switch):
  SYNC_RELAY_VO (e.g. xv, gpu, gpu-next), SYNC_RELAY_HWDEC (e.g. no).

## 7. Sounds (deferred, wiring ready)

Base: Kenney Interface Sounds (CC0, confirmation_* ladder for
ascending-ready). Alt ladder: ObsydianX Pack 1 (CC0, avoid paid
packs). Soft layer: akx/Notifications (CC0 branch). Playback pick:
flutter_soloud (preload WAV, per-play pitch) — NOT added. Swap-in =
replace NoopSfxService; cues already fire with readyIndex. URLs +
mapping in 09-11 chat (unreliable — re-derive from sources above).

## 8. Black window while playing (09-12, FIXED)

Symptom was: room PLAYING ⇒ entire window black (audio + keys
alive, unready restored, zero errors). Cause: the waiting-avatars
center overlay unmounted its GPU textures (avatar Images) exactly
at the HELD→PLAYING flip; teardown racing mpv's frame uploads on
the shared GL context fails silently ⇒ black. Legacy chips never
unmounted and minimal never mounted, which is why they survived.
Fix: center overlay is Visibility(visible + maintainState +
maintainAnimation + maintainSize) — avatars stay mounted, paint
skipped when hidden. Verified by user with full tree.
RULE: never unmount GPU-textured widgets on a transport-gated
branch; keep mounted + skip paint. Bisect screens
(legacy/minimal/nosheet + SYNC_RELAY_UI switch in app.dart)
still wired — delete on approval. session_screen.dart may still
hold the user's commented bisect lines — restore or drop.

## 9. Next (ordered)

1. §8 black screen — diagnose with user, then fix.
2. 2-client LAN soak (manual, user-driven).
3. 1.4 GB real-file media test (user resupplies Jellyfin URL;
  contains api_key — NEVER paste into files).
4. Cache-exhaustion long outage via shaper --kill-after (Phase 5
  chaos assertion, never run).
5. Internet test: plain TCP works in theory; needs forwarded port
  or Tailscale; expect more slowdown engagement on latency.
6. Sounds swap-in (§7) after audition.
Environment: dart 3.14 beta, flutter 3.48 beta, mpv+ffmpeg present,
~/Videos/chiyo.mp4 sample. Never kill the user's Syncplay mpv
instance. No git repo — ask before creating one.
