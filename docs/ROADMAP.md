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
- D2 A joiner during playback does not pause it: they load in the
  background and join already in sync (a pause also works, no pause is
  cleaner).
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
- P1 A reconnect makes you a new member: the relay, ready, sitting out,
  your queue items and even your avatar are gone (log: Hoff m23 → m24 had
  to put ep 06 up again).
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
- P22 Friends on different versions (D8). (P20 version visible and P21
  update band: fixed in 1.2.1-dev.3; check the band in real use.)
- P23 Solo mode you enter and leave; going hosted loses the queue (D9).
- P24 The invite address list is unhelpful (shows the proxy's 198.18.x).
- P25 ssh to Gitea blocked through the proxy (pushes go over https).
- P27 Failing tests: shell "Ctrl+V outside a field", relay e2e "a guest
  puts up a file", "links: through me".
- P28 Log noise: "Failed to create file cache"; an idle relay channel for
  Jellyfin items everyone has an account for.
- P29 Relay start delay after a seek into an unbuffered part.
- P30 Shaders don't work on Windows. Fix in 1.2.1-dev.3 (list read-back
  check; Windows hwdec `auto-copy`): a Windows user must confirm shaders
  stay on and the EGL-surface error is gone.
- P31 Software rendering on a friend's Linux. 1.2.1-dev.3 logs it
  (`mpv: render` lines); needs that friend's log, plus
  `watch-together 2>&1 | grep VideoOutput` from a terminal if software.
- P32 The app freezes on exit, mostly reported on Windows. 1.2.1-dev.3:
  orderly close, Linux `_exit` (0 crashes in 41 closes vs 10/10 before),
  Windows normal close + TerminateProcess + watchdogs, untested on
  Windows; if it still hangs: Event Viewer 1000/1002, a Task Manager dump,
  the `close:` log lines.
- P33 No volume readout on wheel: likely fixed by the controls rework
  (1.2.1-dev.1; a test covers both skins); confirm in real use.
- P34 Local anime folders are opened as plain files (no banner, names,
  next episode, tracking); test library: the user's
  `/mnt/torrents/Torrents/Binux/` (several shows and a movie).

**Restructure** (in order; reviewed against the code). Truth lives in
three places: the server (members, presence, gate, transport, queue incl.
the automatic continuation and countdown, relay state), the device
(client id, library and folders, match corrections, watch history,
settings, notification prefs, what this app is sourcing) and the
integrations (Jellyfin played/resume, AniList list).
0. Safety net and seams, no visible change: fix P27; an `AppEvent` type;
   platform ports wrapping today's calls (window/shell, open URL,
   notifications, yt-dlp process, folder access, player host);
   Connection extracted from the coordinator; the proto 16 spec written.
1. Connection + Identity + Presence, proto 16 in full (one bump, with a
   min/max version range and a stable refusal frame so later changes are
   additive): a lasting client id; a socket close no longer removes the
   member (explicit `bye`); presence joining/in/away/gone with grace;
   `PresencePolicy` in core used by server and app alike; bounded D2
   hold; relay `sourceGone` and source resume; queue `by` lasting;
   `members[].app`. Fixes P1 P3 P4 P6, server half of P2; D1 D2 D5 D6.
2. Status (one computed level) + Notifier (pure policy over events:
   toasts above the controls, SoundEngine, system notifications, activity
   log). Fixes P8 P11 P12 P21 P33, visible half of P2; D4, D1, D9 alone
   policy ("alone" = no other connected member, In or Away).
3. Your server: one hub, listeners attached (loopback; LAN on Invite),
   nothing restarts; Invite as a value (link/deep link, filtered
   addresses, version gate). Fixes P22 P23 P24; D9.
4. Library + Media identity: L1 local grouping (pure Dart, offline: kinds
   episode/movie/extra, folder hints, gaps, merge across folders) and L2
   match (AniList/TVDB ids, art, names, manual pin, cache); one `MediaRef`
   carried in swap/queue media. Fixes P34 and Files' next episode.
5. What's next (decides which/when, never opens; continuation and
   countdown as server state, shared cancel) + Watch tracking (time In,
   device history, Jellyfin now, AniList later). Fixes P7 P9; D3.
6. Media pipeline + player host port: plan → resolve → open → ready,
   commands queued during a switch, source-drop recovery, resolver and
   source chosen by capability. Fixes P2 (client) P15 P17 P18 P28 P29;
   P30 P31 P32 as a player-host sub-step; D6 client half, D11.
Not in the restructure: P25 (ops).

- P35 Windows friends can't get dev builds (Linux only), so Windows
  fixes wait for a release: add a manual CI run that adds the Windows zip
  to the dev prerelease.

**Agreed since:** the queue stays in memory (no server storage). Auto
sit-out: idle or minimised for a while sets you Away, activity sets you
In; it replaces the 10-minute auto-unready.

**Open decisions:**
- Rooms: one server's users form several watch groups. Not built yet,
  but proto 16 carries a room id: identity per server; presence, queue,
  relay and chat per room.
- Starting together: today someone has to stay unready so others can
  join first. Ideas: a short "starting in 30 s, ready up" countdown;
  waiting for everyone from the last session.
- Transport: `wss://` everywhere, each server with its own self-signed
  certificate whose fingerprint travels in the invite and is pinned
  (no certificate authority needed, works for home and LAN servers and is
  allowed on Android); a trusted certificate optional for a VPS domain.
- Grace length: ~10 min; a source in grace keeps its relay buffer.
- Platform decision: "Desktop + mpv only" becomes "mpv only, desktop
  first" if Android goes ahead.
- D10 was dropped on purpose (preload/warm relay/fresh player are folded
  into step 6, not a separate decision).

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
