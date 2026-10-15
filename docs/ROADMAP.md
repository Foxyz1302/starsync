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
0. Safety net and seams, no visible change. Left: a `noticeFor` table
   test; a flaky-link test harness (pure-Dart TCP proxy: pass, blackhole,
   delay, reset, late frame); grace and silence through
   the engine clock; an env override for client id and data folder (two
   instances on one machine); the scenario list in DEVELOPMENT "Tests".
   (Done: tests audited and tagged, P27, AppEvent + Notifier, ports,
   protocol 16 planned, Connection extracted from the coordinator.)
R. Rename (before step 1, so dev builds install side by side with 1.2.x):
   app id `dev.foxyz.starsync`, binary, Windows company `foxyz`; Hive out
   of `~/Documents` into the app's support folder, copied not moved;
   a settings schema version with ordered migrations; an `AppDirs` port;
   the 1.3.0 archive still contains `watch_together(.exe)` so 1.2.x's
   self-update restart works; the old `.desktop` entry removed; the
   manifest kept at the old URL; VPS `ExecStart`/`update.sh` paths.
1. Connection + Identity + Presence; proto 16 opened (version ranges on
   both sides, refusal frame, identity, grace, presence, relay resume,
   ids in the feed); later steps add fields, it is frozen at the 1.3.0
   release. A drop is not the end of the session: keep the last state
   (marked stale), the player, media and relay source; the UI reads the
   connection state (no update band over a running video, no emptied
   queue, no reopen); reconnect with backoff and jitter; silence 8–10 s
   with "connection unstable" from ~3 s; lost/back sounds only after a
   few seconds of drop. New feed actions mapped one-to-one onto today's
   notices, matched by member id, not name. Presence shown in the strip
   and party UI (joining, away, gone = dimmed "reconnecting"). The relay
   source re-dials on return (client half of D6). Auto sit-out with a
   `ShellPort.watchActivity` (focused/unfocused/minimised/hidden): never
   when alone; while playing only minimised-for-a-while counts; the
   client re-sends its intent after a non-resumed welcome. A joiner holds
   only while not playing, at most ~15 s; while playing never (D2). The
   app close sends `bye` and flushes it; update-and-restart does not.
   `Profile` moves to identity. Fixes P1 P3 P4 P6, server half of P2;
   D1 D2 D5 D6 (source).
