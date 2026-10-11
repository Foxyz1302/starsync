# Architecture

Plain overview first: [HOW-IT-WORKS.md](HOW-IT-WORKS.md). Wire format:
[PROTOCOL.md](PROTOCOL.md). Plans: [ROADMAP.md](ROADMAP.md).

## Packages

| Path | What | Rule |
|---|---|---|
| `packages/core` | protocol messages, sync engine (`SyncEngine`), constants, config, Range parsing, logging, Jellyfin client, updater, watched rule (`WatchSession`) | pure Dart, no Flutter |
| `packages/server` | Relic HTTP + WebSocket server (`SyncServer`, `ServerHub`, `Session`, media endpoint, relay buffer, Jellyfin relay), the `serve()` entrypoint, `bin/server.dart` (dedicated server) | pure Dart, no Flutter |
| `apps/desktop` | Flutter app: UI, `SyncClient`, `SessionCoordinator`, `PlaybackController` (media_kit/mpv), `ServerIsolate`, update UI (`UpdateController`) | ships with `watch-together-server` |
| `tool` | harnesses: `range_logger`, `shaper`, `fake_viewer`, `e2e_check` | dev only |
| `deploy` | systemd unit for the dedicated server | |

Guard: `packages/core/test/flutter_free_test.dart` fails if anything under
`core/lib` imports Flutter, `dart:ui` or `signals_flutter`; CI runs
analyze + tests for core and server on every push. Server has no such test but
the same rule; CI checks it with `dart compile exe` of `bin/server.dart`. The client
WebSocket (`web_socket_channel`) lives in `apps/desktop`; Relic has no client.

## Server lifecycle

One entrypoint: `serve(config, events:)` in `packages/server`. `config` is
an `AppConfig.toMap()` (primitives only, so it crosses isolates). It starts a
`SyncServer` (bound to all IPv4 interfaces) and reports on the `events` port:
`ready` (with the port and a `stop` SendPort), `error` (start failed), and
every log record as `log`. Sending `{'t':'stop'}` to the `stop` port closes
all sockets and returns, and the isolate exits. `{'t':'file', 'path', 'reply'}`
on the same port makes a local file the hosted one and answers its name and
size (`ServerIsolate.setFile`): the host's in-session File swap then sends a
`swap` with that name and size, which the server matches to the file.

- **Hosting from the app**: `SessionState.host()` spawns an isolate running
  `serve` (`ServerIsolate`), waits for `ready`, then joins it over
  `127.0.0.1` like any other client. Server logs go to the app's log with a
  `[server]` prefix. The isolate runs with `errorsAreFatal: false`: an
  uncaught async error is logged and the server keeps going. If the isolate
  dies anyway, the session shows "server crashed: ..." and leaves; the
  shell says so in a dialog (during setup the host attempt fails with it).
  Stop (leave, close, cancel during setup, a failed own join)
  sends `stop`, waits up to 3 s for exit, then kills the isolate.
- **Solo session** (watching alone): the same hosting path, so nothing
  about solo is a second code path or on the wire. Putting something up
  while offline (`AppShellState._putUp`) calls `SessionState.startSolo`:
  a `ServerIsolate` with `loopbackOnly` (an extra `'loopbackOnly': true`
  key next to the `AppConfig` map; `SyncServer` binds 127.0.0.1 instead
  of every IPv4 interface), port 0 (a free one), no password, a host key;
  the app joins it and `SessionState.solo` is set. Everything a session
  has works (Jellyfin progress, next episode, skip pills, the player); a
  link goes up direct (no relay mode). Invite friends opens the Host card,
  whose submit (`SessionState.host` while solo) remembers the
  coordinator's `lastPick` (the last `swapLink` / `swapJellyfin` /
  `swapFile` of this connection) and position, leaves and stops the solo
  server, hosts on the card's port and password, swaps the same pick and
  seeks once a state shows it (`switching` is set meanwhile; the shell
  closes the player and reopens it as it was). If hosting fails or is
  cancelled, solo starts again with the same media. Stop leaves without
  asking.
