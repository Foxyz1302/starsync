# Architecture

Plain overview first: [HOW-IT-WORKS.md](HOW-IT-WORKS.md). Wire format:
[PROTOCOL.md](PROTOCOL.md). Plans: [ROADMAP.md](ROADMAP.md).

## Packages

| Path | What | Rule |
|---|---|---|
| `packages/core` | protocol messages, sync engine (`SyncEngine`), constants, config, Range parsing, logging | pure Dart, no Flutter |
| `packages/server` | Relic HTTP + WebSocket server (`SyncServer`, `ServerHub`, `Session`, media endpoint), the `serve()` entrypoint, `bin/server.dart` (dedicated server) | pure Dart, no Flutter |
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
all sockets and returns, and the isolate exits.

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
  `--config`; default port 8080) into the same map and calls `serve`;
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

- **Transport** is `playing` or `held`. The server owns the clock:
  `positionAt(now) = position + (playing ? now - serverTime : 0)`.
  Reports from clients never move it. Only seek, swap and gate transitions
  write `position`/`serverTime` and bump `eventId`.
- **Reports**: clients send `position`, `buffered`, `eventId` every 1 s. The
  server stores `buffered` and liveness; a report with `eventId` older than
  current has its position ignored.
- **Ready gate** (HELD to PLAYING): the in-set is non-empty, every in-set
  member is ready, fresh and has `buffered >= 4 s` (`minBufferSecs`), and
  quorum holds: in-set size >= 2, unless at most one member is fresh. So a
  lone viewer plays alone; with a second viewer present one Space waits for the
  other. Joining members start with `inSet=false, ready=false` and never block.
  Disconnect removes from the set; swap clears everyone.
- **Pause**: while PLAYING, any in-set member who becomes not ready, under
  4 s buffered or stale flips the server to HELD (feed action `pause` by `server`).
  Recovery resumes by itself when the gate passes.
- **Seek**: allowed from any member in any transport; the server writes the
  position and bumps `eventId`; flags are untouched. Clients diff each `state`
  broadcast by `eventId` (`StateDiff`): new event means seek to the computed
  server position, transport change means play/pause. Between events: drift
  over 5 s for more than 2 s seeks, ahead by more than 1.5 s sets rate 0.95
  until level, otherwise nothing. Local seeks are detected by the coordinator
  polling mpv position once per second (`_detectUserSeek`, jump over 2 s and
  more than 2 s from the server position) and sent as a `seek` intent; a retry
  (`_checkSeekLanded`) re-applies a server seek that has not landed after 1.5 s.
  Known roughness: see ROADMAP.
- **Liveness**: WS ping every 5 s; silent over 15 s means stale (out of the
  gate, `stale` feed); over 30 s the socket is closed and the member removed.
  Closed sockets are polled with `isClosed` every second: Relic's server-side
  `onDone` does not fire for dead peers, so presence never relies on it.
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
  the clock is server time, and remote clock offset is not corrected (clients
  assume their clock matches the server's).

Additive wire changes only; bump `proto` and PROTOCOL.md in the same commit.

## Media

Two sources, same sync.

- **Link**: the media field holds an http(s) URL. It travels as `media.url`
  in `swap` and `state`, and as `mediaUrl` in `welcome`. Each app plays it
  directly; the server is only the clock.
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

mpv settings (`PlaybackController`): `Player` with `bufferSize` 64 MiB,
`libass` on; pinned via runtime property: `demuxer-readahead-secs=10`,
`cache-secs=10`, `stream-lavf-o=reconnect_streamed=1,reconnect_on_http_error=1,reconnect_delay_max=4`
(comma form; this mpv build rejects colon-joined). media_kit has no public
`setProperty`; the code calls it through a guarded dynamic call on
`player.platform`. Hardware decoding comes from Settings (auto, off, custom)
and is passed to the `VideoController`; env `SYNC_RELAY_HWDEC` (e.g. `no`)
overrides it. It is read per player, so a change applies on the next join or
Reload video.

Player lifecycle: the `Player` and its `VideoController` live for one
session: created on join, disposed on leave, replaced by `recreate()` for
"Reload video" (button or Ctrl+R; volume kept). `openUrl` opens with `play: false`; play/pause/seek/rate come only from
`StateDiff` actions or the play gate (`localPlayAllowed`: self in-set and
ready). A server seek within 0.5 s of the current position is skipped. `leave()`
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

Never unmount GPU-textured widgets (avatar images) on a transport-gated
branch: teardown races mpv's frame upload and the window goes black. Keep them
mounted and skip painting (`Visibility` with `maintainState`).

## Desktop UI

One `HomeScreen` (`screens/home/`) with a nav rail: Home (profile chip, Join
card, Host card, up to 6 Recent server chips for one-click rejoin), Settings
(profile, hardware decoding, updates, shortcuts, shaders "coming soon"),
Integrations (Jellyfin "coming soon") and About. The update indicator sits on
Home. Settings persist in two Hive boxes: `connect_form` (last form and
recents; saved even when a join fails) and `settings`. Link media names are
derived from the URL path and never contain a query string.

Window chrome is frameless (`window_manager`): every screen brings its own
drag area and min/max/close buttons (`widgets/window_chrome_bar.dart`,
`window_buttons.dart`); the session drag layer is `window_drag_layer.dart`.

## Health reporting

Every failure must show in the UI with a cause and a next step; nothing
stalls silently. The app has a `HealthStatus` signal (severity + message)
for connecting, reconnecting, wrong password, version mismatch, kicked,
host offline, and starvation ("waiting for X - N.N s buffered").
Errors are logged with a stack trace at the boundary, then turned into a
displayable state. The server's `GET /health` returns JSON (`ok`, `name`,
`proto`, `viewers`, `bytesServed`, `uptimeSecs`); it is unauthenticated and
the app does not read it.

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
