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
- P25 ssh to Gitea blocked through the proxy (pushes go over https).
- P30 Shaders don't work on Windows. Fix in 1.2.1-dev.3 (list read-back
  check; Windows hwdec `auto-copy`): a Windows user must confirm shaders
  stay on and the EGL-surface error is gone.
- P31 Software rendering on a friend's Linux. 1.2.1-dev.3 logs it
  (`mpv: render` lines); needs that friend's log, plus
  `starsync 2>&1 | grep VideoOutput` from a terminal if software.
- P32 The app freezes on exit, mostly reported on Windows. 1.2.1-dev.3:
  orderly close, Linux `_exit` (0 crashes in 41 closes vs 10/10 before),
  Windows normal close + TerminateProcess + watchdogs; the player host
  now owns the disposal order. CI's Windows job runs a close smoke run on
  every build (`tool/smoke_windows.ps1`); its first runs on the runner
  must show whether it passes or skips there (no interactive desktop). If
  a real close still hangs: Event Viewer 1000/1002, a Task Manager dump,
  the `close:` log lines.
- P33 No volume readout on wheel: likely fixed by the controls rework
  (1.2.1-dev.1; a test covers both skins); confirm in real use.

**Restructure** (in order; reviewed against the code). Truth lives in
three places: the server (members, presence, gate, transport, queue incl.
the automatic continuation and countdown, relay state), the device
(client id, library and folders, match corrections, watch history,
settings, notification prefs, what this app is sourcing) and the
integrations (Jellyfin played/resume, AniList list).
Released as 1.3.0. Left: check that a 1.2.x app gets a clear "update
the app" message and updates (Windows: the first real use, backlog 5).
Composition root (in place, ARCHITECTURE "Composition root"): the
remaining `.instance` singletons move into `AppGraph` as the steps touch
them; `singletons_test` holds the count (today: AppSettings 49,
JellyfinAccounts 10, UpdateController 8, Profile 8, FolderStore 6,
AppYtDlp 2, RecentLinks 3).
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
Together" (devices are listed under it) and `WatchTogetherApp`.
Left of step 1: Update and restart keeps the member `gone` for the
restarted app, but the app starts on Home (it does not rejoin by itself)
and does not remember what it was passing on, so a relay it served ends
with its grace unless it is put up again; worth doing only if updates
ever happen mid-session (D8 says never during playback).
Left of step 3 (your server): a human check of Invite (Linux and, at
1.3.0, Windows' firewall prompt, now on Invite rather than at start;
that the invite skips the proxy's 198.18.x here) and of the update band
from 1.2.1-dev.3 in real use. No UPnP: the members card says when
friends elsewhere need the port forwarded. Human checks of the
`starsync://` links: clicked in a browser and in Discord on KDE Wayland,
X11 and Windows (the window coming to the front, the registry key after
first start and after an update from a `watch_together.exe` copy). Your
server's `/health` name is the profile name at start (a rename shows
after a restart). Joining a friend while others are on
your server leaves them there without you, unwarned; a join refused
after dialling (wrong password) costs your own member there (`bye`, back
as a new member). Your server writes its session log even when you are
alone.
Left of step 6 (what's next, watch tracking): a human check, on Linux
now, of the server's countdown and the end card in real use (Cancel
from another screen, a seek stopping it, "Waiting for" while the one who
puts it up is gone), of a file continuation on the real folder (Bleach
"skips 66–107" across its folders, SAO S3 into its OP/ED folder, the
last episode of a show) and of Jellyfin's played state and resume point
under time In against a real Jellyfin (a full watch, one sat out, a
resume), and of a dev server restarted mid-episode (what played comes
back where it was for everyone, a Jellyfin item passed on to a guest
re-fed: only files and links are covered by tests). Not built: AniList
progress (the tracker's `records` are its seam); nothing resumes a file
or link at the history's resume point (it only keeps it); no watched
marks on Files' episode rows (only "Next" follows the history) and no
way to see or clear the history. The continuation of a file comes only
from the app that put it up (only it has the file). "Play the next episode
automatically" is the setting of whoever puts an episode up; Up next's
own items count down whatever it says. A play request the performer
does not act on ends after 30 s without a new countdown for that item
(Play now remains). A warm relay waiting for a `gone` source holds the
countdown even when the one who puts the item up is there. After a
server restart, a relayed file or link whose member is not back, or a
Jellyfin item nobody back has an account for, cannot be put back (the
apps let go after 30 s); a server-fetched Up next item is lost (its
address stayed with the old server).
Left of step 5 (media pipeline): a human check, on Linux now and on
Windows at 1.3.0, of a page link in "Everyone fetches it" through the
app's own resolve (YouTube's 1080p video + audio EDL, Bilibili with its
Referer and cookies, X's HLS) and of its subtitles, and of the D11 text
with browser cookies (Bilibili without a login there); a relay viewer
during a real source drop (the bytes run out, "Waiting for <name>", the
return); the first Windows CI runs of the close smoke step. Not built:
a viewer cannot tell what the server's relay buffer holds, so a seek
past its own mpv buffer while the source is away is tried once and then
waits for the source even when the server had it; `Unresolvable` (a
device without yt-dlp) only says who could pass the link on, nothing
routes it there by itself (Android); a page's stream URLs come from the
probe cache (10 minutes, 35 for Up next's first item) and are resolved
again only at Reload video and the 30-minute refresh; a format whose
CDN wants per-track headers that differ gets the first track's (as
mpv's hook did); Bilibili's danmaku is dropped, not shown. The Jellyfin
item this member put up re-feeds its relay after an app restart (the
state still names it the source).
Relay start (P29's rest): a seek into what the source has not sent
plays after about 2.8 s in the e2e; a human check of a real session
on dev.8+. The source's in-flight window still starts at 256 KiB and
grows with the measured rate, so the speed climbs from low after a
seek or a new link; the start of a freshly put-up link was never
measured on its own. Levers if it still shows: start the window from
the last rate, prefetch from the source as soon as a link goes up,
a smaller gate buffer when only the relay is behind.
Left of the read-once source (ARCHITECTURE "Relay", "Read once"): a
human check against real Bilibili and YouTube (the 412 storm gone, the
putter's picture the relay's format, a Windows putter's loopback), and
the source's first frame and seeks over a 12 Mbit/s uplink
(`tool/shaper`): a putter whose upload lags now holds its own player
about 64 MiB past it. Not built: pieces tracks (HLS/DASH, X's) are
still fetched twice (the putter's player from the site, the relay's
pieces on their own; the same idea needs a `PieceBuffer` and a loopback
playlist); Jellyfin items a member passes on are still streamed twice
when the relay is needed. The e2e's media (26 MiB) fits the putter's
buffer whole, so the 64 + 16 MiB bound is only unit-tested.
Left of step 4 (library): a human check of the Files library on the
real folder (`/mnt/torrents/Torrents/Binux/`: Bleach over three folders
with 66–107 missing, SAO S3 Alicization with OP/ED, Re.Zero S04E17, the
Kimetsu movie) and of the AniList matches it gets. A Jellyfin swap
carries AniList/TVDB ids only when the picked item has them (movies); an
episode's show ids need its series item, which picks do not fetch.
Receivers name the media by `media.ref` but still get art only as the
swapper's bytes (now chosen by the ref's AniList id). Relay logins are
sent at Invite: an account linked or signed in again later relays only
after Stop sharing and Invite. "Season N" without a name walks AniList's
sequels, which can land on the wrong cour where AniList splits seasons;
Wrong show? fixes it. The `library` box keeps every AniList entry seen (no pruning);
AniList's episode titles exist only where it lists streaming episodes.
Left of step 2: system notifications need a human check (Linux: the
notification shows and a click brings the window up, also on Wayland,
where focus may be refused without an activation token; Windows: toasts
from an unpackaged install, at 1.3.0). On Linux the notification carries
no `desktop-entry` hint (flutter_local_notifications_linux does not
export its hint types), so a shell may name it "starsync" from the
bundle rather than "Starsync".

**Open decisions:**
- Platform decision: "Desktop + mpv only" becomes "mpv only, desktop
  first" if Android goes ahead.
- D10 was dropped on purpose (preload/warm relay/fresh player are folded
  into step 6, not a separate decision).

### Protocol 16 (open parts)

Opened in step 1: [PROTOCOL.md](PROTOCOL.md) is proto 16 (version
ranges and the refusal frame, error codes and close codes, lasting members by client id with takeover and `seq`, grace and
`bye`, presence and `PresencePolicy`, `state.hold`, feed ids, `seq` and
replay, relay `sourceGone` and source resume, lasting `queue[].by`,
`auto` items, `cancel` and `state.advance`, `media.ref`, `members[].app`/`caps`), server,
core and app. Still open on the wire, frozen at the 1.3.0 release:
- `hello.client` optionally derived per server (HMAC of an install
  secret and the dialled host:port).
- TLS: `/health.tls` is always false; `wss://` only with a CA-valid
  certificate in 1.3.0, pinned self-signed via the Invite `fp` later.
- `err` code `rate`: reserved, nothing sends it.

## Backlog

Next: **Playback and presence** (epic, below; protocol 17).

0. **Move to the owner's media_kit fork** (for 1.5.0):
   `Foxyz1302/media-kit`, branch `integration` (a local checkout sits
   beside this repo as `../media-kit`). Replacing the
   vendored `third_party/media_kit_video` brings:
   - the non-blocking Linux render (`BLOCK_FOR_TARGET_TIME=0`, also in
     the software path) with `video-timing-offset` 0.02 unless the app
     set one. Measured at 75 Hz: late UI frames over a video drop from
     2764/2947 to 1/3681; audio-pts against time-pos goes from −23 ms to
     +2 ms;
   - the Linux teardown fixes (a per-texture lock, deferred unref, the
     SEGV);
   - the texture-name-context and VideoController first-frame fixes,
     which make our `starsync/` patches for them unnecessary;
   - render at widget size (`renderAtWidgetSize`, `setViewSize`), which
     can replace Sharp video's own sizing;
   - the Windows plugin rendering on its own thread, publish-under-lock,
     the normalizeURI fix and the teardown ordering. Windows crashes about
     once per 5–6 opens or switches in the shared logs (bundled libmpv 0.36,
     ANGLE/D3D11, d3d11va-copy), with "Failed to create EGL surface" at
     every player creation.

   Check when switching:
   - which `starsync/*.patch` are already in the fork;
   - our hwdec and cache option pinning;
   - the glsl-shaders read-back compared as a list;
   - the newer Windows libmpv only needs `tls-verify=no`.

   Also bisect the 44–46 dropped video frames in a 60 s Starsync run,
   which the fork's player alone does not show (1 drop). Suspects:
   shaders, Sharp video's resizes, Up next preload, the relay stream.

   The rest of this entry is the earlier evaluation of other forks. Upstream
   media-kit releases stalled at media_kit_video 2.0.1 (Dec 2025) though
   main still gets fixes; `Predidit/media-kit` is active (138 ahead, 146
   behind upstream) with native D3D11 on Windows (no ANGLE: may fix P30
   and the dxva2-egl error), a bundled libmpv on Linux, triple-buffered
   Linux rendering, patched FFmpeg. Check: Windows shaders, whether its
   it plays `edl://` URLs with `http-header-fields` (pages resolve in
   the app since step 5, so mpv's Lua and ytdl_hook are not needed), offline
   CI builds (it downloads binaries in a build hook), and the upstream
   fixes it lacks. Until then we vendor upstream 2.0.1 with the X11/EGL
   patch in `third_party/media_kit_video`.
   Upstream isn't merging outside work (20 open PRs, no release since
   Dec 2025): no upstream PRs. Independent of the fork: the Windows
   libmpv is a 2023 build fetched by `media_kit_libs_windows_video`;
   vendoring that package with a current mpv-dev build (and checksum)
   updates Windows' mpv on its own.

1. **Auto-skip OP/ED** (undecided): who decides and how (shared for the
   server, personal, per show) is open. Constraint: a skip is a seek and
   seeks are shared, and only real ranges (segments, OP/ED chapters) should
   ever be skipped. Detection is the harder half: OPs and EDs are often not
   named (chapters "1"–"5"); a ~1:30 chapter near the start or end of a
   20+ minute episode is a strong hint, and audio fingerprinting across a
   show's episodes (the same song at the same spot) finds them without
   chapters.

2. **yt-dlp follow-ups** (see ARCHITECTURE "yt-dlp"): check that the
   bundled Windows libmpv plays the app's `edl://` URLs (video + audio
   with headers) through media_kit. YouTube: yt-dlp wants a JS runtime
   (deno) for full extraction.
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

3. **AniList account**: sign in (OAuth via a localhost callback), "My list"
   filter on the Schedule from the user's AniList lists. This is the
   Schedule's personal tracking; AnimeFlow has no per-user follow.
   **AniList browser** (wanted next once 1.3.0 holds up): view shows and
   browse older ones (search, seasons, details), and request one from
   there on AnimeFlow; later on Sonarr too, which is what a public
   release of the app would use. Browse ALL anime (not only what the
   Schedule airs), so older finished shows can be requested. A full anime
   page (cover, synopsis, episodes, relations, studios, where it is on
   Jellyfin/Files) opened from anywhere a show appears, e.g. a Schedule
   entry. With the account: track progress on AniList, and carry over
   what Jellyfin already has as watched.

4. **Ops**: Check shaders on Windows; run the relay e2e "the source drops
   uncleanly and comes back" a few times under the full suite (its
   predecessor failed about half the time there).

5. **Windows: first real use.** Check the update away from 1.4.x: an
   install started as `watch_together.exe` restarts `starsync.exe`, and
   its first update check removes `watch_together.exe` and
   `watch-together-server.exe`. CI builds and publishes
   `starsync-<ver>-windows-x64.zip` (libmpv bundled) and runs the
   updater tests on NTFS; a friend has joined from it. Still unchecked:
   fullscreen controls, hosting (firewall prompt), in-app update from one
   release to the next. The rest of the desktop tests are not in CI.

6. **Relay follow-ups** (see ARCHITECTURE "Relay"). First real use: owner's
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

7. **Tray** (like Discord): close to the tray instead of quitting, so
   the app stays on the server and its system notifications keep coming;
   a tray menu (Open, Quit; maybe Leave the server). Quit stays the
   orderly shutdown (P32). Linux trays vary (StatusNotifierItem; GNOME
   shows none without an extension), so close-to-tray needs a fallback
   to quitting where no tray exists.

8. **Hosting without a VPS** (friends host from their own connection,
   on their own bandwidth; a tunnel through the VPS is out: everyone's
   traffic would land on it). In order: IPv6 (try a public IPv6 address
   first, no NAT); UPnP / NAT-PMP port opening later; hole punching
   (the VPS only introduces the two sides) only as a research spike: it
   needs UDP (WebRTC or QUIC) under the sync connection, a local HTTP
   stand-in so mpv can read relayed video, and still fails behind CGNAT
   and symmetric NAT. Also: an invite with a generated access code
   instead of the password (`starsync://host:port/<code>`, a "New link"
   button revokes old links; the server accepts code or password).

9. **Jellyfin** (epic, below).

10. **Screenshots** (wanted): catch the frame in the moment, playing
   or paused, in full quality straight from mpv (`player.screenshot`,
   the video's own resolution; the app's overlays are never in it), with
   or without subtitles. Print Screen belongs to the desktop (KDE,
   Windows), so it gets the app's own key: `s` as in mpv. One press saves
   (show, episode and time in the name) and copies to the clipboard, and
   a small toast with the picture offers Edit: the same frame with and
   without subtitles (both caught at the press, so the toggle is
   instant) and a crop. Check whether upscaling shaders can be in the
   capture through media_kit's renderer; if not, the capture is the
   source resolution.

11. **Folder as a playlist**: put up a whole folder of videos (a
   collection without a show behind it) as a transient playlist, like a
   Jellyfin show: one after another with Up next's countdown, nothing
   saved.

12. **Smaller items**
   - Linux frames are capped at 60 Hz whatever the monitor runs at: the
     GTK embedder gives the engine no vsync source (a fixed 1/60 s
     fallback, flutter/flutter#191245) and GTK3's GL window gets no
     presentation feedback on Wayland. A runner shim paces frames to the
     compositor through private Flutter and GTK structures, hands mouse
     motion over once per frame (Flutter 3.48's task runner falls behind
     a 1000 Hz mouse) and skips GTK's background paint in fullscreen.
     It goes in with the fork move (backlog 0): without the fork's
     non-blocking render, the UI over a video drops to the video's rate.
     Before that: a fullscreen check on a real display with
     `STARSYNC_FRAME_PACING_LOG=1`. Mouse drags may still feel
     sampled at 60 Hz with it (being researched).
   - One open made two session players (#1 and #2) in a diagnostics
     test run: find out why.
   - The video freeze after GPU idle: next suspect is media_kit's context
     switching on the raster thread with NVIDIA.
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

## Epic: Playback and presence

Replaces the ready system, every timeout that can start playback, and D1's
presence. The app waits only for what it can measure (someone's video) and
for what people say on purpose (BRB); nothing starts because time passed.
Protocol 17: everyone updates together. The gestures are tried first in a
test page.

**People** (one state each; Loading and Reconnecting are only labels):
- **Watching**: no badge. The group waits only for their video.
- **BRB**: set on purpose; the group waits until they are back or someone
  continues without them. Never runs out. Kept across a dropped connection
  (while the seat is kept), an app restart, a new video and a server
  restart (the app reports it again). A BRB member who leaves for good
  leaves a plain pause; it never plays by itself.
- **AFK**: Out, set automatically: no input for about 10 minutes while
  nothing plays (plain pause, end card, nothing on). Never set during
  playback or on a BRB member. Only the badge differs, so others see why.
  Any input brings them back, joining at the current moment.
- **Out** (name not final): left out by "continue without", chosen in the
  radial, player closed, or the window minimised 10 minutes while it plays.
  Not waited for, not counted as watched; the player stays at their spot;
  Space or Join puts them at the current moment. Never stops them passing
  the video on.

**The group** is playing, paused, or "Waiting for …" (someone's BRB, or
someone's video loading or running dry). Play and pause are anyone's. A
BRB only holds the group back: when the last one is back it plays if it
was playing when the first BRB began, otherwise it stays paused. A pause lasts
until someone plays. Putting something up keeps play or pause, so the
start of an evening waits for one Play and nobody has to hold it.

**Keys and clicks:**
- Space tap: play or pause. Hold about 0.6 s: BRB (the pause happens on
  key-down; key repeat ignored).
- While anyone is BRB, a tap toggles your own BRB (back, or BRB too); a
  hold of about 2 s continues without them and plays. The pill's hint
  line says so ("Space: BRB too · Hold: continue without").
- A hold fills the pill itself, fading in so a tap barely shows, and the
  pill says what keeping on does ("Keep holding: BRB").
- Continue without a BRB member makes them Out; continue without
  someone's video leaves them Watching to catch up.
- Right-click hold on the video: a radial (BRB or I'm back, Out, Next
  episode during the ending). A plain right-click leaves it open for a
  click.

**Drops and catching up:** a dropped connection never pauses (as now).
Anyone who comes back behind the group (a stalled stream, an app crash,
being left out) gives everyone "Rewind for Alice (1:42)" for about 30 s.

**End of an episode:** a "Next episode" button through the ending (the ED
chapter, or the last 90 s). Up next counts down over the last 10 s and the
next item starts the moment this one ends; the next item starts loading
when the countdown appears. Videos under a minute show only "Up next".
Pause or Cancel stops it at the end. The silent stop when the performer
does not act on a play request asks again (another member if needed).

**Also:** "Wait for Bob" on a person card: a friend sets someone's BRB
when they ran off without it; their own tap clears it.

**Undecided:** the name "Out" (fits next to BRB and AFK, but may not be
clear enough).

**Goes away:** ready and unready and the ready counter, Mark everyone ready,
Force ready (becomes "Don't wait for Alice"), Space as ready, the 15 s
joiner bound, the 60 s joining flip, the 5-minute idle sit-out.

## Epic: Jellyfin

What is left (the rest is in [ARCHITECTURE.md](ARCHITECTURE.md), "Jellyfin
in a session"):
- Sidecar (external) subtitle streams of Jellyfin items: only embedded
  tracks are mapped to mpv today.

## Deferred

P2P, Android. Never: transcoding, web clients.
