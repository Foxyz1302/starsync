# ROADMAP — sync_relay_project (backlog tracker)

This is the durable source of truth for what is built and what is next.
Chat is ephemeral; this file + `HANDOFF.md` (root) + `PROTOCOL.md` /
`ARCHITECTURE.md` carry state across sessions. Check an item off when it
lands, same commit as the code. Proto bumps still require PROTOCOL.md
same-commit.

Model: direct-serve (host opens ports, clients open nothing). The
brief's old WSS host-upload tunnel is obsolete unless a VPS tier
needs remote-host upload. Server = Relic, client WS =
web_socket_channel. Protocol still v4.

## Built (phases 0–4 + hardening — done, details in git history)

Scaffold + CI, mpv Range contract, sessions/tokens/media endpoint,
sync engine + quorum, desktop shell (SyncClient, RoomDiff, media_kit,
avatars, toasts+sheet, reconnect), presence hardening, frameless
chrome, chat/idle fixes, chat double-row fix, avatar 256 KiB cap,
Linux tarball packager + Discord upload card, updater v1
(`--upgrade`: manifest check, download, sha256, apply-over).
WAN-tested 2-client. Counts at last green: core 42, server 41,
desktop 17 + 7 updater.

## Backlog (priority order, each one sitting-sized)

1. First real release: release commit bumps desktop pubspec, tag
   `v0.2.0`, CI (`release.yml`) builds the tarball, publishes the
   Forgejo release, and commits the manifest back. Verifies the
   whole `--upgrade` chain end to end. Manual fallback is
   `tool/package_linux.sh` + `tool/release_publish.sh <tag>`.
2. Jumpy seek: live repro with timeline log first, then fix the
   seek-land retry vs deadband/debounce fight.
3. EOF stall (bug, dogfood 09-12): playback stops just before the
   end and gates HELD ("waiting for X (3.9s)"). Suspect the
   buffered≥4s readiness gate is unsatisfiable near end of media.
4. Tiny buffer (bug, dogfood 09-12): 1–3 s observed; want ~2 min
   for a 1.4 GB / 24 min file (intro skip + surviving short
   drops). Investigate demuxer forward-queue props + 64 MB
   `bufferSize`, then raise.
5. Recovery controls: reload-current-media button + restart-player
   button for when playback wedges.
6. Link conveniences: Ctrl+V pastes clipboard into the media
   field; session link swaps update the remembered media (today
   only the connect screen persists); session shows the open link
   with an open-in-browser button.
7. Time UI: remaining time until end + scrubber preview (target
   time while scrubbing).
8. Shortcut parity pass with mpv / mpv.net.
9. Sounds swap-in: replace `NoopSfxService` (flutter_soloud preload,
   Kenney/ObsydianX/akx sources in HANDOFF §7); keep seek/pause/
   resume cues muted or near-silent.
10. `/health` auth + stop broadcasting the full media URL (api_key
    leaks onto the wire).
11. File-join wart: welcome mediaUrl advertises 127.0.0.1, remote file
    joiners fail-open then self-heal on first room broadcast.
12. Cache-exhaustion long outage via `tool/shaper.dart --kill-after`.
13. Phase 5 chaos suite (host drop 5 s / 30 s, viewer stall, 20-seek
    storm) + OOM / stuck-room / drift-recovery assertions.
14. Windows zip in packaging + Discord card.
15. TLS/Caddy doc.
16. Chat history pane (schema exists, Activity log only for now).
17. Shaders: anime4k upscaling via mpv glsl-shaders + UI toggle.
18. Avatar caching + static serving (worth-it decision open):
    serve avatar bytes once over HTTP by hash instead of
    base64-in-every-room-broadcast.
19. Backfill LAN soak + 1.4 GB test details (record-only, user ran
    both 09-12).

## Epics (multi-sitting, scheduled whole — not before the backlog
friction items above, except Jellyfin which is next feature)

- File relay (original brief, second half): links shipped, relay
  unbuilt. Split into sub-tasks when scheduled.
- Jellyfin native — NEXT feature.
- Updater expansion: in-app prompt, Windows helper (locked-exe
  dance), auto-restart after apply.
- Playlist (`queue-add`/`queue-skip`, shape reserved in PROTOCOL.md),
  sidecar subtitles, local-file fallback (viewer plays matching
  size+duration file locally, still synced), `HttpSource` (host
  pastes a direct-stream URL, server fetches + re-serves).

## Deferred (needs explicit approval; transcode is never)

P2P/WebRTC, multi-session, Android. Transcode: NEVER (user decision
09-12 — not the age for it anymore).
