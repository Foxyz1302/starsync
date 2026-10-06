# Roadmap

Backlog and epics, in order. Done work lives in git history. Check an item
off by deleting it in the same commit as the code. Wire changes also edit
[PROTOCOL.md](PROTOCOL.md).

## Backlog

1. **Isolate server + dedicated server.** Replace host detection by loopback
   peer (breaks behind a same-machine reverse proxy or tunnel) with an explicit
   host token. Run the server on a Dart isolate
   when hosting from the app; build the dedicated server as a separate
   `dart compile exe` of `packages/server` (a Flutter binary cannot be
   headless); drop `--headless`; rename "room" to "server" in code
   (`RoomServer`, `RoomHub`, `RoomBroadcast`, wire `t:'room'`, `room` in
   `/health`, config defaults) with the proto bump that implies; refresh
   `deploy/` and the packaging.

2. **Sync fixes.**
   - Jumpy seek. Root cause: the media_kit seek bar calls `player.seek`
     continuously while dragging; the coordinator only notices through its
     1 s position poll (`_detectUserSeek`), so it fights the server echo and
     the seek-landed retry (`_checkSeekLanded`).
   - End-of-file stall. The 4 s buffered gate cannot be met in the last 4 s of
     a file, the server never learns the duration, and there is no finished
     state. Add duration reporting and a finished state.
   - Tiny read-ahead. Our own pins (`cache-secs=10`,
     `demuxer-readahead-secs=10` in `playback_controller.dart`) cap it; want
     about two minutes for large files.
   - Remote clock offset is not corrected: clients assume their clock equals
     the server's.
   - Stale-ready. A ready member who went stale (no reports for 15 s) should
     return to the ready set when reports resume; the client re-sends ready as
     a workaround (remove it then).
   - Ghost member after an unclean drop until `dropAfter`.

3. **Rendering, then shaders.** media_kit falls back to software rendering
   on the dev machine. Suspect Impeller on Linux against media_kit's GL
   texture path; investigate first, since shaders need hardware rendering and
   it may also cause the video freeze. Then shaders: per-viewer local setting
   using mpv `glsl-shaders`, shipping Anime4K presets (bloc97, MIT).

4. **Windows build + CI.** There is no Windows runner. Try
   `ubuntu2610/flutter_build` (LLVM-MinGW + Wine `gen_snapshot`) on the Linux
   runner, fallback a GitHub Actions mirror. The manifest needs per-platform
   URLs and `release_publish.sh` must handle a second platform. The updater's
   Windows apply path exists but is untested. Desktop tests are not in CI
   either.

5. **Jellyfin** (epic, below).

6. **Smaller items**
   - Link conveniences: Ctrl+V pastes into the media field; a link swap in
     session updates the remembered media; show the open link with an
     open-in-browser button.
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
     every `room` broadcast.
   - The `room` broadcast carries the full media URL, which can include an
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