2. Status (one computed level, incl. the server's hold reason) + Notifier
   (`noticeFor(event, context)`: self presence, alone, window activity,
   playing, prefs, replayed; owns its toast timer; system notifications
   port; library snack bars moved in). Fixes P8 P11 P12 P21 P33, "source
   left"; D4, D1 notifications, D9 alone policy ("alone" defined once in
   core next to `PresencePolicy`).
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
Tests: many pin behaviour the restructure drops; step 0 audits them
(delete what no longer fits, keep a few scenario tests for the core
flows). Open questions below are decided during the restructure.
How: incremental on `main` (one system extracted per step, every dev
build usable), `signals` plus constructor wiring through one composition
root (no new framework), dev builds `1.3.0-dev.N`, everyone moves to
proto 16 together at the 1.3.0 release. Rooms are out (no room id).
No Windows dev builds: restructure testing happens on Linux; Windows
friends stay on 1.2.x until the 1.3.0 release (Windows-only fixes like
P30 reach them then).
Rename to Starsync everywhere (repo, app id, data folder, updater URL
migration) is its own step; app id `dev.foxyz.starsync`, Windows
company name `foxyz` (replacing Flutter's default `com.example`). Auto
sit-out: idle or minimised for a while sets you Away, activity sets you
In; it replaces the 10-minute auto-unready.

**Open decisions:**
- Starting together: today someone has to stay unready so others can
  join first. Ideas: a short "starting in 30 s, ready up" countdown;
  waiting for everyone from the last session.

- Grace length: ~10 min; a source in grace keeps its relay buffer.
- Platform decision: "Desktop + mpv only" becomes "mpv only, desktop
  first" if Android goes ahead.
- D10 was dropped on purpose (preload/warm relay/fresh player are folded
  into step 6, not a separate decision).

### Protocol 16 (planned)

Lands in step 1, written into PROTOCOL.md then. Tags against proto 15:
**new**, **changed**, **removed**. Rooms are out: one server, no room id.

Versions and refusal:
- `hello.proto` **changed**: the client's version; the server accepts
  `[protoMin, protoMax]` (both 16 at 1.3.0; later additions raise
  `protoMax` only, so they stay additive). `welcome.proto` **new**: the
  version used on this connection.
- Refusal **changed**, stable from 16 on: `{"t":"err","code":"version",
  "min":16,"max":16,"server":"1.3.0","message":"proto mismatch: got 15,
  want 16..16"}`, then close (a proto 15 app shows `message`). Every
  `err` gets `code` **new**: `version`, `secret`, `rejected`, `bad`,
  `replaced`.
- `/health`: `protoMin`, `protoMax`, `tls` **new** (`proto` = `protoMax`).

Handshake:
- `hello.client` **new**: a random id per install (22 characters
  base64url), private: never broadcast.
- `hello.app` (`"1.3.0"`), `hello.platform` (`linux`, `windows`,
  `android`), `hello.caps` **new**: what this app can do (`source`: serve
  a relay; `resolve`: run yt-dlp; `jellyfin`: play with its own
  account); unknown entries ignored.
- `hello.resume` **removed** (the client id replaces it); `hello.media`
  **removed** (unused).
- `members[].app` **new**: the member's `hello.app`.

Lasting member:
- The server maps `client` to one member. A new socket with a known
  client id takes that member over (`memberId` and `token` unchanged, so
  `/m` `/r` `/j` URLs keep working); the older socket gets `err`
  `replaced` and closes. `welcome.resumed` **new**: true when it did.
- A socket close no longer removes the member **changed**: it goes
  `gone` and is kept for the grace period (~10 min, `welcome.grace`
  **new**, seconds) with its ready flag, presence, queue items and
  relay. After the grace it leaves (feed `leave`).
- `{"t":"bye"}` **new**: leave now (Leave button, app close).

Presence:
- `members[].presence` **new**: `joining` | `in` | `away` | `gone`;
  `members[].goneSince` **new** (ISO, only while `gone`).
  `members[].out` and `members[].stale` **removed** (`away`; a silent
  socket is closed and its member is `gone`).
- `{"t":"presence","target":"<memberId>","state":"away"|"in"}` **new**,
  replaces `out` **removed**: anyone sets someone `away`; only the member
  itself goes back `in`.
- Feed **changed**: `away` (was `out`), `in` (was `back`), `gone` (was
  `stale`), `return` **new** (back within the grace: no `join`), `leave`
  (after the grace or `bye`), `join` (new members only).
- Gate (one `PresencePolicy` in core, used by server and app): only `in`
  counts for the gate, the ready counter and watched tracking; `away` and
  `gone` never. A joiner is `joining` until its report holds the current
  media with `bufferNeed` at the current position, then `in`. While
  `playing` a joiner never holds (D2): it loads in the background and
  comes in already in sync. While held it is in the set like a fresh
  member today, for at most ~15 s, then out of the set until `in`. A
  returning member (`gone` → back within grace) is `joining` again with
  its ready flag kept, treated like a joiner; an `away` one stays
  `away`.

Relay (D6):
- `media.relay.sourceGone` **new**: true while the source member is
  `gone`. The relay and its buffer stay; viewers play what is buffered.
- Source resume **changed**: the source's close no longer ends the relay;
  only its leave (grace over, `bye`) or a swap does. Back in the grace,
  it dials `/r/<sid>/<token>/source` again; an `info` equal to the first
  continues (pulls restart from the first byte or piece not buffered, new
  pull ids), a different one ends the relay (close 4002 **new**).

Queue and what's next:
- `queue[].by` **changed**: lasting (the member id survives reconnects);
  a `through`/`file` item of a `gone` adder waits instead of being
  skipped, until its adder leaves.
- `queue[].auto` **new**: the continuation (next episode): `add` with
  `auto:true`; at most one, after the others, replaced by a newer one,
  dropped by a swap to something else.
- `state.advance` **new**: `{"id":"q3","at":"<server time>","secs":10}`,
  the shared countdown when the media finishes and an item is first; at
  `at` + `secs` the server sets `queuePlay` to it.
  `{"t":"queue","op":"cancel"}` **new** clears it for everyone (feed
  `advance-cancel` **new**).

Media identity:
- `media.ref` **new**, in `swap.media`, `state.media` and
  `queue[].media`: `{"kind":"episode"|"movie"|"extra","ids":{"anilist":1,
  "tvdb":2},"show":"...","season":1,"episode":6}` (MediaRef); passed
  through as is, at most 2 KiB.

Transport: paths unchanged. A server with TLS serves the same endpoints
over `wss://`/`https://` (`/health.tls`); apps use `wss://` when offered,
`ws://` stays allowed.

**Protocol 16 additions (second review):**
- Client range too: `hello.protoMin`/`proto`; the server picks the
  highest common version; read `proto` before strict hello parsing; 16
  apps still send `hello.media:{}` so a 15 server answers "proto
  mismatch"; a 16 app shows a 15 refusal as "the host runs an older
  Starsync".
- Ordered takeover: `hello.seq` (monotonic per client), older hellos get
  `err stale`; `replaced` is terminal on the client ("opened in another
  window"); `welcome.instance` per server boot (grace expired vs server
  restarted).
- Error codes `stale`, `forbidden`, `rate`, `full`, plus `err.for`; close
  codes listed in one place. `/health.version` (no member names).
- Silence: no frame for ~15 s closes the socket (member `gone`); the
  `gone` feed line only after ~10 s gone (a quick return emits nothing);
  `presence.reason` manual/idle/minimised/bye; away → in while playing
  goes through `joining`; `joining` ends on a report error or timeout; a
  second `/source` socket for the same token replaces the first.
- Feed: `actorId`/`targetId`; `feed.seq` with `hello.feedAfter` and a
  bounded replay in `welcome` (marked `replayed`: logged, not toasted).
- `state.hold {reason ready|buffer|joining|source|start, members, until}`;
  `members[].caps`.
- Relay: `sourceGoneSince`; "same info" = size, duration, tracks, name.
- Queue: `auto` items carry `for: <mediaId>`, added only by the current
  swapper (or first in); `advance` holds while its performer or source is
  gone; `cancel` drops the `auto` item too.
- `MediaRef` gains `absolute`; `season` may be null.
- `client` is redacted from every log; optionally derived per server
  (HMAC of an install secret and the dialled host:port).
- wss: only with a CA-valid certificate in 1.3.0; pinned self-signed via
  the Invite `fp` later.

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
