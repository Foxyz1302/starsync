# Architecture

Plain overview first: [HOW-IT-WORKS.md](HOW-IT-WORKS.md). Wire format:
[PROTOCOL.md](PROTOCOL.md). Plans: [ROADMAP.md](ROADMAP.md).

## Packages

| Path | What | Rule |
|---|---|---|
| `packages/core` | protocol messages, sync engine (`SyncEngine`), constants, config, Range parsing, logging, Jellyfin client | pure Dart, no Flutter |
| `packages/server` | Relic HTTP + WebSocket server (`SyncServer`, `ServerHub`, `Session`, media endpoint, relay buffer, Jellyfin relay), the `serve()` entrypoint, `bin/server.dart` (dedicated server) | pure Dart, no Flutter |
| `apps/desktop` | Flutter app: UI, `SyncClient`, `SessionCoordinator`, `PlaybackController` (media_kit/mpv), `ServerIsolate`, updater | ships with `watch-together-server` |
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
  Stop (leave, close, cancel during setup, a failed own join, being kicked)
  sends `stop`, waits up to 3 s for exit, then kills the isolate.
- **Dedicated server**: `bin/server.dart` compiled with `dart compile exe`
  and shipped next to the app as `watch-together-server`. It parses flags
  (`--port`, `--secret`, `--name`, `--media`, `--advertise-host`,
  `--jellyfin <file>`, `--config`; default port 8080) into the same map and calls `serve`;
  SIGINT and SIGTERM stop it. A Flutter binary cannot run without a
  display, which is why the server is its own build.

`SyncServer` runs a 1 s heartbeat: stale sweep, closed-socket sweep, silent
socket drop, state + feed broadcast. There is one session, id `default`.

Passwords: the default secret is empty, which means an open server (a
warning is logged). Otherwise one shared secret, compared at hello.

Host: when hosting, the app generates a random `hostKey` per hosting, puts
it in the server config and sends it in its own `hello`. The member whose
key matches is the host and cannot be kicked. The address a connection
comes from plays no part (so a reverse proxy or tunnel on the same machine
does not make everyone the host). The dedicated server has no key, so it
has no host. Kick = revoke token, send `kicked`, close; the person may
rejoin at once with a new token.

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
  older than current has its position ignored.
- **Ready gate** (HELD to PLAYING): the in-set is non-empty, every in-set
  member is ready, fresh and has `buffered >= need`, and quorum holds: in-set
  size >= 2, unless at most one member is fresh. `need` is 4 s
  (`minBufferSecs`), or near the end what is left minus 2 s (`endSlackSecs`,
  floor 0), since mpv cannot buffer past the end. So a lone viewer plays
  alone; with a second viewer present one Space waits for the other. Joining
  members start with `inSet=false, ready=false` and never block. Disconnect
  removes from the set; swap clears everyone.
- **Pause**: while PLAYING, any in-set member who becomes not ready, under
  `need` buffered or stale flips the server to HELD (feed action `pause` by
  `server`). Recovery resumes by itself when the gate passes.
- **End**: while PLAYING with a known duration, reaching it sets FINISHED
  (feed `finished` by `server`, position = duration). Clients pause where they
  are; FINISHED never auto-resumes. A seek turns it into HELD at the new
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
  A stale member that was ready goes back into the set with its next frame.
  Closed sockets are polled with `isClosed` every second: Relic's server-side
  `onDone` does not fire for dead peers, so presence never relies on it.
- **Resume**: a reconnecting client sends its previous token as
  `hello.resume`. If the server still has that member (an unclean drop it has
  not noticed), the new socket takes it over: same token, member id, ready
  flag and media URL (the player keeps streaming), no join/leave feed, and the
  dead socket is closed without removing the member. An unknown or kicked
  token joins as a new member.
- **Client policies**: no state broadcast for 5 s means connection lost, clear
  the server state and reconnect every 1.5 s until cancelled (an epoch counter makes
  a cancelled attempt stale) or kicked. After a reconnect the ready flag is
  restored from the server's state. Cancel during setup aborts the join.
  Closing the window leaves gracefully (2 s timeout).
- **Idle** (`IdleTracker`): measured from the later of the last input and the
  moment playback stopped. While HELD and self ready: warning at 8 min,
  auto-unready at 10 min, and never less than 2 min after the warning.
- **Deviations from Syncplay**: clock never follows the slowest watcher; no
  pause-on-leave; anyone can force ready/unready (all or one); quorum gate;
  the clock is server time (clients correct for their offset to it).

