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

1. Update endpoint live: publish `updates/manifest.json` + first
   release tarball on Forgejo (user-owned step; schema in
   `updates/manifest.example.json`). Until then `--upgrade` reports
   up-to-date against a missing manifest.
2. Jumpy seek: live repro with timeline log first, then fix the
   seek-land retry vs deadband/debounce fight.
3. Sounds swap-in: replace `NoopSfxService` (flutter_soloud preload,
   Kenney/ObsydianX/akx sources in HANDOFF §7); keep seek/pause/
   resume cues muted or near-silent.
4. `/health` auth + stop broadcasting the full media URL (api_key
   leaks onto the wire).
5. File-join wart: welcome mediaUrl advertises 127.0.0.1, remote file
   joiners fail-open then self-heal on first room broadcast.
6. Cache-exhaustion long outage via `tool/shaper.dart --kill-after`.
7. Phase 5 chaos suite (host drop 5 s / 30 s, viewer stall, 20-seek
   storm) + OOM / stuck-room / drift-recovery assertions.
8. Windows zip in `tool/package_linux.sh`'s sibling + Discord card.
9. TLS/Caddy doc.
10. Chat history pane (schema exists, Activity log only for now).
11. Backfill LAN soak + 1.4 GB test details (record-only, user ran
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
