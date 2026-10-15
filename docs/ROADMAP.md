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
- P2 Viewers of a relay whose source is gone: mpv loops on failed seeks
  past what the server buffered (viewer-side recovery, step 5).
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
2. Status (one computed level, incl. the server's hold reason) + Notifier
   (`noticeFor(event, context)`: self presence, alone, window activity,
   playing, prefs, replayed; owns its toast timer; system notifications
   port; library snack bars moved in). Fixes P8 P11 P12 P21 P33, "source
   left"; D4, D1 notifications, D9 alone policy (`isAlone` in core). Step 1
   left over for it: the presence notices are today's (sat you out, a
   toast when auto sit-out sets you away, lost signal and return only in
   the activity log); a replayed feed only logs.
3. Your server: one hub, listeners attached and detached without members
   reconnecting (old isolate path kept until that's proven); Invite as a
   value (filtered addresses, version gate from `/health.version`, an `fp`
   field reserved for pinned certificates later); `SessionState` is
   deleted here. Fixes P22 P23 P24; D9.
4. Library + Media identity: L1 local grouping (kinds, folder hints,
   gaps, merge across folders) and L2 match (AniList/TVDB, art, names,
   manual pin, cache); `MediaRef` in swap/queue media. Fixes P34.
5. Media pipeline + player host port: plan → resolve → open → ready,
   commands queued during a switch, viewer-side recovery when a source
   drops (no mpv seek loops, play what's buffered), resolver and source
   chosen by capability; a Windows CI smoke job (start, open, close
   within N s, no orphan process). Fixes P2 P15 P17 P18 P28 P29, P30–P32;
   D11.
6. What's next (decides which/when, asks the pipeline to prepare;
   continuation and countdown as server state, shared cancel) + Watch
   tracking (time In from the presence history, device history, Jellyfin
   now, AniList later). Fixes P7 P9; D3.
7. Release 1.3.0: publish the manifest (protocol 16 makes it a required
   update for 1.2.x) and update the VPS dedicated server in the same
   window; check a 1.2.x app gets a clear "update the app" message.
Composition root: an `AppGraph` built in `main.dart` only constructs and
disposes systems (no logic, no signals); systems get dependencies through
constructors, widgets through one `AppScope`; a test fails if the count
of `.instance` singletons grows (today: SessionState 94, AppSettings 51,
JellyfinAccounts 10, Profile 7).
Not in the restructure: P25 (ops).


**Agreed since:** the queue stays in memory (no server storage).
Transport: `wss://` preferred when a server offers it, `ws://` still
allowed (a cleartext exception on Android); it only carries sync.
Tests: many pin behaviour the restructure drops; each is tagged with the
step that rewrites it, and the safety-net scenarios (DEVELOPMENT "Tests")
must keep passing through every step. Open questions below are decided during the restructure.
How: incremental on `main` (one system extracted per step, every dev
build usable), `signals` plus constructor wiring through one composition
root (no new framework), dev builds `1.3.0-dev.N`, everyone moves to
proto 16 together at the 1.3.0 release. Rooms are out (no room id).
No Windows dev builds: restructure testing happens on Linux; Windows
friends stay on 1.2.x until the 1.3.0 release (Windows-only fixes like
P30 reach them then).
Left of the rename (app, binaries, archives and data folder are
Starsync): the repository (`Foxyz/sync_replay_project`) and with it the
manifest and asset URLs (a new manifest URL needs a release that reads
both first); the dedicated server's fallback folder
`~/.cache/watch-together`, the release token file
`~/.config/watch-together-release-token`, Jellyfin's client name "Watch
Together" (devices are listed under it) and `WatchTogetherApp`; dropping
the 1.2.x launchers from the archive once nobody updates from 1.2.x.
Left of step 1: Update and restart keeps the member `gone` for the
restarted app, but the app starts on Home (it does not rejoin by itself)
and does not remember what it was passing on, so a relay it served ends
with its grace unless it is put up again; worth doing only if updates
ever happen mid-session (D8 says never during playback).

**Open decisions:**
- Starting together: today someone has to stay unready so others can
  join first. Ideas: a short "starting in 30 s, ready up" countdown;
  waiting for everyone from the last session.

- Platform decision: "Desktop + mpv only" becomes "mpv only, desktop
  first" if Android goes ahead.
- D10 was dropped on purpose (preload/warm relay/fresh player are folded
  into step 6, not a separate decision).

### Protocol 16 (open parts)

Opened in step 1: [PROTOCOL.md](PROTOCOL.md) is proto 16 (version
ranges and the refusal frame, error codes and close codes, lasting members by client id with takeover and `seq`, grace and
`bye`, presence and `PresencePolicy`, `state.hold`, feed ids, `seq` and
replay, relay `sourceGone` and source resume, lasting `queue[].by`,
`auto` items and `cancel`, `media.ref`, `members[].app`/`caps`), server,
core and app. Still open on the wire, frozen at the 1.3.0 release:
- `state.advance` (step 6): the server starts the countdown when the
  media finishes and an item is first, sets `queuePlay` at its end and
  holds it while the item's performer or source is `gone`. Today it is
  parsed and broadcast but never started; `auto` items and `cancel` are
  live.
- `media.ref` producers (step 4); the server carries it already.
- `hello.client` optionally derived per server (HMAC of an install
  secret and the dialled host:port).
- TLS: `/health.tls` is always false; `wss://` only with a CA-valid
  certificate in 1.3.0, pinned self-signed via the Invite `fp` later.
- `err` code `rate`: reserved, nothing sends it.

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

5. **Ops**: Check shaders on Windows; run the relay e2e "the source drops
   uncleanly and comes back" a few times under the full suite (its
   predecessor failed about half the time there).

6. **Windows: first real use.** Check the rename at 1.3.0: a 1.2.x
   install updates and restarts (`watch_together.exe`, a copy of
   `starsync.exe`), the data in `%APPDATA%\foxyz\Starsync` came over from
   `%APPDATA%\com.example\watch_together` and Documents, the next update
   restarts `starsync.exe`. CI builds and publishes
   `starsync-<ver>-windows-x64.zip` (libmpv bundled) and runs the
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
   - Up next follow-ups (see ARCHITECTURE "Up next"): a whole season or
     a pick list at once ("Add the rest of the season").
   - Sidecar subtitles.

## Epic: Jellyfin

What is left (the rest is in [ARCHITECTURE.md](ARCHITECTURE.md), "Jellyfin
in a session"):
- Auto-advance cancel for everyone (the next episode and Up next): today
  Cancel is per screen (the designated swapper's Cancel stops the swap; a
  seek stops all). The wire has it (`queue` `cancel`, `state.advance`);
  the app uses it in step 6.
- Sidecar (external) subtitle streams of Jellyfin items: only embedded
  tracks are mapped to mpv today.

## Deferred

P2P, Android. Never: transcoding, web clients.