Additive wire changes only; bump `proto` and PROTOCOL.md in the same commit.

## Media

Three sources, same sync. Any of them can also go through the relay
(below).

- **Link**: the media field holds an http(s) URL. It travels as `media.url`
  in `swap` and `state`, and as `mediaUrl` in `welcome`. Each app plays it
  directly; the server is only the clock. A pasted link that
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
| bad / unknown token, kicked, unknown session | 401, 403, 410 |

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
`stream-lavf-o=reconnect_streamed=1,reconnect_on_http_error=1,reconnect_delay_max=4`
(comma form; this mpv build rejects colon-joined). The cache is in RAM:
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
mpv logs at `v`: OpenGL init logs `GL_VERSION` under `libmpv_render`
(`RenderMode.gpu`; "suspected software renderer" means llvmpipe,
`softwareGl`); none within 1.5 s of the controller being ready means the
software path (`software`, where shaders do nothing; the shader toast, the
menu and Settings say so). After startup the `v` level adds no steady
traffic (measured: 0 messages over 5 s of playback). The hardware path is
fragile: media_kit borrows whatever EGL context GDK left current on the main
thread (upstream media-kit#1404), so an X11 session or a Flutter/GDK change
can silently fall back to software.

Player lifecycle: the `Player` and its `VideoController` live for one
session: created on join, disposed on leave, replaced by `recreate()` for
"Reload video" (button or Ctrl+R; volume kept). `openUrl` opens with `play: false`; play/pause/seek/rate come only from
`StateDiff` actions, the play gate (`localPlayAllowed`: self in-set and
ready) or the user's own seeks (see Sync model). A server seek within 0.5 s of the current position is skipped. `leave()`
stops the player (otherwise audio keeps playing). On media change
(`mediaId` bump) the coordinator opens the new URL and `StateDiff` seeks to 0,
holds and resets rate.

Frozen picture: `FrameWatchdog` samples about once a second. It hashes a
small capture of the compositor's centre (`ShownFrameProbe`) and suspects a
freeze when position advances while that hash stays constant for 3 s. Two
differing mpv `screenshot-raw` frames show the decoder is still producing
pictures, which confirms the freeze (a still scene is dismissed). A confirmed
freeze reloads the video with a toast. It fires once until the picture moves
again for 10 s, so it cannot loop. Seeks, pause, buffering and a hidden window
disarm it.

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
  decides). Without any opening and with media over 20 min, "Skip 1:30"
  during the first 6 min.
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
  `/Items`, search, seasons, episodes), image URLs (tag + maxWidth, no token
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
  `serverId` equals the credential's. Only that item is relayed, only to a
  valid, unkicked viewer token: no open proxy.
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
the source, `packages/server/lib/src/relay_buffer.dart`,
`relay_routes.dart`; wire in [PROTOCOL.md](PROTOCOL.md) "Relay").

What gets relayed (`SessionCoordinator.swapPicked`):

| Put up | Others get it |
|---|---|
| File, by the host | `/m` from the hosting app (no relay) |
| File, by anyone else | relayed from that member's computer |
| Link, "Everyone fetches it" (default) | each app fetches it |
| Link, "Server fetches it" | the server reads it once into the buffer; the link is never broadcast; refused on an open server (it would fetch any address it can reach for anyone) |
| Link, "Through me" | relayed from that member's computer; for links only they can open |
| Jellyfin item (browser pick or pasted link) | own account first, then the server's login (`/j`), then relayed from the member who put it up (with their sign-in, or the pasted link's key, which stays on their machine) |

Relayed links must be one file the relay can range-read: a `text/*`
response (YouTube and other pages, which only the player resolves) is
refused before the swap.

How bytes move:
- The source dials `/r/.../source` (outbound, so NAT/CGNAT are fine) and
  answers the server's pulls from the file or the URL (`RelaySource`,
  `FileRelayBytes`, `HttpRelayBytes`; a Jellyfin source sends its own
  `Authorization` header from this machine). Viewers only ever talk HTTP
  to the server, so the source never sees mpv's request pattern.
- The server keeps one `RelayBuffer` per relayed media: 1 MiB slices in
  memory, filled by one sequential pull at a time. Kept: the first and
  last 2 MiB (container indexes; mpv reads both on open and on seeks),
  64 MiB behind the slowest viewer and 256 MiB past the furthest, the
  same as each viewer's mpv buffer (`PlaybackController`), so a skip
  inside the viewers' buffer window is served from memory. Evicted by
  distance from the viewers, never LRU. With 2+ viewers the source sends
  each byte about once.