- **Dedicated server**: `bin/server.dart` compiled with `dart compile exe`
  and shipped next to the app as `watch-together-server`. It parses flags
  (`--port`, `--secret`, `--name`, `--media`, `--advertise-host`,
  `--jellyfin <file>`, `--[no-]yt-dlp`, `--yt-dlp-dir`, `--yt-dlp-cookies`, `--config`; default port 8080) into the same map and calls `serve`
  (`--upgrade` / `--check-update` run the [updater](#updater) instead);
  SIGINT and SIGTERM stop it. A Flutter binary cannot run without a
  display, which is why the server is its own build.

`SyncServer` runs a 1 s heartbeat: stale sweep, closed-socket sweep, silent
socket drop, state + feed broadcast. There is one session, id `default`.

Passwords: the default secret is empty, which means an open server (a
warning is logged). Otherwise one shared secret, compared at hello.

Host: when hosting, the app generates a random `hostKey` per hosting, puts
it in the server config and sends it in its own `hello`. The member whose
key matches is the host (`members[].host`: the crown, art rights). The
address a connection comes from plays no part (so a reverse proxy or tunnel
on the same machine does not make everyone the host). The dedicated server
has no key, so it has no host. Nobody removes anyone: members sit each
other out ("Sitting out" below), the host included, since the hosted
server and its `/m/` file serving do not need the host's player.

## Sync model

Loosely modeled on Syncplay, with a different readiness design.

- **Transport** is `playing`, `held` or `finished`. The server owns the clock:
  `positionAt(now) = position + (playing ? now - serverTime : 0)`.
  Reports from clients never move it. Only seek, swap, gate transitions and
  the end of media write `position`/`serverTime` and bump `eventId`.
- **Clock offset**: `serverTime` is on the server's clock. Each client sends
  a `ping` with its clock every second and estimates the offset NTP style
  (`ClockSync`: `offset = s - (t0 + t3) / 2` of the sample with the smallest
  round trip among the last 16). All extrapolation uses
  `SyncClient.serverNow()` (local clock plus offset), so a client whose clock
  is off still lands on the server position.
- **Reports**: clients send `position`, `buffered`, `eventId` every 1 s, plus
  the media `duration` and its `mediaId` once the player knows it. The
  server stores `buffered` and liveness, and takes the first reported
  duration for the current media (swap resets it); a report with `eventId`
  older than current has its position ignored. `buffered` is the current
  media's only: the client sends 0 until the player holds it (a swap's
  media still resolving, being fetched by the server or opening), and the
  server counts a report naming an earlier `mediaId` as 0, so the old
  media's buffer never passes the gate for the new one.
  Besides the 1 s tick, a report goes out right after a new media is
  open and, while HELD, the moment the buffer reaches `need`, so the gate
  does not wait for the next tick.
- **Ready gate** (HELD to PLAYING): the in-set is non-empty and every
  in-set member is ready, fresh and has `buffered >= need`. `need` is 4 s
  (`minBufferSecs`), or near the end what is left minus 2 s
  (`endSlackSecs`, floor 0), since mpv cannot buffer past the end. So a
  lone viewer plays alone; with others present everyone must ready.
- **In-set** (who the gate waits for): a member joins it on joining, or
  on coming back from stale, while not PLAYING (any media, the one the
  server started with included); joining while PLAYING it stays out
  (`ready=false`) until it readies: a late joiner never pauses anyone. A
  swap puts every fresh member in the set and keeps everyone's ready flag,
  so the next video starts once everyone ready has buffered (the client
  setting "Unready when the video changes", `AppSettings.unreadyOnSwap`,
  default off, sends `ready=false` itself on a new `mediaId`; not for the
  first state of a session, and a reconnect does not restore a ready that
  a swap meanwhile would have dropped). Stale, leave, sitting out and a
  player error remove from the set.
- **Player error** (`EngineMember.error`, `report.error`,
  `state.members[].error`): a member whose player cannot open the current
  media says why in its reports; the server takes it out of the set at
  once (like sitting out, but automatic: `ready`/`force` do not put it
  back, its ready flag is kept), so the others start without it. A report
  without it (the media opened, after a reload too) or a swap clears it:
  back in the set like a join while not PLAYING; while PLAYING from its
  next frame if it is ready (the others then hold for its buffer, as for a
  stale member coming back), else from its `ready`.
- **Sitting out** (`EngineMember.out`, `state.members[].out`): a member
  stays connected (chat, feed, party, nudges) but is never in the set and
  never ready: no `ready` or `force` reaches it, a swap leaves it out, its
  reports keep it fresh but their `buffered` counts as 0. Anyone can sit
  anyone out (`out` with `out:true`, the host included); only the member
  itself comes back (`out:false`): it is then in the set like a fresh join
  (unless PLAYING) and still unready. The app: an out member's player has
  nothing open (no stream or relay pulls; a relay it serves goes on) and
  shows the join-back card (cover, title, episode, the server position and
  playing/paused). "Join back" or Space sends `out:false` and then
  `ready`: at once while HELD (the gate waits for its buffer), while
  PLAYING once the player has buffered `need` (at most 15 s), so the others
  do not pause for the load. Putting something up while out comes back
  first. A reconnect that lands as a new member sits out again.
- **Pause**: while PLAYING, any in-set member who becomes not ready, under
  `need` buffered or stale flips the server to HELD (feed action `pause` by
  `server`). Recovery resumes by itself when the gate passes.
- **End**: while PLAYING with a known duration, reaching it sets FINISHED
  (feed `finished` by `server`, position = duration). Clients pause where they
  are, except one within 3 s of the end (`finishSlackSecs`), which plays
  out to mpv's own stop; at the end the position shows the full duration.
  FINISHED never auto-resumes. A seek turns it into HELD at the new
  position (resuming at once if the gate passes); a swap resets to HELD.
- **Seek**: allowed from any member in any transport; the server writes the
  position, bumps `eventId` and records who sent it (`seekBy`, `seekSeq` in
  `state` for that event); flags are untouched. Clients diff each `state`
  broadcast by `eventId` (`StateDiff`): new event means seek to the computed
  server position, transport change means play/pause. The coordinator
  applies states one at a time, newest first (a state arriving meanwhile
  replaces any still waiting): interleaved applies could land an older
  pause after a newer play. Between events: drift
  over 5 s for more than 2 s seeks, ahead by more than 1.5 s sets rate 0.95
  until level, otherwise nothing.
- **User seeks**: the player is a `SyncPlayer` whose public `seek` is the
  user's: the session's seek bar (`ChapterSeekBar`, one `seek` per pointer
  move while dragging and one on release, like media_kit's), the arrow
  keys, skips, chapter jumps and `seekTo` all become explicit events. The player moves at
  once (scrub preview); `UserSeekGate` sends one `seek` intent with a fresh
  `seq` after 300 ms without another request (`seekDebounceMs`). While the
  user is seeking, and until the echo of the last sent seq arrives (3 s at
  most), server seeks never touch the player; the echo of our own seek is not
  applied either (the player is already there). A server seek that has not
  landed after 1.5 s is re-applied once (`_checkSeekLanded`), to the server
  position recomputed now, and only while its event is still current and the
  user is not seeking.
- **Liveness**: WS ping every 5 s; silent over 15 s means stale (out of the
  gate, `stale` feed); over 30 s the socket is closed and the member removed.
  A stale member goes back into the set with its next frame if it is ready
  (also one stale at a swap) or the server is not PLAYING.
  Closed sockets are polled with `isClosed` every second: Relic's server-side
  `onDone` does not fire for dead peers, so presence never relies on it.
- **Resume**: a reconnecting client sends its previous token as
  `hello.resume`. If the server still has that member (an unclean drop it has
  not noticed), the new socket takes it over: same token, member id, ready
  flag and media URL (the player keeps streaming), no join/leave feed, and the
  dead socket is closed without removing the member. An unknown token joins
  as a new member.
- **Client policies**: no state broadcast for 5 s means connection lost, clear
  the server state and reconnect every 1.5 s until cancelled (an epoch counter makes
  a cancelled attempt stale). After a reconnect the ready flag is
  restored from the server's state. Cancel during setup aborts the join.
  Closing the window leaves gracefully (2 s timeout).
- **Idle** (`IdleTracker`): measured from the later of the last input and the
  moment playback stopped. While HELD and self ready: warning at 8 min,
  auto-unready at 10 min, and never less than 2 min after the warning.
  With "When idle, sit out instead of just unready"
  (`AppSettings.idleSitsOut`, default off) the 10 min step sits out.
- **Nudge**: `nudge` names a member; the server passes it to that member
  only (no feed), at most 3 per second and 20 per minute per sender
  (`nudgesPerSec`, `nudgesPerMin`; the rest is dropped silently). The
  nudged app plays the nudge sound whatever its per-sound switch (the
  volume still applies), toasts "Alice nudged you" and asks the desktop
  for attention when its window is not focused: the runners' `starsync/window`
  channel (`attention`), the urgency hint on Linux (GTK, cleared on focus)
  and `FlashWindowEx` until foreground on Windows.
- **Deviations from Syncplay**: clock never follows the slowest watcher; no
  pause-on-leave; anyone can force ready/unready (all or one); presence gate;
  the clock is server time (clients correct for their offset to it).

Additive wire changes only; bump `proto` and PROTOCOL.md in the same commit.

## Media

Three sources, same sync. Any of them can also go through the relay
(below).

- **Link**: the media field holds an http(s) URL. It travels as `media.url`
  in `swap` and `state`, and as `mediaUrl` in `welcome`. Each app plays it
  directly (a web page through mpv's yt-dlp hook, see "yt-dlp"); the
  server is only the clock. A pasted link that
  `parseJellyfinLink` recognises goes up as a Jellyfin ref instead when the
  ServerId is known (in the link, else `/System/Info/Public`), so its
  `api_key` is never shared (`mediaForLink`, host and swap alike).
- **Host local file**: `SyncServer.setLocalFile` / `mediaPath` makes the file
  the session media. `GET /m/<sid>/<token>/<name>` serves it with a Range
  table, gated by the viewer's token. The server builds the URL per viewer
  (`http://<host>:<port>/m/default/<token>/<name>`), so tokens never reach
  other viewers. `<host>` is the authority the client dialled; `advertiseHost`
  (default empty) only overrides it when set explicitly. When a `state`
  broadcast has no `media.url`, the client builds the URL itself from the host
  it connected to. Bytes stream file to socket and are counted as streamed
  (`bytesServed`); nothing is stored. The host plays through loopback like
  everyone else.

- **Jellyfin item**: the media is a ref (`{serverId, itemId, ...}`, wire in
  [PROTOCOL.md](PROTOCOL.md) "Jellyfin media"); the server never stores or
  sends a URL or token for it. Each app resolves it with its own account and
  direct-plays the static stream; guests use the server's own login when
  it has one ("Jellyfin relay"), else the member who put it up ("Relay").

Range table (`resolveMediaRequest`, tested byte-exact):

| Request | Response |
|---|---|
| no Range | 200, `Content-Length` = size |
| `bytes=a-b` | 206, `Content-Range: bytes a-b/size` |
| `bytes=a-` | 206 to EOF |
| `bytes=-n` | 206 last n bytes |
| unsatisfiable | 416, `Content-Range: bytes */size` |
| host has no file | 503 + `Retry-After: 2` |
| bad / unknown token, unknown session | 401, 410 |

Always `Accept-Ranges: bytes`; `Content-Type` from the extension
(`contentTypeForFile`). Relic hands the Range over as a typed `RangeHeader`;
the endpoint takes the first range and keeps the unit, so non-`bytes` units
still get 416.

What mpv does against it (recorded with `tool/range_logger.dart`): mp4 opens
once with no Range then streams `bytes=0-` to the end; mkv opens `bytes=0-`
twice (probe, playback), reads a small tail at `size-n` (cues, expressed
open-ended), then every seek is a fresh `bytes=N-` connection. A server
outage of a few seconds is ridden out from mpv's cache with no error. Longer
outages exhaust the cache and rely on reconnect (not chaos-tested yet).

mpv settings (`PlaybackController`): `Player` with `bufferSize` 256 MiB
(media_kit's `bufferSize` sets both `demuxer-max-bytes` and
`demuxer-max-back-bytes`), `libass` on; pinned via runtime property:
`demuxer-readahead-secs=150`, `cache-secs=150` (about two minutes of
read-ahead: rides out short drops, intro skips are instant),
`demuxer-max-bytes=268435456` (150 s up to ~14 Mbit/s; a 1.4 GB / 24 min
file is ~8), `demuxer-max-back-bytes=67108864`,
`stream-lavf-o=reconnect_streamed=1,reconnect_on_http_error=5xx,reconnect_delay_max=4,reconnect_max_retries=3`
(comma form; this mpv build rejects colon-joined): a dropped connection
or a 5xx is retried, at most 3 times per read and 4 s apart at most; a
4xx (a CDN refusing a request) fails at once instead of being retried
(older ffmpeg ignores `reconnect_max_retries`). A load that fails (mpv's
fatal "No video or audio streams selected", or an EDL track that cannot
be opened) before a duration is known is reported once per open
(`onLoadError`), with ffmpeg's HTTP status when this player gets
ffmpeg's log (ffmpeg logs through one mpv instance per process: the
first one, and once that is disposed the next one created; the preload
player passes the HTTP errors it gets on to the session player). That, a yt-dlp hook error and a failed `openUrl` become
the coordinator's `playerError` in plain words (`playErrorText`, core
`link_probe.dart`: 412/precondition/login/cookies/sign in → "This site
needs cookies — Settings → Player → yt-dlp → Cookies", 403 → "Not allowed
(403)", 404/410 → "Not found (404)", "Unsupported URL" → "Not a video
page yt-dlp knows", network errors → "Couldn't reach the site", anything
else as is). It rides in `report.error` (see "Player error" in the sync
model) until the media opens (a new duration) or the server's `mediaId`
moves on; the pill shows "Can't play this: ..." with Retry (Reload
video). The cache is in RAM:
media_kit sets `cache-on-disk` without a `cache-dir`, and mpv falls back. mpv
ignores invalid values silently, so every pin is read back and a mismatch is
logged and kept in `pinMismatches`. Measured against the `/m` endpoint
(`readahead_e2e_test`): a paused player buffers ~147 s ahead (10 s before).
media_kit has no public `setProperty`/`getProperty`; the code calls them
through a guarded dynamic call on `player.platform`. Hardware decoding comes from Settings (auto, off, custom)
and is passed to the `VideoController`; env `SYNC_RELAY_HWDEC` (e.g. `no`)
overrides it. It is read per player, so a change applies on the next join or
Reload video.

Shaders (per viewer, local only, no wire change): mpv `glsl-shaders`, set
through the same dynamic `setProperty` and read back
(`PlaybackController.applyShaders`). The value is the platform path list
(`:` joined, `;` on Windows). One saved choice in `AppSettings`
(`shaderPreset`, `shaderQuality`, `customShaders`): applied on every player
creation (join, Reload video) and live when changed from the session (the
control bar's shader menu, Ctrl+0..6, both also save it). The Anime4K
v4.0.1 files live in `apps/desktop/assets/shaders/anime4k/` (only the 14
the presets use, plus its MIT LICENSE); mpv needs real paths, so
`extractAnime4k` copies them once per version to
`<app support>/shaders/anime4k-<version>/` (a `.complete` marker is written
last). `anime4kFiles` maps each mode to the file list of Anime4K's mpv
templates: HQ = the high-end GPU set (VL + M networks), Fast = the low-end
set (M + S). A missing file, a path containing the list separator, a
read-back mismatch, or an mpv `libmpv_render` error while shaders are on
turns shaders off (saved) with a toast.

Render mode: media_kit's Linux/Windows video output creates mpv's render
context (OpenGL, else its software renderer) when the `VideoController` is
created, and nothing in its API says which. The player therefore requests
mpv logs at `v` while the controller is created: OpenGL init logs
`GL_VERSION` under `libmpv_render`
(`RenderMode.gpu`; "suspected software renderer" means llvmpipe,
`softwareGl`); none within 1.5 s of the controller being ready means the
software path (`software`, where shaders do nothing; the shader toast, the
menu and Settings say so). Otherwise the session player logs at `warn`
(`PlaybackController.logLevel`, switched with `mpv_request_log_messages`
on media_kit's handle): media_kit drains mpv's log on the UI thread, one
message at a time, so a chatty level, or ffmpeg logging every retry of a
refused request, could starve the UI. Shader and yt-dlp hook errors are
`error` lines and still arrive. The thumbnail and sound players keep
media_kit's default (`error`) and nothing listens to their log. The hardware path is
fragile: media_kit borrows whatever EGL context GDK left current on the main
thread (upstream media-kit#1404), so an X11 session or a Flutter/GDK change
can silently fall back to software.

Player lifecycle: the `Player` and its `VideoController` live for one
session: created on join, disposed on leave, replaced by `recreate()` for
"Reload video" (button or Ctrl+R; volume kept), or by a promoted preload
when Up next's first item goes up (see "Getting ready" under "Up next"). `openUrl` opens with `play: false`; play/pause/seek/rate come only from
`StateDiff` actions, the play gate (`localPlayAllowed`: self in-set and
ready) or the user's own seeks (see Sync model). A server seek within 0.5 s of the current position is skipped. `leave()`
stops the player (otherwise audio keeps playing). On media change
(`mediaId` bump) the coordinator stops the previous media at once (no old
picture or sound while the new one resolves, is fetched or opens; a
reconnect to the media the player holds keeps it), then opens the new URL
(or promotes the preload holding it) and `StateDiff` seeks to 0, holds
and resets rate.

Chapters, segments, tracks (`PlaybackController` signals, values from
`playback/media_marks.dart`, no widgets; any controls UI reads them):
- `chapters`: mpv `chapter-list` (observed through the same dynamic
  `observeProperty` and read as JSON): `MediaChapter` index, title, start;
  end = next start, the last one's = `duration`.
- `segments`: the Jellyfin item's MediaSegments (`GET /MediaSegments/{id}`,
  10.10+: Intro, Outro, Recap, Preview, Commercial), fetched by the
  coordinator with `OwnPlay` only; relay and blocked viewers cannot call
  Jellyfin and use chapters alone. Empty without a segment provider plugin
  (the case on the owner's 10.11 server).
- `tracks`: audio and subtitle `MpvTrack`s from mpv `track-list` (id,
  language, title, codec, channels, default / forced / hearing-impaired /
  external, `selected`), re-read after every selection.
- `position` (250 ms steps), `duration`, `buffered` (end of the cached
  range: mpv `demuxer-cache-time`, media_kit's `buffer`, 250 ms steps);
  computed `opening`, `ending` (`SkipRange`) and `currentChapter`.

Skip rules (pure, `media_marks.dart`):
- Opening = first Intro segment, else the first chapter whose title has a
  whole word OP / Opening / Intro (any case, digits allowed: "OP1").
  Ending = first Outro segment, else ED / Ending / Credits / Outro.
- `skipOfferAt` (the coordinator's `skipOffer`, null at `finished`): inside
  the opening (up to its last second) "Skip OP" to its end; inside the
  ending "Skip ED" to its end only (no guessing about previews: the viewer
  decides). Without any opening, without chapters (a chaptered file
  without an OP chapter has none on purpose) and with media over 20 min,
  "Skip 1:30" during the first 6 min.
- +1:30 (`skipForward`: the pill, the controls' "1:30" button,
  Shift+Right) is a `nudge`, so repeated presses add up.
- Chapter steps (PgUp / PgDn, `chapterStepTarget`): forward to the next
  start; back to the current start, or the previous one within 5 s of it
  (mpv's `chapter-seek-threshold`).
- Every skip and chapter jump is a user seek (debounced, everyone follows).

Never unmount GPU-textured widgets (avatar images) on a transport-gated
branch: teardown races mpv's frame upload and the window goes black. Keep them
mounted and skip painting (`Visibility` with `maintainState`).

## Jellyfin client

`packages/core/lib/src/jellyfin/`, pure Dart over `dart:io` `HttpClient`
behind a `JellyfinHttp` interface (tests inject a fake). Plans:
[ROADMAP.md](ROADMAP.md) "Epic: Jellyfin".

- `JellyfinClient`: one server + one user. Auth (Quick Connect, password,
  `/Users/Me` check, logout), browsing (views, Resume, NextUp, Latest, paged
  `/Items` with `DateCreated`, search, seasons, episodes, recently played),
  image URLs (tag + maxWidth, no token
  needed), PlaybackInfo, stream URLs, MediaSegments (a 404 = none),
  Playing / Progress / Stopped reports, played / unplayed / resume position.
- `normalizeServerUrl`, `parseJellyfinLink`: pasted addresses and item links
  -> `(baseUrl, itemId)`; accounts are keyed by `ServerId`
  (`/System/Info/Public`).
- `episodeAfter`: next episode is the successor in `/Shows/{id}/Episodes`
  (crosses seasons, skips other copies of the same episode); NextUp means
  first unwatched, not next-after-X.
- `matchTrack` / `matchTracks`: carry audio/subtitle choice to the next
  episode (language required, then title words, forced/HI flags, codec,
  channels).

Gotchas (Jellyfin 10.11):
- Every request sends `Authorization: MediaBrowser Client, Device, DeviceId,
  Version[, Token]` (values percent-encoded). Unauthenticated calls missing a
  field get 400 with no body.
- A POST must carry `Content-Length` even when empty: behind nginx a
  body-less POST without it gets 400 (this was the Quick Connect Initiate
  failure).
- Jellyfin overwrites a token's stored device name and app version with the
  header's. Only use tokens this app obtained itself; a relay using a
  viewer's token must send that viewer's client fields (the server relay
  sends exactly its credential's fields).
- Static streams (`/Videos/{id}/stream?static=true`) serve the original file
  with byte ranges. The share URL has no credentials; each side adds its own
  `api_key` (`authorizeUrl`).
- Ticks: 10,000,000 per second.

## Jellyfin relay

For viewers without an account on the item's Jellyfin
(`packages/server/lib/src/jellyfin_relay.dart`). The server may hold one
`JellyfinCredential` (config key `jellyfin`: `baseUrl`, `serverId`, `token`,
`client`, `device`, `deviceId`, `version`; primitives, so it crosses the
isolate boundary in the `serve()` map). The hosting app fills it with its
own app-obtained token and that token's device fields; the dedicated server
reads it from `--jellyfin <file>` (YAML/JSON with those keys, keeps the
token off the command line) or a `jellyfin:` map in `--config`. An empty
`serverId` is looked up at start (`/System/Info/Public`); if that fails the
relay stays off. The token is never logged (`toString` and config parse
errors leave it out).

- Available (`state.relay`) only while the current media is a ref whose
  `serverId` equals the credential's; `state.relayNext` likewise for Up
  next's first item, which `/j` also serves so guests can preload it
  (see "Getting ready" under "Up next"). Only those two items are
  relayed, only to a valid viewer token: no open proxy.
- Each request opens `/Videos/{id}/stream?static=true&mediaSourceId=` with
  `Authorization: MediaBrowser` built from exactly the configured fields
  (Jellyfin rewrites a token's device fields from the header), forwards
  `Range` untouched and `Accept-Encoding: identity`, and returns Jellyfin's
  status and range headers. Bytes stream through (no buffering) and count
  toward `bytesServed` as sent. A viewer disconnect cancels the upstream
  response, which closes that connection (tested: `HttpClientRequest.abort`
  does nothing once the response has arrived; cancelling the response
  subscription does).
- No progress reporting in the server: watched state is per client.

## Relay

A member's media through the server's memory, for viewers who cannot
reach it themselves (`packages/core/lib/src/relay.dart` for the wire and
the source, `relay_pieces.dart` for segmented streams,
`packages/server/lib/src/relay_buffer.dart`, `piece_buffer.dart`,
`relay_routes.dart`; wire in [PROTOCOL.md](PROTOCOL.md) "Relay").

What gets relayed (`SessionCoordinator.swapPicked`):

| Put up | Others get it |
|---|---|
| File, by the host | `/m` from the hosting app (no relay) |
| File, by anyone else | relayed from that member's computer |
| Link, "Everyone fetches it" | each app fetches it |
| Link, "Server fetches it" | the server reads it once into the buffer; the link is never broadcast; refused on an open server (it would fetch any address it can reach for anyone) |
| Link, "Through me" (default) | relayed from that member's computer; plays for everyone whenever it plays for them (their cookies, their network) |
| Jellyfin item (browser pick or pasted link) | own account first, then the server's login (`/j`), then relayed from the member who put it up (with their sign-in, or the pasted link's key, which stays on their machine) |

Relayed links are range-read: a media file as is, a web page as yt-dlp's
formats, resolved where the bytes are fetched (see "yt-dlp"); the swap
carries only the page URL and the mode. A page's formats are one file, or
a video-only and an audio-only file (YouTube has only those): a media of
two **tracks**, each relayed as its own byte stream with its own buffer
and URL, played together by viewers as an mpv EDL
(`edl://!no_clip;%n%<video>;!new_stream;!no_clip;%n%<audio>`,
`relayViewerUrl` / `mpvEdl`). media_kit opens an `edl://` URL unchanged
(it writes it to a playlist and `loadlist`s it) and mpv keeps both
streams in sync across seeks; one URL keeps the app's "one media URL"
path (sync, swap, reopen) as is. The source member plays the page
itself (yt-dlp hook) like any other link.

A page with only segmented streams (HLS `m3u8_native`, DASH
`http_dash_segments`, e.g. X's HLS, generic `.m3u8`/`.mpd`) is relayed as
**pieces** tracks (`"as":"pieces"`, one muxed playlist or video + audio):
the fetcher parses the upstream media playlist (`parseHlsPlaylist`), or
yt-dlp's DASH `fragments` (`dashPieces`: a first fragment without a
duration is the init section, so no MPD parser), into a
`RelayPieceList`: each segment, `EXT-X-MAP` init section and AES-128 key
is a piece, one upstream GET, with `EXT-X-BYTERANGE` folded into the
piece. The server serves a VOD media playlist it writes itself from that
list (`RelayPieceList.playlist`: durations, media sequence,
discontinuities, MAP, AES-128 keys with their IVs; every URI its own
`p/<i>`), so a source can never point viewers anywhere else. One URL per
piece also avoids mpv's seek hang on byte-range fMP4 playlists (Apple's
`bipbop` hung on the first seek read directly). Refused: DRM (SAMPLE-AES,
`skd:`, any non-identity key format, `EXT-X-SESSION-KEY`, yt-dlp's
`has_drm`), a live playlist (no `EXT-X-ENDLIST`; yt-dlp's `is_live`
first), a master or I-frame playlist. A remux on the fetcher (ffmpeg
`-c copy` into one pipe) and yt-dlp's own download + merge were rejected:
the size is unknown until the end, a seek past the written part cannot be
served, and it needs ffmpeg or disk.

How bytes move:
- The source dials `/r/.../source` (outbound, so NAT/CGNAT are fine) and
  answers the server's pulls from the file or the URL (`RelaySource` over
  a `RelayMedia`: its `RelayTrack`s, each a `RelayBytes`:
  `FileRelayBytes`, `HttpRelayBytes`, `LinkRelayMedia` / `PageRelayMedia`
  for links; a Jellyfin source sends its own `Authorization` header from
  this machine). Viewers only ever talk HTTP to the server, so the source
  never sees mpv's request pattern. The tracks of a media share the
  channel and its flow control (they compete for the same uplink).
- Upstream GETs (`HttpRelayBytes.read`) are split into back-to-back
  ranges of at most yt-dlp's `http_chunk_size` for the format, else
  10 MiB (`relayUpstreamChunkBytes`); a buffer pull stays one read.
  YouTube serves a range up to 10 MiB at full speed but throttles a longer
  or open-ended one to about twice the bitrate (measured 0.8 MB/s against
  8.6 to 12.5 MB/s); chunked, a 1080p relay seeks in under 0.8 s (4 to
  6.6 s unchunked) and even beats mpv reading YouTube directly, since the
  buffer reads ahead at full speed.
- The server keeps one buffer per track of a relayed media (one for a
  file), a `RelayBuffer` for bytes: 1 MiB slices in
  memory, filled by one sequential pull at a time. Kept: the first and
  last 2 MiB (container indexes; mpv reads both on open and on seeks),
  64 MiB behind the slowest viewer and 256 MiB past the furthest, the
  same as each viewer's mpv buffer (`PlaybackController`), so a skip
  inside the viewers' buffer window is served from memory. Evicted by
  distance from the viewers, never LRU. With 2+ viewers the source sends
  each byte about once. Several tracks split the ahead and behind budgets
  by size (one duration, so by bitrate; `relayBudgets`), at least 8 MiB
  each, which keeps both windows at the same playback distance (1080p
  video + aac: about 246 + 10 MiB ahead); each pins its own head and
  tail. A viewer is its token in every track's buffer.
- A pieces track gets a `PieceBuffer`: whole pieces by index, each one
  pull (a piece names its index on the channel), served whole with Range
  inside a piece. A viewer's position is its newest requested segment
  (opening the playlist puts a new viewer at the first one, so its first
  pieces are fetched before it asks). Filled: a blocked viewer's piece
  (oldest wait first; a pull nobody waits on gives way at once), the init
  and key pieces the viewers' segments use, then segments ahead of each
  viewer up to the ahead budget, slowest first. Init and key pieces are
  kept; segments are evicted by distance (behind costs 4x), sizes
  estimated from the bytes per second of the pieces in so far (before
  that 4 Mbit/s video, 160 kbit/s audio, which also splits the budget).
  A failed pull is retried after 1 s. Measured (mpv 0.41 through the
  dedicated server, loopback, ~30 MB/s upstream): Mux's TS HLS (1080p,
  one muxed playlist) opened in 0.8 s, seeks 0.07 to 1.1 s; Akamai's DASH
  (1080p + aac, two playlists, EDL) 1.3 s, seeks 0.03 to 1.4 s; an X
  video's HLS video + audio 0.3 to 0.75 s, seeks 0.03 to 0.4 s; A/V sync
  within 0.2 ms after every seek; a second viewer of the same pieces
  opened in 0.02 s from the buffer.
- Filling a byte buffer: a viewer blocked on a slice first (oldest wait
  first, handing the source over at slice boundaries), then the pinned
  slices, then read-ahead from the slowest viewer. Nothing is fetched while nobody
  watches through the relay (a Jellyfin source with only account holders
  uploads nothing).
- mpv leaves superseded requests open but unread after a seek: only a
  viewer's newest request moves its position or asks the source for
  anything; older ones still get bytes that are already buffered.
- Flow control on the source (`RelayWindow`): one in-flight budget per
  connection, 2 x delivery rate x min RTT (rate max-filtered over 2 s),
  clamped 256 KiB to 8 MiB; the server acks bytes as they arrive. A
  cancelled pull's unacked bytes are written off, and a cancel that lands
  while a frame is being read stops it before it is sent.
- Cleanup: the buffer is memory only. Any swap disposes it (its URLs then
  404, the source is closed with 4001 and stops), and so does server
  stop. A crash frees it with the process.
- Source away: viewers keep playing from the buffer; a request waits up
  to 60 s for missing bytes. The source reconnects with backoff (same
  token after a resume); a different size (or piece count and roles)
  drops that track's buffer.
  `state.media.relay.live` follows the channel, and viewers show "waiting
  for <name> to pass the video on" while it is down, "<name> left:
  playing what the server has" once the source left the server.
- Stats (`relay_stats.dart`, `ServerHub.sampleRates` on the 1 s
  heartbeat; wire in [PROTOCOL.md](PROTOCOL.md)): the source's rate is
  its bytes over the time a pull is in flight (`FeedClock`, one per media
  shared by its tracks, run by each buffer's pull), so a full buffer with
  an idle source does not read as a slow one; smoothed over about 4 s of
  that time (`SourceRate`). Its first-byte wait counts, so it reads a bit
  under the uplink on short pulls. The need is the tracks' sizes over the
  reported duration (pieces: their bytes per second once a minute of
  segments is in). Each member's rate is its `bytesServed` change over
  5 s (`ReadRates`), which follows what its player asks for, not what its
  link could take. Two significant digits keep `state` from changing with
  every byte. The app (`session/delivery.dart`) derives the rest from the
  state: the kind (link, host's file, server's file, member relay, server
  fetch, Jellyfin), each member's route (source; via server: relayed,
  `/m`, or Jellyfin `jf` false; direct: links, Jellyfin `jf` true) and
  buffer health (enough for `bufferNeed`, low, empty while playing). The
  members card (`shell/delivery_line.dart`) shows it as a source line and
  a dot per member; nothing goes on the picture. The source gets one toast
  per media while `rate` < `need`. Not shown: a direct member's speed
  (the server never sees its bytes).

Measured (mpv 0.41 viewers, real server and source, a shaped link
between source and server; `tool/relay_e2e.dart`, 2-minute 1080p test
file averaging 10 Mbit/s with a 15 Mbit/s busy section):

| Source uplink | Open | Seeks (incl. +90 s skip) | Stalls in 50 s |
|---|---|---|---|
| 400 Mbit/s, 20 ms | 0.8 s | 0.01 to 0.03 s | 0 |
| 40 Mbit/s, 40 ms | 2.1 s | 1.1 s first, then 0.03 s | 0 |
| 20 Mbit/s, 150 ms | 5.4 s | 1.1 to 5.3 s | 3 |
| 12 Mbit/s, 40 ms | 5.4 s | 0.5 to 2.9 s | 3 |

3 viewers skipping together on 40 Mbit/s: no stalls, the source sent
101 MiB for 287 MiB served. A late joiner opened in 0.04 s from the
buffer. A 5 s source outage: no stall; 30 s: one stall once the buffer ran
out, then it recovered. Freezes of 0.3 to 0.8 s in 30% of seconds: no
stall. So the source's upload must beat the media's average bitrate
(peaks are covered by read-ahead once it has some lead), and comfortably
so for quick seeks. Rejected along the way: a fixed per-request window
(seeks of 14 s on slow links, data for abandoned positions clogging the
pipe), one shared window across requests (deadlocked on mpv's unread
requests), Dart `http2` (connection window stuck at 64 KiB).

## yt-dlp

Web pages with a video (YouTube, Twitter/X, ...) play through yt-dlp in
all three link modes. Nothing is bundled or installed by hand.

- **Manager** (`YtDlp`, `packages/core/lib/src/yt_dlp.dart`, used by the
  app and the server): the managed copy in its folder (`yt-dlp` /
  `yt-dlp.exe`) first; if missing it downloads the official standalone
  build for the platform (`ytDlpAssetName`: `yt-dlp_linux`,
  `yt-dlp_linux_aarch64`, musl variants, `yt-dlp.exe`, ...) from the tag
  `releases/latest` redirects to, checks it against that release's
  `SHA2-256SUMS`, makes it executable (not on Windows) and renames it into
  place. If the download fails, a `yt-dlp` on PATH is the fallback. After
  that, at most once a day (`last-check` stamp in the folder) and in the
  background, a newer tag is downloaded the same way; nothing waits for
  it. `version`, `lastError`, `busy` and `changes` feed Settings → Player
  → yt-dlp ("Update now" forces the check). Every failure is non-fatal.
  Folders: the app's is `<app support>/yt-dlp` (`AppYtDlp`, warmed up at
  start), shared with its hosted server; the dedicated server's is
  `--yt-dlp-dir`, else `$STATE_DIRECTORY/yt-dlp` (systemd), else
  `yt-dlp` next to the binary if writable, else
  `~/.cache/watch-together/yt-dlp`.
- **Cookies** (`YtDlpCookies`, `cookies.dart`): a yt-dlp folder holds at
  most one source, `cookies.txt` (a private Netscape copy, mode 0600,
  written to a `.part` that is made private before anything goes into
  it) or `cookies-browser` (`BROWSER[:PROFILE]`). Every resolve adds
  `--cookies <copy>` or `--cookies-from-browser <spec>` (the update and
  `--version` runs do not); yt-dlp may write the copy back. Imports
  (`parseCookies`) take a Netscape cookies.txt or a cookie extension's
  JSON array (`name`, `value`, `domain`, `path`, `expirationDate` /
  `expires`, `hostOnly`, `secure`, `httpOnly`, `session`; host-only
  cookies keep their bare host with `FALSE`, the rest get a leading '.';
  session cookies expire `0`), grouped by site (`cookieSite`: the
  registrable domain by a short rule, with google.com filed under
  youtube.com and bilibili's CDNs under bilibili.com). The app: Settings
  → Player → yt-dlp → Cookies (a browser and profile, or a file picked or
  dropped, kept whole: every site in it; "Remove cookies"; the shell's
  own drop target is off on Settings so only this box takes the file); its hosted server shares the folder,
  so it uses them too. mpv's hook gets the same as `ytdl-raw-options`
  (`cookies=%N%<path>` / `cookies-from-browser=%N%<spec>`, length-quoted),
  re-set before each external link when it changed, after
  `sub-langs=all,-danmaku` (Bilibili's danmaku XML is served raw-deflate:
  ffmpeg warns on every read and the video waits on the track). The dedicated
  server: `--yt-dlp-cookies <file>` / `ytDlpCookies` converted into its
  folder at start; without it the copy and browser setting are removed.
  Values are never logged and never leave the machine.
- **Resolve** (`YtDlp.resolve`, `resolveArgs`): `yt-dlp -J --no-playlist --no-warnings
  --ignore-config` plus the cookies, 25 s timeout: title, uploader, duration, thumbnail,
  live or not, and what a relay reads (`pickTracks`), each format with
  its URL, `http_headers` and `http_chunk_size`. Only plain http(s)
  formats without DRM count:
  - the best single file (`pickSingleFile`: video and audio not `none`, a
    video container, tallest up to 1080p, else the shortest above), unless
  - a video-only + audio-only pair is taller (`pickSplit`): video tallest
    up to 1080p (else the shortest above), HEVC before AV1 before VP9
    before h264 (the most compact first: relayed bytes cost every viewer
    and the server buffer, and mpv decodes them all), then bitrate; audio the original language, not a
    `-drc` variant unless alone, m4a/aac before opus, then bitrate.
    YouTube has only these (299 + 140 for a 1080p60 video).
  - Neither: segmented streams (`pickPieces`: `m3u8_native`/`m3u8` with a
    media playlist URL, or `http_dash_segments` with http(s) `fragments`;
    not `has_drm`): one muxed playlist (video and audio not known to be
    absent) unless a video-only + audio-only pair is taller, with the
    same height, codec and audio rules. Relayed as pieces (see "Relay").
  - A live stream, or nothing of the above: nothing to relay.
- **Probe** (`probeLink`, `link_probe.dart`): a `Range: bytes=0-0` GET; a
  video/audio type, or a generic one on a media file name, is a file
  (`looksLikeMediaFile`); anything else goes to yt-dlp, and when yt-dlp
  cannot read it the page's `og:title` / `<title>` is kept with yt-dlp's
  reason and the GET's HTTP status. `LinkProbe.problem`: why it will not
  play, in plain words (`playErrorText` of yt-dlp's reason, else of a 4xx
  status), null for a file or a page yt-dlp read. The app probes on paste
  (`AppYtDlp.probe`, remembered 10 minutes, longer for Up next's first
  item (see "Up next"); media file names too, not a
  Jellyfin item link) for the
  Link preview and the swap: a page is named by its title, never its URL
  tail, and its thumbnail goes up as its art (see "Media art"). A link with a
  problem, or one the probe cannot reach ("Couldn't reach the site"), is
  not put up in any mode: the Link page shows the reason (preview and
  under the button) and offers "Put it up anyway" (`LinkMedia.anyway`),
  for when the server or a friend with cookies may still open it;
  `swapLink` refuses it the same way for any other caller.
- **Everyone fetches it**: the swap sends the page URL. Before opening an
  external link every app points mpv's hook at its managed copy
  (`script-opts=ytdl_hook-ytdl_path=...`, `ytdl-format=bv*[height<=1080]+ba/b`,
  once per player), waiting for the download unless the URL names a media
  file. A hook error is a player error (see the mpv settings under "Media"). The hook (mpv
  0.41) gives mpv the first requested format's `http_headers` (User-Agent
  as `user-agent`; Referer, Cookie, X-Forwarded-For as file-local
  `http-header-fields`, which win over the empty list media_kit sets on
  load) and its `cookies` (`stream-lavf-o`), for every track of its EDL:
  Bilibili's CDN answers 403 without the Referer. The app never opens a
  resolved format URL in mpv itself (the putter of "Through me" plays the
  page through the hook too); relays read them with yt-dlp's headers.
- **Through me**: the putter's probe must give tracks, and a pieces
  track's playlist must be readable, else the swap is refused ("Live
  streams can't be passed on", DRM, or nothing a relay can read) with a
  hint to use "Everyone fetches it". The swap names the tracks; its relay
  source reads them with yt-dlp's headers (`PageRelayMedia`). On 403/410
  (expired format URLs, 6 h on YouTube; signed segment URLs) from any
  track it resolves the page again once for all tracks, finds the same
  format ids with the same sizes and piece counts and roles (playlists
  re-read and re-mapped by index; else "the video changed on the page")
  and goes on from where it stopped. Format URLs are bound to the
  resolving machine's address, so they never leave it.
- **Server fetches it**: the server probes the link itself
  (`LinkRelayMedia`) with its own yt-dlp (off with `--no-yt-dlp` /
  `ytDlp: false`) and relays its tracks the same way, setting
  `relay.tracks` with `live`. The putter only refuses a page its own
  yt-dlp says cannot be relayed (the server may reach what the putter
  cannot); when the server cannot read it, the putter gets an `err` with
  the reason. Viewers open a fetched
  link's `/r/` URL only once `relay.live` is set ("the server is getting
  the video…" until then): resolving takes seconds and media_kit's mpv
  gives up on a silent request after 5 s (`network-timeout`).

## Jellyfin in a session

Client side (`lib/src/jellyfin/session_media.dart`, `progress.dart`,
`track_prefs.dart`, wired in `SessionCoordinator`):
- **Resolve**: a `state` whose media is a ref is resolved per viewer
  (`resolveJellyfinRef`): an account for that ServerId that is not expired
  -> PlaybackInfo with its own user (PlaySessionId, media source; `/Items/{id}`
  alongside for series and episode numbers), then mpv plays the static
  stream with the token in `http-header-fields` (`Authorization:
  MediaBrowser` with this install's fields), not in the URL: `OwnPlay`,
  `report.jf {serverId: true}`. Else, when `state.relay`, `welcome.relayUrl`
  or `/j/default/<token>/<itemId>` on the dialled host: `RelayPlay`,
  `jf: false`. Else, when `media.relay` names a source, the `/r/` URL:
  `RelayPlay`. Else `BlockedPlay`: the session shows "No Jellyfin account
  here for <server>, and nobody is passing it on" with a button that
  opens Integrations over the session; linking (or reconnecting) the
  account retries by itself. A 401 marks the account expired. The member
  list shows "via server" for members whose `jf` is false for the current
  item (see "Relay", Stats). A reconnect to the same item with `OwnPlay` keeps playing as is.
- **Progress** (`JellyfinProgressReporter`, `OwnPlay` only): Playing once the
  file is open and mpv has picked its tracks; Progress every 10 s and at
  once on pause, resume, a seek (position more than 3 s from where playback
  should be) or a track change; Stopped on swap, leave, sitting out, window close
  (bounded to 1.5 s inside the graceful leave) and at `finished`; seeking
  back from the end sends Playing again. Reports carry `PositionTicks`
  (see "Watched rule"), `IsPaused` and mpv's `aid`/`sid` as Jellyfin
  stream indices (`jellyfinIndexForMpvTrack`, `SubtitleStreamIndex -1` =
  off). They go out in order on one chain; failures are logged, one quiet
  toast per session, playback is never touched; a 401 marks the account
  expired and ends reporting.
- **Watched rule** (`WatchSession` in `packages/core/lib/src/watch_session.dart`,
  pure, meant for any tracker): each opening samples the position every
  tick; only normal playback counts (forward, at most 2x speed + 1.5 s,
  samples at most 10 s apart; seeks, skips and pauses add nothing). The
  union of the watched stretches is the coverage (rewatching counts once),
  alongside the plain watched time, first / last / furthest position and
  start / end time. At a stop: played before this opening -> keep played;
  coverage >= 80 % of the runtime, or the ending reached (furthest position
  past the Outro / ED start, else the real end) with coverage >= 50 % ->
  played; coverage under max(2 min, 5 %) (at most a quarter of a short
  item) -> a peek; else part way, resuming at the last position. An
  unknown runtime never makes it played. Jellyfin decides played from
  positions alone (10.11): Playing sets a resumable item unplayed, a
  Progress or Stopped position past "max resume" (90 %) marks it played,
  one in between keeps a resume point. So `JellyfinProgressReporter`
  (played before = `UserData.Played` read at open with
  `/UserItems/{id}/UserData`):
  - played (before, or by the rule at an earlier stop of this opening):
    `UserPlayedItems` right after Playing, Progress without
    `PositionTicks` (leaves the saved position and played state), Stopped
    without `PositionTicks` (Jellyfin marks it played, position 0), then
    `UserPlayedItems` again;
  - peek: Stopped with the resume point from before the opening (0 when
    none), so the item is as it was;
  - part way: Stopped at the last position, held under 85 % of the
    runtime so Jellyfin cannot mark it played;
  - not played yet, any time: Progress leaves `PositionTicks` out from
    85 % of the runtime on (and without a runtime), so only the rule
    marks it played.
  Members playing through the server report nothing.
- **Episodes**: with `OwnPlay` on an episode, `adjacentEpisodes` (one
  `/Shows/{id}/Episodes` call; `episodeBefore` / `episodeAfter`) gives the
  previous and next episode. The controls show previous / next buttons
  (also `<` `>`, Shift+P / Shift+N); from `nextPromptStart` (the ending's
  start when one is known, see "Skip rules", else the last 2 min of the
  runtime) a floating "Next episode" pill shows while the controls are up
  (see "Session controls"). Auto-advance still waits for `finished`. Any
  of them swaps to that episode's ref with the clicker's account. Guests
  (relay, blocked) see none of it.
- **Auto-advance** (Settings, on by default): at `finished` with a known
  next episode, every client with the setting on shows a 10 s countdown
  card (Cancel / Play now; without the setting, a "Next" card with Play
  next). Exactly one client swaps: `autoAdvanceSwapper`, the lowest member
  id among non-stale members whose `jf` for that server is true. Only what
  every client sees in `state` decides it (who put the item up is not in
  `state`; a late joiner never saw that swap), so clients agree without a
  wire change. Cancel is local: it stops the countdown on that screen, and
  the swapper's Cancel stops the swap; a seek by anyone ends `finished`
  and with it every countdown. Only while Up next is empty and its
  continuation was not cleared (see "Up next"); a queued item replaces
  a countdown already running.
- **Tracks**: the controls' Audio and Subtitles buttons list
  `PlaybackController.tracks`. A pick is applied, reported, and saved as a `TrackChoice`
  (language, title, codec, channels, forced/HI: from the Jellyfin streams
  with `OwnPlay`, else from mpv's track list) per series and as the global
  fallback in the `track_prefs` Hive box. On the next Jellyfin item it is
  matched with `matchTrack` against the source's streams (mapped to mpv ids
  with `mpvTrackId`) or mpv's track list, and selected locally. Nothing goes
  on the wire.
- **Change video**: the player's "Change video" opens the Library tab;
  Link goes through `mediaForLink`, a Jellyfin pick as a ref, a file
  through `ServerIsolate.setFile` (host) or the relay (`swapFile`).

## Up next

The queue: what plays after the current media. The server holds the list
(`EngineQueue` in `packages/core/lib/src/queue.dart`, in memory, part of
`state`; wire in [PROTOCOL.md](PROTOCOL.md), "Queue"), any member edits
it by item id (ops never clash), items outlive their adder. The app side
is `lib/src/queue/`: `QueueController` (owned by the coordinator, fed by
every `state` and feed), the pure rules in `queue_logic.dart`, the UI in
`queue_ui.dart`.

- **Adding** (`QueueController.add`, from "Add to queue" anywhere or the
  popover): a link is probed like a swap (`AppYtDlp.probe`) and refused
  when it will not play, in the chosen mode ("Through me" also needs
  something a relay can read, "Server fetches it" a password on the
  server; alone it is direct). The item carries the title, a second line
  (uploader or site, the show and episode, a file's parsed episode), the
  length when known, and a picture (a page's thumbnail, a Jellyfin
  episode still or backdrop, a file's frame from `thumbnailFor`; JPEG,
  under the poster cap) sent as `thumb`. A link passed on "through me"
  and a file go up as a `key` only: the app keeps the URL or path in
  memory under it and nothing else leaves it. The adder gets a toast
  "Added … to Up next"; everyone else an activity-log line.
- **Who puts an item up** (`queuePerformer`, from `state` alone, so all
  clients agree): a link passed on or a file, only its adder (gone:
  skipped, "Bob left"); a Jellyfin item, its adder when it plays that
  server with its own account, else the lowest member id that does
  (`jf`, which lists every working account; nobody: skipped); a link
  everyone opens or the server fetches, its adder when present, else the
  lowest active member id; for these, stale or sitting out counts as
  away (an adder who is stale is waited for until it is gone). A skip is
  a `remove` with the reason from the lowest member id that is not stale
  (`queueJanitor`); the feed's `queue-skip` toasts on every screen.
- **Advancing**: at `finished` with Up next waiting, every screen shows
  `UpNextCard` (picture, title, who added it and how; with auto-advance on
  a 10 s countdown with Cancel, else Play now only); at zero the app that
  puts the first item up does, with a swap naming it (`swap.queueId`), so
  the server takes it off in the same step and a second swap of it is
  ignored. Cancel is per screen like the next-episode countdown. "Play
  now" anywhere (a row, the card, the Up next button's ⏭, `>` / Shift+N) swaps
  directly from the app that can, else sends `play` and that app reacts
  to `state.queuePlay`. With nothing up at all, the first item goes up as
  soon as it is added. The swap goes through the usual paths
  (`swapPicked`, `swapJellyfin`; a server-fetched item through
  `swapQueued`, without the URL, its picture as the art), so relays, art
  and refusals work as for any swap; when it fails the item is skipped
  with the reason. A swap without `queueId` (a manual one) leaves the
  queue alone. A member who puts its own link or file up while sitting
  out comes back first; any other queued swap leaves the swapper out.
- **Getting ready** (`QueueController._warm`): every app keeps the one
  item that plays next ready all the time, its own copy, so a skip, Play
  now or the end of the media starts it at once. That is the first Up
  next item, else, with Up next empty, the first "Continues with"
  episode (on the apps that have it); while sitting out only the probe
  of a link this app puts up (its swap reads it). Per
  kind: a Jellyfin item is resolved with this app's account
  (`resolveJellyfinRef`: PlaybackInfo and the item) into
  `SessionCoordinator.warmJellyfin`, which `_playJellyfin` takes instead
  of resolving when the same ref goes up within 35 minutes and the
  account is unchanged; without an account it is the server's `/j` URL
  when `state.relayNext` says the server's login passes it on (see
  "Jellyfin relay"). A link everyone opens is that link; the app that
  puts it up also probes it (`AppYtDlp.probe` with `keep`: kept 35
  minutes instead of 10, a refresh replaces it only once it is in; swaps
  read it from there). A link passed on "through me" and a file only on
  their adder's app (the link, the path; not the host's own file, which
  plays from `/m`). A server-fetched link and others' relayed items have
  nothing to get ready (the relay starts with the swap; see ROADMAP). It
  is resolved as soon as it is first there, again every 30 minutes, and
  dropped when it stops being first.
  **Preload**: once resolved, the stream is opened in a second, hidden
  mpv player (`PlaybackController.preload`, through
  `SessionCoordinator.preloadMedia`): paused at the start, muted, with
  its own video output when the session view is up (media_kit starts a
  player with `vid=no`; the output decodes the first frame), the same
  pins, hwdec and yt-dlp hook as the session player but a 48 MiB forward
  and 8 MiB back cache (`preloadBytes`), mpv log at `error`. One at a
  time; it waits until the media playing has started here
  (`SessionCoordinator.settledMediaId`: opened, failed or nothing to
  open), so it never competes with that open and a preload a swap is
  about to take is never replaced first; a removed, reordered or replaced
  first item swaps or drops it then, a manual swap to something else
  keeps it (still next). A link is opened again at the 30-minute refresh
  (stream URLs expire); a failed preload is not retried until then and
  changes nothing (the usual open follows). When the coordinator opens
  the same URL and headers (`openUrl`), the preload is promoted instead:
  it becomes the session player (log, marks and track observers move
  over, volume, unmute, the full cache pins, shaders), the view swaps to
  its video output (`generation`), and the old player is disposed once
  the view let go of its texture (as on leave). Its buffer comes along,
  so the report sent right after the open already passes the gate: the
  start no longer waits for anyone's open. A promoted player is no
  longer the first mpv of the process, so ffmpeg's HTTP status reaches
  it only when it happens to be the instance ffmpeg logs through (load
  errors themselves are still detected; see "Media"). Off with env
  `SYNC_RELAY_PRELOAD=0`. Measured (`queue_switch_e2e_test`, a fake
  Jellyfin and link host answering after 120 ms at 24 Mbit/s, two
  account holders and a `/j` guest): ⏭ to the server playing 59 to
  86 ms for the next episode and 35 ms for a direct link, against about
  1.5 s cold; at 300 ms and 12 Mbit/s 52 and 103 ms against about 2.9 s.
  `SwitchTrace` (env `SYNC_RELAY_TRACE_SWITCH=1` prints it) times each
  phase of a media change: state, resolved, open, opened or preloaded,
  buffered, playing.
  The row of the item shows a dot on its picture's corner (a tooltip
  says which): hollow waiting, pulsing getting ready (resolving, then
  preloading its first 4 s), filled ready, red failed (tried again every
  2 minutes).
- **Continues with**: not queued, computed here like the next episode:
  with an own-account Jellyfin episode playing, the next three episodes
  of the series (`/Shows/{id}/Episodes`, cached), greyed under Up next,
  "+" adds one. "Clear" hides them for the media playing and keeps its
  next-episode countdown from starting.
- **UI**: `UpNextButton` is one of the player's top-bar controls, before
  chat (see "Player overlay" under Desktop UI), in the look of the
  design's buttons (`UpNextLook`); it shows and hides with the controls,
  which an open popover holds up: the first item's picture (`QueueThumb`,
  the rows' faint box and icon until it arrives), "UP NEXT" over its
  title, a +n count, ⏭ plays it now; without Up next the continuation
  (the episode's image, "NEXT · S1 E8" over its name, ⏭ = next episode);
  nothing when both are empty. Resting on it 600 ms (popover closed)
  shows `UpNextPreview` under it, right edges aligned, in `AppGlass`:
  the picture large, title, second line, "length · added by (avatar)
  name · how" (an episode: series, length, overview), how ready it is
  here (the row's dot and words, else who puts it up) and the `>` key;
  it stays while the mouse is on either, holds the controls up
  (`ControlsHold`) while shown, and a click on it opens the queue. Its
  title opens the queue as a
  `LeafPopover` (package `leaf_widgets`, an overlay rather than a route)
  hanging under it, right edges aligned: the app's glass (`AppGlass`),
  the menus' paddings and row hover, 64 px rows with an 80 px 16:9
  picture, title, second line, "length · added by (avatar) name · how", a drag handle
  (`ReorderableListView`, reordered here at once and sent as `move`), ▶
  and × floating in on hover; "Continues with"; a "Paste a link to add"
  field (focused on open, so the player's keys and Space rest while it
  is up; Esc closes) and a drop zone for links and video files. Being no
  route, it holds the shell's own drop and paste handling off while open
  (`handoffHolds`). "Add to queue" elsewhere, on every source: the Link
  page's button next to Put it up (in the chosen mode), a right-click
  `showAppMenu` (Put it up / Add to queue / Play next) on recent links,
  Jellyfin cards (home rows, libraries, search), series episodes and
  details-panel episodes, Files videos and Schedule cards that can be
  put up, a button in the Jellyfin details panel (right-click: play
  next), and Add to queue / Play next on the drop and paste card (videos
  in order, a link in the Link page's mode). All go through
  `QueueController.add`. None of it offline.

## Desktop UI

One window, `AppShell` (`lib/src/shell/`), whatever the connection state
(online = `SessionState.route` is `session`). The window comes back as it was
(`platform/window_memory.dart`, settings key `windowBounds`, saved on
resize/move/maximize and close): its normal size and maximized state
everywhere, its position where an app may place itself (Windows, X11;
not Wayland, where the compositor decides) and only if it still lands
on a connected display, else centred. Fullscreen is not restored. Motion is shared
(`motion.dart`): one curve (`fastEaseInToSlowEaseOut`, 320 ms), a fade
through for views that replace each other (the old one gone after 35%, the
new one fading and scaling in from 0.985), `showPopover` (cards that fade
and scale in from where they open; they scroll when the window is short)
and `HScroll` (horizontal rows: mouse drag or Shift+wheel; the plain wheel
always scrolls the page). Space never presses a focused button
(`appShortcuts`): it is the ready key. Menus are one widget
(`widgets/app_menu.dart`): `showAppMenu` is a popup route anchored under
the button (over it when the room below is short), frosted dark glass
with a check on the current row, fading and scaling in; arrows move,
Enter picks, Esc or a click outside closes, and being a route it keeps
the player's keys off (fullscreen too). `AppSelect` is the value picker
on it (the current label and a chevron on a soft rounded surface; every
setting that picks one of a few values), `AppMenuButton` the ⋮ action
menu. Material's own menus (the standard controls' track, chapter and
shader menus, the Jellyfin sort and server switch) get the same surface
from `AppMenuStyle.theme`; the uosc controls keep their own flat menus.

- **Party strip** (`party_strip.dart`, 60 px): your avatar (profile card; 42 px like the party's),
  the Library / Schedule / Settings tabs with a growing underline (an
  `HScroll` when narrow), the update indicator, then offline a grey dot,
  "Offline", Join a friend and Host (connect cards; icon-less "Join" and
  "Host" under 1100 px), solo a "Solo · only you" chip, Invite friends
  (the Host card, titled "Invite friends", "Start hosting") and Stop (no
  dialog; no avatars or chat), online the party: `AvatarStack` (host first, then
  ready; spreads on hover; 5 shown, 3 under 1100 px), the server name and
  "ready n/m" (hidden under 1100 px), chat with an unread badge, and Leave
  (asks first). The stack opens the members card (the source line, then
  per member status, route and buffer dot (see "Relay", Stats), host /
  relay pills, "sitting out"; per member force ready, Nudge and Sit
  out (anyone, the host too), your own row Sit out / Join back; "Copy invite
  address": the dialled address when joined; hosting, `inviteAddresses`
  of `NetworkInterface.list` (IPv4, no loopback or link-local, private
  ranges first) with the Host port, and a note that friends outside the
  LAN need a forwarded port or a reachable server). Empty strip space is the window
  drag area; the window buttons sit at its end.
- **Avatars** (`avatar.dart`): `StatusAvatar` draws a ring outside the
  picture with a gap in the background colour (both scale with the size):
  green ready, amber buffering (with a spinner), grey not ready, dimmed
  stale, dimmed with a moon ("away") sitting out (last in the stack); a crown for the host (`members[].host` in the state; your own
  app also knows before the first state) and a tower for the member
  passing the video on. `memberAvatarImage` is the one picture lookup: yours from the
  profile, anyone else's from `coordinator.avatars` by `avatarHash`.
  Colours are local: yours is picked in the profile, others' come from
  their name.
- **Connect cards** (`connect_cards.dart`): Join lists recent servers as
  one-click rows that poll `GET /health` every 10 s while the card is open
  (`health_probe.dart`: online, name, viewer count, "needs update" when
  `proto` differs from ours), then address, port and password. Host takes
  a port and a password (hosted ports as chips) and puts nothing up: what
  to watch is picked in the library afterwards. Submit state (busy,
  cancel, per-card errors) is `ConnectFlow`, owned by the shell so an
  attempt and its error outlive the card; a card closes itself once
  in a server that is not solo. Join says that a friend gives the address
  and that no account or Jellyfin is needed.
- **Profile** (`profile_card.dart`, `screens/home/profile.dart`): a card
  tinted with your colour: picture (hover "Change" opens `CropPicker`:
  drag, wheel or slider zoom, previews at 88/42/24 px, exports a 256 px
  PNG), name edited in place, colour swatches, links to the Settings pages.
  `Profile` stores the name in the connect form and the PNG and colour in
  the `connect_form` box (an old picture path is shrunk once and kept as
  bytes). Online, a name change (once typing settles) or picture change
  goes out through `Profile.push` (`coordinator.updateProfile`).
- **Welcome** (`welcome.dart`): offline the Library opens with
  `WelcomeBand` over the source switch, only for newcomers (no Jellyfin
  account, no recent server, not dismissed with "Don't show again";
  sizes away when online): the app
  icon, Starsync and "Watch together, in sync", then three `WayCard`s,
  Join a friend first (filled), Host, Watch solo (opens Files, or
  Jellyfin when linked); beside the name from 940 px, under it below,
  stacked under 520 px. With no Jellyfin server linked the Jellyfin source
  is `NoJellyfinPanel`: Files and Link cards ("No account needed") and an
  optional Jellyfin card whose "Link a server" opens the sign-in in place.
- **Tabs**: Library (`library_tab.dart`): a source switch (Jellyfin /
  Link / Files, fade through) with the Jellyfin library chips beside it.
  Its state (source, link field and relay mode, selected Jellyfin card,
  last pick) is the shell's `MediaPickerController`
  (`screens/home/media_picker.dart`; picks are sealed `PickedMedia`,
  `picked_media.dart`), so it survives tab switches; it opens on Jellyfin
  with the last put-up selected. Jellyfin cards select on click and open
  `JellyfinDetailsPanel` (`jellyfin/details_panel.dart`, 400 px, slides
  in, docked from 1000 px library width, floating over it below; content
  cross-fades between items): banner, meta, "Put it up · S1E3", mark
  watched / unwatched, remove from Continue, overview, the episode list
  (click picks the episode, double-click puts it up). A double-click on a
  card puts it up (a series: `playableFor`, its next episode). Link
  (`library_link.dart`): paste field, a preview (a page's yt-dlp title,
  uploader, length and thumbnail, else the file name; see "yt-dlp"), the relay modes online ("Through me",
  the controller's default, as the main card; "Everyone fetches it" and
  "Server fetches it" under "Other ways", open while one of them is
  picked, closing it goes back to Through me), and the
  last 12 links put up (`recentLinks` in the `connect_form` box). Files
  is `FilesPage` (`files/`): watched folders (`FolderStore`) scanned in
  an isolate, videos grouped by series; series start collapsed, a header
  click opens one and open ones stay open for the app session
  (`showFilesFolder` opens a folder from outside). With nobody else
  watching (`solo` on the Library, Files and Schedule: offline or solo)
  the buttons say Play, Link has no relay modes and Files no relay notice;
  offline a put-up starts a solo session. Schedule (`schedule/`) is a week of day columns built
  from AniList's airing schedule (`anilist.dart`: pages cached 10 min in
  memory and 1 h on disk, stale data shown on 429 or failure) matched
  against AnimeFlow (`animeflow.dart`, app API with the Jellyfin token;
  `/library` marks shows on Jellyfin it doesn't track, through every AniList
  entry of a season (`anilist_map`: a season AniList splits has several)) into a status per
  episode (`schedule_model.dart`). An aired episode of such a show reads
  "on Jellyfin" only when Jellyfin has it: the season plus AniList
  episode + the run's offset, checked against the series' episodes seen
  by the linked account (`jellyfinEpisodeNumbers`, one request per series
  memoised 3 min; `confirmOnJellyfin` is the pure step); absent reads
  "aired · not on Jellyfin yet", unknown (no linked account, lookup
  failed) "aired", neither with Put it up. Put it up resolves the Jellyfin
  episode (`resolveJellyfinEpisode`: AnimeFlow's numbering, else the
  season and offset, else the air day) and goes through the shell's
  put-up; right-click queues it the same way. Requests and the owner's inbox are in
  `requests_sheet.dart`. It refreshes every minute; mouse drag and
  Shift+wheel scroll the board sideways, the plain wheel scrolls a column.
  Settings (`settings_tab.dart`) has a left nav with icons
  (icon chips under 760 px) over pages of rounded Material cards
  (`SettingsPanel`), one help line under every setting: profile, party &
  network (Host card port and password in the connect form, recent
  servers), player (the shared rows below, custom shader files),
  Jellyfin & integrations (linked servers, AnimeFlow's `/me` via
  `AnimeFlowClient.fromAccounts`, auto-advance), notifications & sounds
  (what pops up; no switches), updates, shortcuts, about.
- **Drop and paste** (`handoff.dart`, `fox_utils`): the shell is one
  `DropTarget` (a "Drop to open" overlay while dragging) and a
  `HardwareKeyboard` handler for Ctrl+V outside a text field (clipboard
  files first, then text). `classifyHandoff` (pure) turns paths or text
  into videos (the Files extensions, `kindOf`), a folder, an http(s) link,
  an image or nothing; videos win over folders, folders over images.
  `HandoffCard` opens as a popover at the pointer: a video goes up through
  the shell's put-up (Play when alone; offline that starts solo) or adds
  its folder to Files; a folder is added to Files and opened; a link fills
  Library → Link (with others the relay mode is picked there). In a
  server, videos and links also get Add to queue / Play next. Images are ignored.
  Nothing happens while a dialog or popover is over the shell.
- **Sounds** (`sfx/`): the coordinator plays an `SfxCue` for ready,
  unready, force-ready, join, leave, swap and others' chat (feed
  events), being sat out by someone (the `kick` sound), a nudge (always,
  whatever its switch), the idle warning, and connection lost / back (once per drop).
  Nothing for what the video already says (play, pause, seeks, the end).
  The sounds are synthesized, not sampled: `synth.dart` renders voices
  (plucked strings with bends, glass and star bells, a singing bowl,
  hollow knocks, wooden clacks, filtered-noise air and stardust, a long
  dark space reverb) to quiet WAVs; `sound_bank.dart` voices every event
  in three presets (`SoundPreset`: Cosmic, Abyss, Wood & glass) in one
  shared key, so mixed presets still agree. `SynthSfx` renders a sound on
  first use into the temp dir (cache key: preset, sound, ready index) and
  plays it on a pool of three audio-only mpv players, at
  `AppSettings.soundVolume` (square curve) unless switched off in
  `soundsOff`. Settings → Notifications & sounds has the volume, the
  overall sound set (`soundPreset`), and per sound a preview, its own set
  (`soundPresetFor`, else the overall one) and a switch; a preview always
  re-renders, so an edited spec plays after a hot reload.
- **Player** (`session_player.dart`): `SessionPlayer` holds the one
  `Video` of the current player (a new `GlobalKey` per player generation).
  The shell keeps it in one layer of the body at one place in the element
  tree: full it fills the body, mini it is 384x216 in a corner (drag it, it
  snaps to the nearest corner with the shared curve). A mode change fades
  the layer out, moves it while invisible and fades it in (with the tabs
  when the full player comes or goes), so the video is never mounted twice
  nor remounted. A tab sends the full player to mini; × on the mini sits
  out (the player unloads and shows the join-back card, `SitOutCard`, over
  the still mounted `Video`); × on that card closes the player, the strip
  brings it back, and joining back with it closed shows the mini. Fullscreen
  is `windowManager.setFullScreen` with the strip hidden (party avatars in
  a corner while paused); F, Esc and double-click on the picture toggle it.
  The player keys (Settings → Keyboard shortcuts) work while the player is
  full and nothing is in front of it; ↑ / ↓ step the volume. Space (ready)
  and Tab (chat) are app-wide: `AppKeys` (`widgets/app_keys.dart`, around
  the shell) takes them first while in a server, unless a text field has
  focus or a dialog or menu is in front. Tab reaches the shell's chat
  toggle through `ChatKey` (the strip while shown, the player in
  fullscreen). The app's shortcuts map Tab / Shift+Tab to nothing, so focus
  never lands on a button Space would press. Something coming up while the player
  is closed opens it: full right after joining or after putting it up
  here, else mini. Both control designs show `NowPlayingTitle` top left
  (`now_playing_title.dart`: 2:3 cover, title, episode line from
  `coordinator.nowPlaying`, art through `artBytes`; it fades through when
  the media changes); the mini shows title and episode without the cover.
  Until playback first starts on a media (server not playing, position
  under 1 s) `StartBanner` (`start_banner.dart`) lies under the controls:
  the banner (else a blur of the cover, else dark), darkened, with cover,
  big title and episode; it fades out on play and stays gone for that
  media; under 320 px tall (the mini) it drops the cover and shrinks the
  title. One status pill (`player_status.dart`) sits centred in the
  action area (see "Player overlay"): `playerStatusFor` (pure) picks the most pressing of
  removed, reconnecting (Cancel), a warn/error health message (Retry),
  connecting (only after 2 s), finished, someone loading (below
  `StateBroadcast.bufferNeed`, the gate's own need at the current
  position: less near the end, none at finished; their avatar with the progress round it), you not
  ready (a click marks you ready) and who everyone waits for (avatars,
  "2/3 ready"); nothing otherwise, info never. Your own `playerError`
  comes right after reconnecting ("Can't play this: ...", Retry reloads
  the video); members with `members[].error` show as "Bob can't play
  this: ..." (before your ready prompt, which then rides in the detail
  line) and are never in "waiting for". A member's new error also toasts
  once (the pill is hidden while playing); avatars carry a red error mark
  and the members card says "can't play this: ...". 34 px avatars, a main line
  and a muted detail line. The pill glass, colour only for problems; it fades through
  between kinds. The mini shows its short line in its hover bar. ⚙ in both
  control designs opens the player settings card (`controls/
  player_settings.dart`, `showPopover`, on `AppGlass`): player design, progress line
  when hidden, upscaling shader, hardware decoding (set live on mpv's
  `hwdec`), subtitle and audio track. The rows (`playerSettingRows`) are
  the same widgets Settings → Player shows; all apply live. The progress
  line (2 px, `AppSettings.progressLine`) is the collapsed uosc timeline;
  for the standard design `ControlsHoverProbe` mirrors media_kit's
  visibility rule (up on mount and mouse movement, down 3 s later or on
  exit), as media_kit does not expose it. Fullscreen adds the
  `WindowButtons` to the top bar while the controls are up (restore
  leaves fullscreen).
- **Player overlay** (full player, both designs; `session_player.dart`):
  everything over the picture has a fixed place on one grid (16 px from
  the sides, the bars' inset), so nothing floats on its own. The top
  bar (part of the controls): now-playing title left; right the Up next
  button (`UpNextButton`), chat, back-to-library or exit fullscreen,
  then the window buttons in fullscreen, all in that design's button
  look. Under it at the right, in fullscreen while paused, the party's
  avatars; with the controls down and unread chat, the unread chip top
  right. The action area: one band just above the bottom controls
  (`_actionArea`; their height per design, 16 px gap), sliding down to
  16 px from the bottom while they are hidden (`AnimatedPositioned`,
  the shell's `ease` / `easeTime`); in it the status pill centred
  (moved left only as far as it must to clear the right end, never
  overlapping it) and at the right end the end card (`UpNextCard`, else
  `EndOfEpisodeCard`, which stay up) or the action pills (Skip OP / ED /
  1:30 over Next episode, `PillGate`). The Jellyfin blocked card sits in
  the middle. Two surfaces: cards and popovers use `AppGlass`
  (`widgets/app_menu.dart`, the menus' recipe: blur, dark tint, hairline
  border, 12 px radius, shadow); pills use `PlayerGlass`
  (`AppGlass.pill`: a stadium, lighter tint, no shadow): the status
  pill, the unread chip and `FloatingPill` (the action pills, 44 px
  tall like the status pill without avatars). The mouse on any
  floating element counts as the mouse on the controls: a
  `ControlsHold` (`controls/controls_probe.dart`) held by
  `ControlsHoldRegion`s (and by the open Up next popover or its preview) keeps either
  design's controls up (`UoscControls.holdBy`; `ControlsHoverProbe.hold`,
  which re-wakes media_kit's controls through their private hover
  handler, the same guarded dynamic call as `keepVideoControlsAwake`),
  and lets them hide on their usual countdown once released.
- **Chat** (`chat_panel.dart`): a 340 px panel sliding in at the right
  (strip button or Tab): chat with avatars; the "Activity" chip (off by
  default, `showActivity`, kept for the app's run only) adds the other
  feed lines between them. Opening focuses the field; Tab or Esc in it
  close the panel and focus goes back where it was. Unread chat badges
  the strip's and both player designs' chat buttons; in fullscreen with
  the controls down and the video not playing a glass chip
  (`PlayerGlass`) top right shows it (while it plays nothing sits on the
  picture).
  **Toasts** (`toasts.dart`): the coordinator's toasts bottom left, with
  the avatar of their `ToastItem.actor` (feed and chat toasts; the app's
  own have none); each
  slides in, stays 5 s, then slides out and collapses its gap. A click on
  a chat toast opens the chat; the others let clicks through. Chat toasts
  follow `AppSettings.chatPopups` (Settings → Notifications: All, Only
  when paused (default), Off); the message is in the chat either way.

Settings persist in two Hive boxes: `connect_form` (last form, recent
servers and links, the profile picture and colour; saved even when a join
fails) and
`settings`. Link media names are a web page's title (see "yt-dlp"), else
derived from the URL path, never containing a query string.

Jellyfin on the desktop (`lib/src/jellyfin/`, over the core client):
- `accounts.dart`: `JellyfinAccounts` (singleton `instance`), one
  `JellyfinAccount` per ServerId (address list, user, token) in the
  `jellyfin` Hive box with a random per-install DeviceId; Client = app name,
  Version = app version, Device = hostname. Only tokens obtained by
  `sign_in.dart` (Quick Connect or password) are stored. Tokens are checked
  on start (`/Users/Me`, each known address in turn): online, offline, or
  expired (kept, shown as Reconnect; never dropped silently). A 401 while
  browsing also marks it expired. `clientFor(serverId)` gives the shared
  signed-in client; `cached()` memoises browse calls for 3 min.
- `sign_in.dart` + `sign_in_panel.dart`: address -> `/System/Info/Public`
  -> Quick Connect (code, poll, cancel) or password; reconnect must hit the
  same ServerId. `accounts_panel.dart` is the Integrations card.
- `browser.dart`: back stack of `BrowseRoute`s (Home rows, library grid,
  series) kept alive under `Visibility(maintainState)` so back keeps
  scroll and loaded pages; search (300 ms debounce) overlays them. Where
  it is (server, stack, a data version that moves after watched-state
  changes so rows reload in place — a change from the details panel, or
  `JellyfinAccounts.watched` once a playback's Stopped report went out —,
  the Continue keys) is a
  `BrowseController` shared with the header chips and the details panel.
  Cards (`cards.dart`) fill the width with whole columns (`fitColumns`);
  rows are `HScroll`s, rows and grids lazy builders; library grids page
  100 at a time with skeletons up to the total count. Images
  (`images.dart`) are `Image.network` at width steps (160..2560) with the
  image tag in the URL, so the image cache key changes only when the
  image does.
- Home (`home_page.dart`, rules in `home_rows.dart`): one Continue row,
  `mergeContinue` over Resume, NextUp and recently played: one card per
  series, ordered by when it was last played, the resume item if that was
  the last thing played in it, else next up; series untouched for 60 days
  drop out unless nothing else is left; "Remove from Continue" clears a
  resume point and hides the series (`dismissed:<serverId>` in the
  `jellyfin` box) until it is played again. "Latest in X" loads single
  items (`groupItems=false`) and `latestCards` makes one series card per
  series (its poster, "S1E1" or "N new"); with `hideReReleases` (setting,
  row menu, default on) items added over 30 days after they aired are left
  out. "Show all" opens the library sorted by date added, newest first.
- Picking an item gives a `JellyfinMedia` (serverId, baseUrl, itemId,
  mediaSourceId?, title, subtitle, runtime; no credentials). The library
  remembers the last pick in the `jellyfin` box and puts it up as a ref
  (`putUpJellyfinMedia`, `swapPicked`); a hosted server gets the relay
  credential (`relayCredentialFor`: the account of the
  item's server, else the default one, not expired; its token with
  exactly `JellyfinAccounts.clientInfo`'s device fields).
- Browser location: every navigation saves the route stack per server
  (`browse:<serverId>` in the `jellyfin` box, `encodeBrowseStack`: ids,
  names and the fields pages start from), so the library and the next
  start open where the browser was. A `BrowseStart` overrides it: "Change
  video" opens the library on the series of the episode playing, its
  season selected and the episode highlighted.

Session controls (the Standard player design): media_kit's
`MaterialDesktopVideoControls` with our bars (`shell/session_player.dart`, pieces in
`screens/session/player_controls.dart`); its own double-click and keys are
off (its double-click pushes a fullscreen route with a second `Video`), the
picture's double-click is a raw pointer observer (`DoubleClickListener`).
The top bar holds the now-playing title, Up next, Change video, chat and back-to-library
(fullscreen: exit, then the window buttons); the bottom bar ends with the
shader button, ⚙ and fullscreen. Its seek bar is off; ours
(`ChapterSeekBar`: chapter diamonds, hover time with the chapter title)
sits in the bottom bar, which is taller by the bar's height (the top bar
keeps its row at the top). A drag sends no hover events, so the bar keeps
the controls up through a guarded dynamic `onHover()` on media_kit's
private controls state (`keepVideoControlsAwake`). Pills (Skip OP / ED /
1:30, Next episode) and cards live outside the auto-hiding controls, in
the action area ("Player overlay"). The
cards stay up; a pill (`PillGate`) shows only while the controls are up
(`ControlsHoverProbe` for this design, `UoscControls.shown` for uosc) or
the mouse is on it (which holds the controls up too), and Skip OP / Skip 1:30 also for 5 s when an offer of
a new kind appears (Skip ED and Next episode never without the controls).
Volume (`controls/volume.dart`, both
designs): mpv's `volume-max` is pinned to `PlaybackController.maxVolume`
(150) per player; `VolumeBar` runs 0..150 with a tick at 100 and the part
above in amber; the wheel and ↑ / ↓ step 5 %, clamped.

The uosc player design (`controls/uosc/`, after mpv's uosc theme;
"Player design" = `AppSettings.mpvControls`, default Standard): the `Video`'s
controls builder wraps both sets in `SessionControlsSwitch`, which follows
the setting live. `UoscControls` is our
own frame (no media_kit controls state): mouse movement shows it, 3 s
without any hides it and the cursor; `hold` keeps it up during a timeline
drag and while a menu route is open, double-click toggles fullscreen.
`UoscTimeline` runs the full width at the bottom: played part filled,
`cacheRect` (position to `buffered`) hatched (`hatchLines`), chapter
diamonds on the top edge, current time and duration in boxes inside it, a
hover tip with the chapter title over the hover time; hidden, it shrinks
to a 2 px line with chapter ticks (faded out when the progress line
setting is off). Above it a row of flat buttons: menu (≡:
change video, chat & activity, reload, mark everyone ready, fullscreen,
leave),
subtitles and audio with track counts, a shader badge ("A HQ", opening the
shared `showShaderMenu`), ready, mark everyone ready, reload; 1:30,
chapters, previous / next episode, change video, volume, ⚙, fullscreen; the
now-playing title top left (`UoscControls.topLeft`, with a top gradient), Up next, chat
and back-to-library (fullscreen: exit) top right, centred on the title. Menus (`showUoscMenu`: a popup route above the button, the
current row highlighted) list tracks and chapters with start times. All
actions are the coordinator's (seeks through `player.seek`, the user path;
`selectTrack`, `skipForward`, `seekTo`); keys and the floating pills are
the same in both sets.

Window chrome is frameless (`window_manager`): the party strip is the drag
area and holds the min/max/close buttons (`widgets/window_buttons.dart`);
fullscreen has no drag area and shows the buttons in the player's top bar.

## Health reporting

Every failure must show in the UI with a cause and a next step; nothing
stalls silently. The app has a `HealthStatus` signal (severity + message)
for connecting, reconnecting, wrong password, version mismatch,
host offline, and starvation ("waiting for X - N.N s buffered").
Errors are logged with a stack trace at the boundary, then turned into a
displayable state. The server's `GET /health` returns JSON (`ok`, `name`,
`proto`, `viewers`, `bytesServed`, `uptimeSecs`); it is unauthenticated, so
it carries nothing sensitive. The Join card's recent servers poll it for live
status.

## App icon and launcher entry

`assets/icon/icon.svg` is the source; `icon_<size>.png` and the Windows
`app_icon.ico` are rendered from it (rsvg-convert, magick). The GTK
application id is `moe.senkochan.watch_together`, which Wayland uses as the
window's `app_id`; compositors take the icon from the `.desktop` file of
that id. A tarball install has none, so on start a Linux release build
(`platform/desktop_entry.dart`, skipped in debug) writes
`~/.local/share/applications/moe.senkochan.watch_together.desktop` (Exec =
the running binary) and the icons into the hicolor theme, only when they
changed. The runner also sets the window icon from the bundle (X11).

## Updater

One implementation, `packages/core/lib/src/updater.dart` (pure Dart, tested
in `packages/core/test/updater_test.dart`), with two front ends: the app and
the dedicated server. Both binaries ship in the same archive, so either one
updates the whole install folder. Reads a manifest (`version`, `protocol`, `url`, optional `sha256`, `notes`)
from `updateManifestUrl`, compares versions, downloads the tarball, checks
sha256 when present, then extracts into a staging dir inside the install
folder (same filesystem, so moves are renames; the folder must be
user-writable). Each top-level entry is moved aside and the new one moved in,
with rollback on failure (writing the running executable fails with ETXTBSY;
rename works). A packaged install is detected by `data/` and `lib/` next to
the binary (app or server, same folder); anything else exits with "update
manually". A manifest whose
protocol is newer than the local one is a required update. Windows apply
renames in-use files to `*.old` (swept on next start); CI tests it against a
running exe on NTFS. The manifest's `assets` maps `linux-x64` /
`windows-x64` to archive URLs; top-level `url` (Linux) is for builds <= 0.2.1. The version is
stamped into both binaries with `APP_VERSION` (`--dart-define` for the app,
`--define` for `dart compile exe`; dev runs report `0.0.0-dev` and the app
skips checks). CLI: `watch-together-server --upgrade` (no display needed;
the shipped `update.sh` / `update.bat` run it), `--check-update` prints only;
it ends with "restart the server to run <version>". `watch_together --upgrade`
does the same from the app binary. In the app, `UpdateController`
(`apps/desktop/lib/src/update/`) runs the same code for the strip's update
indicator, which opens the update card, and restarts the app ("Update and
restart", closing Hive first).
Settings has Check now and an auto-check toggle. The manifest is `updates/manifest.json` in
this repo, written by `tool/release.sh`. Test builds (`X.Y.Z-dev.N`,
`isDevBuild`) also read `devManifestUrl`, the `manifest.json` of the `dev`
prerelease (`tool/dev_release.sh`), and take the newer of the two
(`fetchLatestManifest`); the release X.Y.Z outranks its test builds, so
testers land back on stable. `0.0.0-dev` (a dev run) checks nothing.

## Decisions

- Desktop + mpv only, no web clients: exists because Jellyfin SyncPlay is bad.
- No transcoding: bandwidth is plentiful and the Jellyfin box should not be loaded.
- No roles, friends trust model: simplest thing that fits the use.
- Blank password = open server: the owner chooses between open and private.
- Sit out instead of kick: friends never need to throw someone out, only to
  stop waiting for them; the person stays in chat and can be nudged back.
- Server runs inside the app on an isolate, and ships as a separate compiled
  server: a Flutter binary cannot run headless, so a dedicated server needs
  its own build of `packages/server`. An isolate keeps the UI responsive and
  shares the process (sockets, file paths) without a second executable.
- Host by key, not by address: loopback detection broke behind a
  same-machine reverse proxy or tunnel.
- Server owns the clock; reports never move it: avoids ping-pong between clients.
- Presence gate: a lone viewer must be able to watch; everyone present
  while the video is stopped must ready before it starts.
- Relic for the server, `web_socket_channel` for the client; packages are
  chosen on merit, not locked.
- Plain `ws://`, no TLS: friends use LAN, VPN or a forwarded port; TLS
  (e.g. a reverse proxy) is a documentation item.
- One session per server, id `default`: the map is keyed for later but unused.
- No server storage: config and logs only; media never touches the server
  disk. The relay buffer is memory only and sized like a viewer's buffer
  (about 320 MiB at most), so a small VPS can carry it.
- The relay is the source's own connection through the server, not a
  shared token: a member's Jellyfin sign-in or a link's key never leaves
  their machine. Prior art (Plex Relay, Tailscale DERP) relays as a
  bandwidth-capped fallback on someone else's servers; here the server is
  the owner's, so it carries full quality.
- Avatars by content hash: `state` carries only `avatarHash`; the server keeps
  the bytes of current members in memory and serves them at `/a/...`, which
  clients fetch once per hash (`AvatarCache`). Uplink per broadcast stays
  small whatever the picture size (cap 256 KiB base64 per avatar).
- Media art the same way (`/i/...`, `ArtCache` as `coordinator.art`): the
  member who swapped the media in fetches poster and banner once the state
  shows its swap landed (`media_art.dart`: Jellyfin series/item images with
  its own account; a web link's yt-dlp thumbnail, the one the Library's
  Recent grid shows, as poster and banner both, shrunk to a JPEG under the
  poster cap when larger; else an AniList title search on the parsed
  release name) and sends `art`, so guests without Jellyfin get covers too.
  `coordinator.nowPlaying` derives title, episode line and art hashes from
  `state.media` (`now_playing_info.dart`). A web video
  (`NowPlaying.thumbnail`) shows the media name as is, no episode line, a
  16:9 cover in the controls (a neutral placeholder until the art is up)
  and none on the start card. Art up: poster and banner of one hash mark
  it. Before the art: `isWebVideo` tells it from the media itself (an
  http(s) `url` without a media file extension, or a relayed, non-Jellyfin
  media whose name has no file extension: a page's title), so the layout
  never switches when the thumbnail lands.
