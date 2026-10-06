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
     show the open link with an open-in-browser button.
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
     `api_key` (recognised Jellyfin links become refs; other links do not).
   - TLS: document a reverse proxy in front of the server.
   - Playlist: `queue-add`, `queue-skip`, auto-advance like a swap.
   - Sidecar subtitles.

## Epic: Jellyfin

What is left (the rest is in [ARCHITECTURE.md](ARCHITECTURE.md), "Jellyfin
in a session"):
- Queue: put several library items (a season, a pick list) up as a
  playlist that advances like a swap (shares `queue-add` / `queue-skip`
  with the backlog's Playlist item).
- The "Next episode" prompt from the item's Outro / credits segment instead
  of the last two minutes (`nextPromptStart`).
- Auto-advance cancel for everyone: today Cancel is per screen (the
  designated swapper's Cancel stops the swap; a seek stops all). A shared
  cancel needs a wire message.
- Sidecar (external) subtitle streams of Jellyfin items: only embedded
  tracks are mapped to mpv today.

## Deferred

P2P, Android. Never: transcoding, web clients.