- Filling: a viewer blocked on a slice first (oldest wait first, handing
  the source over at slice boundaries), then the pinned slices, then
  read-ahead from the slowest viewer. Nothing is fetched while nobody
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
  token after a resume); a different file size drops the buffer.
  `state.media.relay.live` follows the channel, and viewers show "waiting
  for <name> to pass the video on" while it is down.

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
  list shows "via host" for members whose `jf` is false for the current
  item. A reconnect to the same item with `OwnPlay` keeps playing as is.
- **Progress** (`JellyfinProgressReporter`, `OwnPlay` only): Playing once the
  file is open and mpv has picked its tracks; Progress every 10 s and at
  once on pause, resume, a seek (position more than 3 s from where playback
  should be) or a track change; Stopped on swap, leave, kick, window close
  (bounded to 1.5 s inside the graceful leave) and at `finished` (position =
  duration, so Jellyfin marks it played); seeking back from the end sends
  Playing again. Reports carry `PositionTicks`, `IsPaused` and mpv's
  `aid`/`sid` as Jellyfin stream indices (`jellyfinIndexForMpvTrack`,
  `SubtitleStreamIndex -1` = off). They go out in order on one chain;
  failures are logged, one quiet toast per session, playback is never
  touched; a 401 marks the account expired and ends reporting.
- **Episodes**: with `OwnPlay` on an episode, `adjacentEpisodes` (one
  `/Shows/{id}/Episodes` call; `episodeBefore` / `episodeAfter`) gives the
  previous and next episode. The controls show previous / next buttons
  (also `<` `>`, Shift+P / Shift+N); from `nextPromptStart` (the ending's
  start when one is known, see "Skip rules", else the last 2 min of the
  runtime) a floating "Next episode" pill shows outside the auto-hiding
  controls. Auto-advance still waits for `finished`. Any
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
  and with it every countdown.
- **Tracks**: the controls' Audio and Subtitles buttons list
  `PlaybackController.tracks`. A pick is applied, reported, and saved as a `TrackChoice`
  (language, title, codec, channels, forced/HI: from the Jellyfin streams
  with `OwnPlay`, else from mpv's track list) per series and as the global
  fallback in the `track_prefs` Hive box. On the next Jellyfin item it is
  matched with `matchTrack` against the source's streams (mapped to mpv ids
  with `mpvTrackId`) or mpv's track list, and selected locally. Nothing goes
  on the wire.
- **Change video**: the player's "Change video" opens the Library tab
  (the shared `MediaPicker`, `screens/session/swap_panel.dart`); Link
  goes through `mediaForLink`, a Jellyfin pick as a ref, File (host only)
  through `ServerIsolate.setFile` and a matching `swap`.

## Desktop UI

One window, `AppShell` (`lib/src/shell/`), whatever the connection state
(online = `SessionState.route` is `session`). Motion is shared
(`motion.dart`): one curve (`fastEaseInToSlowEaseOut`, 320 ms), a fade
through for views that replace each other (the old one gone after 35%, the
new one fading and scaling in from 0.985), `showPopover` (cards that fade
and scale in from where they open; they scroll when the window is short)
and `HScroll` (horizontal rows: mouse drag, the vertical wheel scrolls them
sideways until an end, then the page).

- **Party strip** (`party_strip.dart`, 60 px): your avatar (profile card),
  the Library / Schedule / Settings tabs with a growing underline (an
  `HScroll` when narrow), the update indicator, then offline Join and Host
  (connect cards), online the party: `AvatarStack` (host first, then
  ready; spreads on hover; 5 shown, 3 under 1100 px), the server name and
  "ready n/m" (hidden under 1100 px), chat with an unread badge, and Leave
  (asks first). The stack opens the members card (status, host / relay
  pills, "via host", force ready, kick). Empty strip space is the window
  drag area; the window buttons sit at its end. Debug builds add a button
  that opens the layout mock (`screens/demo/`).
- **Avatars** (`avatar.dart`): `StatusAvatar` draws a ring outside the
  picture with a gap in the background colour (both scale with the size):
  green ready, amber buffering (with a spinner), grey not ready, dimmed
  stale; a crown for the host (only your own app knows it hosts: the
  state has no host flag) and a tower for the member passing the video
  on. `memberAvatarImage` is the one picture lookup: yours from the
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
  online.
