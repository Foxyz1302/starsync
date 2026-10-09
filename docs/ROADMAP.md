# Roadmap

Backlog and epics, in order. Done work lives in git history. Check an item
off by deleting it in the same commit as the code. Wire changes also edit
[PROTOCOL.md](PROTOCOL.md).

## Backlog

1. **Ready gate and swap (protocol bump).** Bug: three in a server, a file
   relayed from one; two readied and it played, the third (not ready) was
   dragged along frame by frame. Members present at a swap must all count
   for the gate (a joiner after the swap still counts only once ready);
   a swap keeps everyone's ready flag, with a per-user "Unready when the
   video changes" setting. Shared auto-skip lives here too (below).

2. **Quick UI**
   - Tab no longer moves focus (Tab toggles chat, then Space pressed a
     random button); Space is always ready outside text fields.
   - Opening chat focuses its field; Esc/Tab hands focus back.
   - Unread badge on uosc's chat button; an unread hint in fullscreen.
   - Your avatar in the strip the same size as the party's.
   - Chat panel: people's messages only, a toggle shows activity.
   - Skip OP/ED: no "Skip 1:30" guess when the file has chapters (a
     missing OP chapter is on purpose); the pill shows for the first 5 s
     of the range and again when the mouse moves (like the controls).
   - Auto-skip OP/ED: a server-wide setting in `state` (anyone toggles it,
     the feed says who); exactly one client seeks (the media's `swapBy`,
     else the lowest fresh member id), only for real ranges (segments or
     OP/ED chapters), as a normal user seek.
   - Volume above 100% like mpv.

3. **Drag & drop and paste** (`fox_utils`): drop or Ctrl+V anywhere; a
   small card asks how to open it (file: put up / add its folder to Files;
   link: put up with the link modes; image: the avatar editor when open).

4. **Files**: detected series groups start collapsed (big libraries);
   next episode from Files (by parsed episode, with the countdown). Later:
   tracking for file series.

5. **yt-dlp** (epic): players that open links themselves use mpv's ytdl
   hook (bundled on Windows); then relay of single-file formats; then a
   resolver for the Link preview (title, thumbnail, duration).

6. **AniList account**: sign in (OAuth via a localhost callback), "My list"
   filter on the Schedule; today's "Following" (AnimeFlow's monitored
   shows) becomes "On the server".

7. **Ops**: `watch-together-server --upgrade` (a VPS has no GTK for the
   app's updater); check shaders on Windows; the relay e2e "source drops
   uncleanly and resumes" fails about half the time under the full suite.

8. **Windows: first real use.** CI builds and publishes
   `watch-together-<ver>-windows-x64.zip` (libmpv bundled) and runs the
   updater tests on NTFS; a friend has joined from it. Still unchecked:
   fullscreen controls, hosting (firewall prompt), in-app update from one
   release to the next. The rest of the desktop tests are not in CI.

9. **Relay follow-ups** (see ARCHITECTURE "Relay"). First real use: owner's
   PC -> VPS -> friend, Jellyfin and a file. Then:
   - Source takeover: when the source leaves, another member with an
     account on that Jellyfin (or the same file: name, size, hash) takes
     over instead of the buffer running dry.
   - "Bob can't open this link — relay it?": offer the relay to whoever put
     a direct link up when a viewer's player fails to open it.
   - Show who is relaying and how fast in the member list; warn the source
     when its upload is below the media's bitrate.

10. **Jellyfin** (epic, below).

11. **Smaller items**
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
