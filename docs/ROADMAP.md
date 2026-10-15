# Roadmap

Backlog and epics, in order. Done work lives in git history. Check an item
off by deleting it in the same commit as the code. Wire changes also edit
[PROTOCOL.md](PROTOCOL.md).

## Stabilisation (feature freeze)

No new systems or features until the app is stable on a proper
architecture. The next release is the restructure (1.3.0, or 2.0.0).
Problems are numbered; delete a line when its fix ships.

**Decisions** (agreed):
- D1 Presence: In (watching, full), Away (sat out: still in the server,
  chat and chosen notifications, system notifications in the background,
  not counted for the gate, ready counter or watched tracking), Gone
  (disconnected, held in a grace period).
- D2 A joiner during playback holds it until everyone watching is ready,
  like the start gate.
- D3 Watched: at least as good as Jellyfin's own; a peek, skipping around
  or a screenshot visit never counts. Basis: time present while it played.
- D4 Toasts above the control bar; toasts for joins/leaves, queue adds
  (title, picture, who), swaps, problems; the rest in the activity log.
  Chat pop-ups and their sound always on by default; only the unread badge
  stays off the picture.
- D5 A reconnect resumes the same member within a grace period (~10 min).
- D6 The person passing a video on drops: others keep playing; on
  reconnect the relay continues from where it was.
- D7 One controls model, two skins (done in 1.2.1-dev.1); uosc credited.
- D8 Always the latest version: automatic checks, a clear prompt (no
  background download), never during playback.
- D9 Watching alone is a full standalone player: no social sounds or
  prompts; social parts appear when others are there; no solo mode.
- D11 Login-only sites: error texts say which cookies were used.

**Problems:**
- P1 A reconnect makes you a new member: the relay, ready, sitting out and
  your queue items are lost (log: Hoff m23 → m24 had to put ep 06 up again).
- P2 Joining a relay whose source left serves broken leftovers; mpv loops
  on failed seeks; nobody is told the source is gone.
- P3 A joiner during playback lands mid-scene (see D2).
- P4 Reconnects time out repeatedly on a bad link; no clear
  "reconnecting" state.
- P6 Sat-out people count in the ready counter.
- P7 Sat-out people get tracked as watched on Jellyfin.
- P8 Sat-out people get the normal notifications.
- P9 The watched rule (position coverage) misses real watches (D3).
- P11 Toasts cover the video controls.
- P12 Queue additions don't show as toasts.
- P15 Commands reach a player mid-switch (`seek 90.0`, `event:5` errors).
- P17 Preload, warm relay and the fresh player per video are layered on
  the player instead of being one media pipeline.
- P18 Bilibili "no video formats" with browser cookies set; the hint
  wording misleads (D11).
- P20 Version not visible. P21 Updates easy to miss. P22 Friends on
  different versions (D8).
- P23 Solo mode you enter and leave; going hosted loses the queue (D9).
- P24 The invite address list is unhelpful (shows the proxy's 198.18.x).
- P25 ssh to Gitea blocked through the proxy (pushes go over https).
- P27 Failing tests: shell "Ctrl+V outside a field", relay e2e "a guest
  puts up a file", "links: through me".
- P28 Log noise: "Failed to create file cache"; an idle relay channel for
  Jellyfin items everyone has an account for.
- P29 Relay start delay after a seek into an unbuffered part.
- P30 Shaders don't work on Windows (our read-back check turns them off;
  dxva2-egl interop error).
- P31 Software rendering on a friend's Linux; render mode not logged.
- P32 The app freezes/segfaults on exit (NVIDIA EGL exit handler; mpv
  players alive at teardown; Windows close order).
- P33 No volume readout when using the mouse wheel on the video.
- P34 Local anime folders are opened as plain files (no banner, names,
  next episode, tracking).

**Restructure** (in order): identity + presence (D1 D2 D5 D6); notifier
(toasts, sounds on `SoundEngine`, system notifications, activity log);
what's next + watch tracking (D3); media pipeline + media identity
(Jellyfin, local folders, links resolve to one show/episode identity);
"your server" (D9). The plan with the current and target system maps is
the "Starsync architecture" write-up.

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

5. **Ops**: Check shaders on Windows; the relay e2e "source drops
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
   - The host's own file as Up next's first item: it plays from `/m`
     once up, so others open it cold (the warm relay covers every other
     relayed item, see ARCHITECTURE "Relay"). The hosting app could hand
     the server the item's path early and `/m` serve it under a `next/`
     name until the swap.
   - Research (before building anything): can stream URLs a member's
     app resolved with yt-dlp (its cookies, its address) be fetched by
     the server from another address? Per site: YouTube (its
     `googlevideo` URLs carry the resolving IP), Bilibili, X, generic
     HLS/DASH, others; and YouTube resolved by the server itself from a
     VPS, with and without cookies. Decides whether a server-driven
     fetch of member-resolved links (the member need not upload or stay)
     is worth building.

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
   - Up next follow-ups (see ARCHITECTURE "Up next"): a member
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
