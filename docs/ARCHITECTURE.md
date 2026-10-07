# Architecture

Plain overview first: [HOW-IT-WORKS.md](HOW-IT-WORKS.md). Wire format:
[PROTOCOL.md](PROTOCOL.md). Plans: [ROADMAP.md](ROADMAP.md).

## Packages

| Path | What | Rule |
|---|---|---|
| `packages/core` | protocol messages, sync engine (`SyncEngine`), constants, config, Range parsing, logging, Jellyfin client | pure Dart, no Flutter |
| `packages/server` | Relic HTTP + WebSocket server (`SyncServer`, `ServerHub`, `Session`, media endpoint, Jellyfin relay), the `serve()` entrypoint, `bin/server.dart` (dedicated server) | pure Dart, no Flutter |
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
  dies anyway, the session shows "server crashed: ..." and leaves; Home
  shows it on the Host card (during setup the host attempt fails with it).
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

Three sources, same sync.

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
  direct-plays the static stream; guests use the relay (see "Jellyfin
  relay").

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
  `jf: false`. Else `BlockedPlay`: the session shows "This needs a
  Jellyfin account on <server> (or the host can relay)" with a button that
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
- **Swap panel**: "Change video" in the side panel opens the shared
  `MediaPicker` over the video (`screens/session/swap_panel.dart`); Link
  goes through `mediaForLink`, a Jellyfin pick as a ref, File (host only)
  through `ServerIsolate.setFile` and a matching `swap`.

## Desktop UI

One `HomeScreen` (`screens/home/`) with a single top bar (`top_bar.dart`):
profile chip, Join and Host tabs, the update indicator, Settings /
Integrations / About buttons, and the window drag area and buttons. Only the
selected view is mounted; form state lives in `HomeShell`. Join
(`join_tab.dart`): one compact address/port/password row, then up to 6
Recent server tiles in a grid that adds columns as the window widens. While
the Join tab is visible each tile polls the server's `GET /health` every
10 s (`health_probe.dart`) for online, name, viewer count and a "needs
update" badge when `proto` differs from ours. Host (`host_tab.dart`): the
media picker (`media_picker.dart`: Jellyfin, Link, File; a reusable widget
driven by a `MediaPickerController` whose `selection` is a sealed
`PickedMedia`: `LinkMedia`, `FileMedia` or `JellyfinMedia`, see
`picked_media.dart`) fills the main area; port, password and Host sit in a
340 px column on the right, below the picker under 860 px. With the
Jellyfin source the browser fills the height and can be enlarged, which
turns the column into a one-row bar under it. Text fields have fixed or capped widths (720 px max) so
they stay compact on ultrawide screens. Submit state (busy, cancel,
per-tab errors, server crash) is `ConnectFlow`. Settings (profile, hardware
decoding, experimental mpv-style controls, Jellyfin auto-advance, updates,
video shaders, shortcuts), Integrations
(linked Jellyfin servers) and About open in the same body. Settings persist
in two Hive boxes: `connect_form` (last form and recents; saved even when a
join fails) and `settings`. Link media names are derived from the URL path
and never contain a query string.

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
  mediaSourceId?, title, subtitle, runtime; no credentials). The Host tab
  remembers the last pick in the `jellyfin` box and hosts it as a ref
  (`hostJellyfinMedia`, `ConnectFlow.submit(media:)`); the hosted server
  gets the relay credential (`relayCredentialFor`: the account of the
  item's server, else the default one, not expired; its token with
  exactly `JellyfinAccounts.clientInfo`'s device fields).
- Browser location: every navigation saves the route stack per server
  (`browse:<serverId>` in the `jellyfin` box, `encodeBrowseStack`: ids,
  names and the fields pages start from), so the Host tab, the swap panel
  and the next start open where the browser was. A `BrowseStart` overrides
  it: the swap panel opens on the series of the episode playing, its
  season selected and the episode highlighted.

Session controls: media_kit's `MaterialDesktopVideoControls` with our
bars (`screens/session_screen.dart`, pieces in
`screens/session/player_controls.dart`). Its seek bar is off; ours
(`ChapterSeekBar`: chapter diamonds, hover time with the chapter title)
sits in the bottom bar, which is taller by the bar's height (the top bar
keeps its row at the top). A drag sends no hover events, so the bar keeps
the controls up through a guarded dynamic `onHover()` on media_kit's
private controls state (`keepVideoControlsAwake`). Pills (Skip OP / ED /
1:30, Next episode) and cards live outside the auto-hiding controls, so
they show in fullscreen (whose route renders only the video and controls).

Experimental mpv-style controls (`controls/uosc/`, after mpv's uosc theme;
Settings toggle `AppSettings.mpvControls`, default off): the `Video`'s
controls builder wraps both sets in `SessionControlsSwitch`, which follows
the setting live, in the window and in fullscreen. `UoscControls` is our
own frame (no media_kit controls state): mouse movement shows it, 3 s
without any hides it and the cursor; `hold` keeps it up during a timeline
drag and while a menu route is open, double-click toggles fullscreen.
`UoscTimeline` runs the full width at the bottom: played part filled,
`cacheRect` (position to `buffered`) hatched (`hatchLines`), chapter
diamonds on the top edge, current time and duration in boxes inside it, a
hover tip with the chapter title over the hover time; hidden, it shrinks
to a 3 px line with chapter ticks. Above it a row of flat buttons: menu (≡:
change video, people, reload, mark everyone ready, fullscreen, leave),
subtitles and audio with track counts, a shader badge ("A HQ", opening the
shared `showShaderMenu`), ready, mark everyone ready, reload; 1:30,
chapters, previous / next episode, change video, people, volume,
fullscreen. Menus (`showUoscMenu`: a popup route above the button, the
current row highlighted) list tracks and chapters with start times. All
actions are the coordinator's (seeks through `player.seek`, the user path;
`selectTrack`, `skipForward`, `seekTo`); keys and the floating pills are
the same in both sets.

Window chrome is frameless (`window_manager`): every screen brings its own
drag area and min/max/close buttons (Home's top bar; the session uses
`widgets/window_chrome_bar.dart`; both use `window_buttons.dart`); the session drag layer is `window_drag_layer.dart`.

## Health reporting

Every failure must show in the UI with a cause and a next step; nothing
stalls silently. The app has a `HealthStatus` signal (severity + message)
for connecting, reconnecting, wrong password, version mismatch, kicked,
host offline, and starvation ("waiting for X - N.N s buffered").
Errors are logged with a stack trace at the boundary, then turned into a
displayable state. The server's `GET /health` returns JSON (`ok`, `name`,
`proto`, `viewers`, `bytesServed`, `uptimeSecs`); it is unauthenticated, so
it carries nothing sensitive. Home's recent-server tiles poll it for live
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
(`*.old` rename, swept on next start) exists but is untested. The version is
stamped with `--dart-define=APP_VERSION` (dev runs report `0.0.0-dev` and skip
checks). `watch_together --upgrade` (or the shipped `update.sh`) runs it from
the CLI; `UpdateController` runs the same code for Home's update indicator,
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
- No server storage: config and logs only; media never touches the server disk.
- Avatars ride in the 1 Hz `state` broadcast (cap 256 KiB base64 per avatar):
  simple, costs host uplink; hash-based serving is on the roadmap.
