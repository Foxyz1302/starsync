# Roadmap

Backlog and epics, in order. Done work lives in git history. Check an item
off by deleting it in the same commit as the code. Wire changes also edit
[PROTOCOL.md](PROTOCOL.md).

## Backlog

1. **Auto-skip OP/ED** (undecided): who decides and how (shared for the
   server, personal, per show) is open. Constraint: a skip is a seek and
   seeks are shared, and only real ranges (segments, OP/ED chapters) should
   ever be skipped.

2. **Files**: next episode from Files (by parsed episode, with the
   countdown, and under Up next's "Continues with"). Later: tracking for
   file series.

3. **yt-dlp follow-ups** (see ARCHITECTURE "yt-dlp"): check that the
   bundled Windows libmpv has the ytdl hook (Lua) and plays `edl://` URLs
   through media_kit; if not, resolve in the app and open the relay
   tracks' formats. YouTube: yt-dlp wants a JS runtime (deno) for full
   extraction. Formats that need yt-dlp's cookies.
   - Live streams through the relay (today refused: the sync model needs a
     fixed duration and seeking).
   - `tool/relay_e2e.dart`: a two-track case (bytes and pieces) over a
     shaped source link. Pieces on a slow source: a cold piece can take
     longer than media_kit's 5 s `network-timeout`; if it does, fetch the
     first pieces before setting `relay.live`.
   - Pieces, unverified so far: the 403/410 re-resolve against a real
     expiring HLS (signed segment URLs), HLS discontinuities / ad
     splicing, Windows' bundled ffmpeg with extensionless piece URLs
     (`p/<i>`; fine with ffmpeg 9 on Linux).
   - Thumbnails and scrubbing previews of a relayed media with tracks
     should open the video track's URL alone, not the EDL.

4. **AniList account**: sign in (OAuth via a localhost callback), "My list"
   filter on the Schedule from the user's AniList lists. This is the
   Schedule's personal tracking; AnimeFlow has no per-user follow.

5. **Ops**: `leaf_widgets` (the Up next popover's `LeafPopover`) is a
   local path dependency: make it a git dependency like `fox_utils`
   before the next release (CI cannot see the path), or go back to the
   app's popover route. Check shaders on Windows; the relay e2e "source drops
   uncleanly and resumes" fails about half the time under the full suite.

6. **Windows: first real use.** CI builds and publishes
   `watch-together-<ver>-windows-x64.zip` (libmpv bundled) and runs the
   updater tests on NTFS; a friend has joined from it. Still unchecked:
   fullscreen controls, hosting (firewall prompt), in-app update from one
   release to the next. The rest of the desktop tests are not in CI.

7. **Relay follow-ups** (see ARCHITECTURE "Relay"). First real use: owner's
   PC -> VPS -> friend, Jellyfin and a file. Then:
   - Source takeover: when the source leaves, another member with an
     account on that Jellyfin (or the same file: name, size, hash) takes
     over instead of the buffer running dry.
   - "Bob can't open this link — relay it?": offer the relay to whoever put
     a direct link up when a viewer's player fails to open it.

8. **Jellyfin** (epic, below).

9. **Smaller items**
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
   - Chaos suite: host drop 5 s / 30 s, viewer stall, 20-seek storm, long
     outage with cache exhaustion (`tool/shaper.dart --kill-after`); assert no
     OOM, no stuck session, drift recovers.
   - Chat history pane (today: activity log only).
   - Images in chat (paste a screenshot; server memory only): possible,
     not wanted yet.
   - HTTP: move the app's clients (Jellyfin, AniList, AnimeFlow, updater)
     to dio from `fox_utils` when touching them, for retries/interceptors.
   - TLS: document a reverse proxy in front of the server.
   - Up next follow-ups (see ARCHITECTURE "Up next"): getting the first
     item ready only resolves its link; fetching its first seconds early
     through the relay would make relayed starts instant too. A member
     whose reconnect lands as a new member loses its "through me" links
     and files in the queue (skipped as gone); the key could follow the
     member. A whole season or a pick list at once ("Add the rest of the
     season").
   - Sidecar subtitles.

## Epic: Jellyfin

What is left (the rest is in [ARCHITECTURE.md](ARCHITECTURE.md), "Jellyfin
in a session"):
- Auto-advance cancel for everyone (the next episode and Up next): today
  Cancel is per screen (the designated swapper's Cancel stops the swap; a
  seek stops all). A shared cancel needs a wire message.
- Sidecar (external) subtitle streams of Jellyfin items: only embedded
  tracks are mapped to mpv today.

## Deferred

P2P, Android. Never: transcoding, web clients.
