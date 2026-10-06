# Roadmap

Backlog and epics, in order. Done work lives in git history. Check an item
off by deleting it in the same commit as the code. Wire changes also edit
[PROTOCOL.md](PROTOCOL.md).

## Backlog

1. **Windows build + CI.** There is no Windows runner. Try
   `ubuntu2610/flutter_build` (LLVM-MinGW + Wine `gen_snapshot`) on the Linux
   runner, fallback a GitHub Actions mirror. The manifest needs per-platform
   URLs and `release_publish.sh` must handle a second platform. The updater's
   Windows apply path exists but is untested. The tarball's
   `watch-together-server` needs a Windows `dart compile exe` too. Desktop
   tests are not in CI either.

2. **Jellyfin** (epic, below).

3. **Smaller items**
   - Video output robustness: if media_kit's hardware path regresses to
     software (see ARCHITECTURE, Media: render mode), vendor a
     media_kit_video fix that builds the EGL display from GDK's native
     display. The video freeze after GPU idle is not explained by this;
     next suspect is media_kit's context switching on the raster thread
     with NVIDIA.
   - Link conveniences: a link swap in session updates the remembered media;
     show the open link with an open-in-browser button; the session's swap
     panel reuses Home's `MediaPicker`.
   - Time UI: remaining time, scrubber preview.
   - mpv / mpv.net shortcut parity.
   - Sounds: replace `NoopSfxService` (cues already fire). Candidates:
     Kenney Interface Sounds (CC0), ObsydianX Pack 1 (CC0), akx/Notifications
     (CC0); playback via flutter_soloud. Keep seek/pause/resume near silent.
   - Chaos suite: host drop 5 s / 30 s, viewer stall, 20-seek storm, long
     outage with cache exhaustion (`tool/shaper.dart --kill-after`); assert no
     OOM, no stuck session, drift recovers.
   - Chat history pane (today: activity log only).
   - Avatar caching: serve avatar bytes once by hash instead of base64 in
     every `state` broadcast.
   - The `state` broadcast carries the full media URL, which can include an
     `api_key`.
   - TLS: document a reverse proxy in front of the server.
   - Playlist: `queue-add`, `queue-skip`, auto-advance like a swap.
   - Sidecar subtitles.

## Epic: Jellyfin

- Each viewer logs in to Jellyfin themselves (Quick Connect or password).
- Several Jellyfin servers can be linked, keyed by `ServerId`.
- The sync server shares only `{ServerId, ItemId}`. Pasted Jellyfin links are
  recognised and reduced to that pair.
- Viewers with an account direct-play `/Videos/{id}/stream?static=true`
  with their own token and report Playing / Progress / Stopped, so watched
  state and Continue Watching update per account.
- Guests without an account play through the sync server, which fetches with a
  credential that stays server-side (the host's own or a configured one).
- Next episode: the successor in `/Shows/{seriesId}/Episodes` (NextUp means
  first unwatched, not next-after-X); audio and subtitle track matching by language, then title,
  then codec/channels.
- Library browser; anyone can put up items.

Spike facts (Jellyfin 10.11.11): `/Videos/{id}/stream?static=true&mediaSourceId=`
serves the original with byte ranges (206). PlaybackInfo gives `PlaySessionId`
and DirectPlay. All audio and subtitle tracks are embedded in the mkv. Quick
Connect is enabled but `/QuickConnect/Initiate` returned 400: investigate
(likely missing client/device fields in the auth header).

## Deferred

P2P, Android. Never: transcoding, web clients.