- **Profile** (`profile_card.dart`, `screens/home/profile.dart`): a card
  tinted with your colour: picture (hover "Change" opens `CropPicker`:
  drag, wheel or slider zoom, previews at 88/42/24 px, exports a 256 px
  PNG), name edited in place, colour swatches, links to the Settings pages.
  `Profile` stores the name in the connect form and the PNG and colour in
  the `connect_form` box (an old picture path is shrunk once and kept as
  bytes). Online, a name change (once typing settles) or picture change
  goes out through `Profile.push` (`coordinator.updateProfile`).
- **Tabs**: Library (`library_tab.dart`) is the media picker
  (`media_picker.dart`: Jellyfin, Link, File; a `MediaPickerController`
  whose `selection` is a sealed `PickedMedia`, see `picked_media.dart`)
  with "Put it up for everyone" (`screens/session/swap_panel.dart`); it
  starts on what was last put up. Offline it only browses. Schedule is a
  placeholder. Settings (`settings_tab.dart`) has a left nav (chips under
  760 px) over the settings panels (`screens/home/settings_page.dart`):
  profile, player (hardware decoding, mpv-style controls, shaders),
  Jellyfin & integrations (linked servers, auto-advance), updates,
  shortcuts, about.
- **Player** (`session_player.dart`): `SessionPlayer` holds the one
  `Video` of the current player (a new `GlobalKey` per player generation).
  The shell keeps it in one layer of the body at one place in the element
  tree: full it fills the body, mini it is 384x216 in a corner (drag it, it
  snaps to the nearest corner with the shared curve). A mode change fades
  the layer out, moves it while invisible and fades it in (with the tabs
  when the full player comes or goes), so the video is never mounted twice
  nor remounted. A tab sends the full player to mini; × on the mini closes
  it (muted, still in the server) and the strip brings it back. Fullscreen
  is `windowManager.setFullScreen` with the strip hidden (party avatars in
  a corner while paused); F, Esc and double-click on the picture toggle it.
  The player keys (Settings → Keyboard shortcuts) work while the player is
  full and nothing is in front of it. Something coming up while the player
  is closed opens it: full right after joining or after putting it up
  here, else mini. While held, a pill under the picture names who
  everyone waits for, or says "Waiting for you · press Space" (a click
  marks you ready); the mini shows it in its hover bar.
- **Chat** (`chat_panel.dart`): a 340 px panel sliding in at the right
  (strip button or Tab): chat with avatars, other activity as quiet lines.
  **Toasts** (`toasts.dart`): the coordinator's toasts bottom left, with
  the actor's avatar when the text starts with a member's name; each
  slides in, stays 5 s, then slides out and collapses its gap.

Settings persist in two Hive boxes: `connect_form` (last form, recents and
the profile picture and colour; saved even when a join fails) and
`settings`. Link media names are derived from the URL path and never
contain a query string.

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
  series, detail) kept alive under `Visibility(maintainState)` so back keeps
  scroll and loaded pages; search (300 ms debounce) overlays them. Cards
  (`cards.dart`) fill the width with whole columns (`fitColumns`); rows and
  grids are lazy builders; library grids page 100 at a time with skeletons
  up to the total count. Images (`images.dart`) are `Image.network` at
  width steps (160..2560) with the image tag in the URL, so the image cache
  key changes only when the image does. An inspector pane follows
  hover/focus from 1400 px browser width.
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

Session controls: media_kit's `MaterialDesktopVideoControls` with our
bars (`shell/session_player.dart`, pieces in
`screens/session/player_controls.dart`); its own double-click and keys are
off (its double-click pushes a fullscreen route with a second `Video`), the
picture's double-click is a raw pointer observer (`DoubleClickListener`).
The top bar holds the title, Change video, chat and back-to-library. Its seek bar is off; ours
(`ChapterSeekBar`: chapter diamonds, hover time with the chapter title)
sits in the bottom bar, which is taller by the bar's height (the top bar
keeps its row at the top). A drag sends no hover events, so the bar keeps
the controls up through a guarded dynamic `onHover()` on media_kit's
private controls state (`keepVideoControlsAwake`). Pills (Skip OP / ED /
1:30, Next episode) and cards live outside the auto-hiding controls, so
they stay up when the controls hide.

