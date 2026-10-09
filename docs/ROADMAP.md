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
   countdown). Later: tracking for file series.

3. **yt-dlp follow-ups** (see ARCHITECTURE "yt-dlp"): check that the
   bundled Windows libmpv has the ytdl hook (Lua) and plays `edl://` URLs
   through media_kit; if not, resolve in the app and open the relay
   tracks' formats. YouTube: yt-dlp wants a JS runtime (deno) for full
   extraction. Formats that need yt-dlp's cookies.
   - Relay "pieces" tracks for pages with only HLS/DASH (`m3u8_native`,
     `http_dash_segments`): a track served as a synthesized VOD media
     playlist whose entries are pieces (one segment, init `EXT-X-MAP` or
     AES-128 key = one upstream GET, served whole, Range inside a piece
     honoured), with a piece buffer per track (pieces by index, filled
     like `RelayBuffer`: a blocked viewer, the init piece, then ahead of
     the slowest viewer; evicted by distance); `EXT-X-BYTERANGE` folded
     into pieces (it also avoids mpv's seek hang on byte-range fMP4
     playlists); yt-dlp's DASH `fragments` turned into the same playlist,
     so no MPD parser. Wire: a track entry gains `"as":"pieces"`, `info`
     lists piece durations, a pull names a piece. Refuse DRM
     (`skd:`/SAMPLE-AES/Widevine). Measured in a spike: piece relay of
     Mux/Apple/Akamai HLS/DASH opened in 1.5 to 2.2 s, seeks 0.02 to 2.4 s.
   - Live streams through the relay (today refused: the sync model needs a
     fixed duration and seeking).
   - `tool/relay_e2e.dart`: a two-track case over a shaped source link.

4. **AniList account**: sign in (OAuth via a localhost callback), "My list"
   filter on the Schedule; today's "Following" (AnimeFlow's monitored
   shows) becomes "On the server".

5. **Ops**: `watch-together-server --upgrade` (a VPS has no GTK for the
   app's updater); check shaders on Windows; the relay e2e "source drops
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
   - Show who is relaying and how fast in the member list; warn the source
     when its upload is below the media's bitrate.

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
- Auto-advance cancel for everyone: today Cancel is per screen (the
  designated swapper's Cancel stops the swap; a seek stops all). A shared
  cancel needs a wire message.
- Sidecar (external) subtitle streams of Jellyfin items: only embedded
  tracks are mapped to mpv today.

## Deferred

P2P, Android. Never: transcoding, web clients.