Experimental mpv-style controls (`controls/uosc/`, after mpv's uosc theme;
Settings toggle `AppSettings.mpvControls`, default off): the `Video`'s
controls builder wraps both sets in `SessionControlsSwitch`, which follows
the setting live. `UoscControls` is our
own frame (no media_kit controls state): mouse movement shows it, 3 s
without any hides it and the cursor; `hold` keeps it up during a timeline
drag and while a menu route is open, double-click toggles fullscreen.
`UoscTimeline` runs the full width at the bottom: played part filled,
`cacheRect` (position to `buffered`) hatched (`hatchLines`), chapter
diamonds on the top edge, current time and duration in boxes inside it, a
hover tip with the chapter title over the hover time; hidden, it shrinks
to a 3 px line with chapter ticks. Above it a row of flat buttons: menu (≡:
change video, chat & activity, reload, mark everyone ready, fullscreen,
leave),
subtitles and audio with track counts, a shader badge ("A HQ", opening the
shared `showShaderMenu`), ready, mark everyone ready, reload; 1:30,
chapters, previous / next episode, change video, volume, fullscreen; chat
and back-to-library (fullscreen: exit) top right. Menus (`showUoscMenu`: a popup route above the button, the
current row highlighted) list tracks and chapters with start times. All
actions are the coordinator's (seeks through `player.seek`, the user path;
`selectTrack`, `skipForward`, `seekTo`); keys and the floating pills are
the same in both sets.

Window chrome is frameless (`window_manager`): the party strip is the drag
area and holds the min/max/close buttons (`widgets/window_buttons.dart`);
fullscreen has neither.

## Health reporting

Every failure must show in the UI with a cause and a next step; nothing
stalls silently. The app has a `HealthStatus` signal (severity + message)
for connecting, reconnecting, wrong password, version mismatch, kicked,
host offline, and starvation ("waiting for X - N.N s buffered").
Errors are logged with a stack trace at the boundary, then turned into a
displayable state. The server's `GET /health` returns JSON (`ok`, `name`,
`proto`, `viewers`, `bytesServed`, `uptimeSecs`); it is unauthenticated, so
it carries nothing sensitive. The Join card's recent servers poll it for live
status.

## Updater

`apps/desktop/lib/src/update/updater.dart` (no Flutter imports, unit tested).
Reads a manifest (`version`, `protocol`, `url`, optional `sha256`, `notes`)
from `updateManifestUrl`, compares versions, downloads the tarball, checks
sha256 when present, then extracts into a staging dir inside the install
folder (same filesystem, so moves are renames; the folder must be
user-writable). Each top-level entry is moved aside and the new one moved in,
with rollback on failure (writing the running executable fails with ETXTBSY;
rename works). A packaged install is detected by `data/` and `lib/` next to
the binary; anything else exits with "update manually". A manifest whose
protocol is newer than the local one is a required update. Windows apply
renames in-use files to `*.old` (swept on next start); CI tests it against a
running exe on NTFS. The manifest's `assets` maps `linux-x64` /
`windows-x64` to archive URLs; top-level `url` (Linux) is for builds <= 0.2.1. The version is
stamped with `--dart-define=APP_VERSION` (dev runs report `0.0.0-dev` and skip
checks). `watch_together --upgrade` (or the shipped `update.sh`) runs it from
the CLI; `UpdateController` runs the same code for the strip's update indicator,
which opens the update card, and restarts the app ("Update and restart").
Settings has Check now and an auto-check toggle. The manifest is `updates/manifest.json` in
this repo, written by `tool/release.sh`.

## Decisions

- Desktop + mpv only, no web clients: exists because Jellyfin SyncPlay is bad.
- No transcoding: bandwidth is plentiful and the Jellyfin box should not be loaded.
- No roles, friends trust model: simplest thing that fits the use.
- Blank password = open server: the owner chooses between open and private.
- The host cannot be kicked: the server dies with the host anyway.
- Server runs inside the app on an isolate, and ships as a separate compiled
  server: a Flutter binary cannot run headless, so a dedicated server needs
  its own build of `packages/server`. An isolate keeps the UI responsive and
  shares the process (sockets, file paths) without a second executable.
- Host by key, not by address: loopback detection broke behind a
  same-machine reverse proxy or tunnel.
- Server owns the clock; reports never move it: avoids ping-pong between clients.
- Quorum gate: a lone viewer must be able to watch; two or more must start together.
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
