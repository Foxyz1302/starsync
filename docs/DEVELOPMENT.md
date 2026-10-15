# Development

Layout and rules: [ARCHITECTURE.md](ARCHITECTURE.md).

## Build

Needs the Flutter SDK (beta channel, Dart 3.13+) and, for the Linux desktop
build, the usual GTK toolchain (clang, cmake, ninja, pkg-config, libgtk-3-dev).
mpv libraries come from `media_kit_libs_video`. `media_kit_video` is the patched copy in
`third_party/media_kit_video` (see its `starsync/README.md`); test video
output changes under X11 (`GDK_BACKEND=x11`, ideally a real X11 session)
and Wayland. `flutter_soloud` (the app's
sounds) compiles SoLoud and miniaudio from source in its build hook with
that C++ toolchain (MSVC on Windows); it needs no audio dev headers (miniaudio
loads ALSA / PulseAudio / JACK at run time) and, with `no_xiph_libs` set in
the desktop pubspec, downloads nothing. `fox_utils` (drag & drop,
clipboard files and images; native Linux/Windows plugin) is the owner's
shared package, a git dependency pinned to a tag of
`git.example.org/Foxyz/fox_utils`: bump it by tagging there and changing
`ref` in the desktop pubspec.

```
cd apps/desktop && flutter pub get && flutter run -d linux
cd apps/desktop && flutter build linux --release --dart-define=APP_VERSION=<x.y.z>
tool/package_linux.sh [--skip-build] [--noupload]    # dist/*.tar.gz
powershell -File tool/package_windows.ps1 [-SkipBuild]  # dist/*.zip (on Windows)
cd packages/server && dart compile exe --define=APP_VERSION=<x.y.z> bin/server.dart -o starsync-server
```

`APP_VERSION` defaults to `0.0.0-dev`; the packagers stamp it from the
desktop pubspec into both the app and the server. `tool/package_linux.sh`
also passes `GIT_COMMIT` (what the app shows: "Updater" in
[ARCHITECTURE.md](ARCHITECTURE.md)). Setting `DISCORD_WEBHOOK_URL` makes the packager post the
tarball to Discord (never commit it). The packager always compiles the
dedicated server (with the Flutter SDK's `dart`) into the tarball as
`starsync-server`, also with `--skip-build`. The app binary is `starsync`
(`BINARY_NAME`; Linux application id `dev.foxyz.starsync`), the archive
`dist/starsync-<version>-linux-x64.tar.gz` / `-windows-x64.zip` with one
top folder `starsync-<version>/`; it also carries the names up to 1.2.x
(`watch_together`, `watch-together-server`: launchers on Linux, copies on
Windows; "Updater" in [ARCHITECTURE.md](ARCHITECTURE.md)). The Dart
package of the app is `starsync` (`package:starsync/...`).

## Dev loop

Run a server without the app, then point apps at it:

```
dart run packages/server/bin/server.dart --port 8080 --secret x [--media FILE]
```

This is the same `serve()` the app runs when hosting and the same code as
the dedicated binary. Prints `READY port=... name=...` and stops on SIGINT
or SIGTERM. Then Join from one or more apps at `127.0.0.1:8080`. Or just
Host from the app. mpv env override:
`SYNC_RELAY_HWDEC` (wins over the Settings choice). `SYNC_RELAY_VO` has no
effect with embedded video: media_kit forces `vo=libmpv`. `SYNC_RELAY_PRELOAD=0`
turns Up next's preload player off; `SYNC_RELAY_TRACE_SWITCH=1` prints
the timings of each media change (`SwitchTrace`).

Two instances on one machine: `STARSYNC_PROFILE=<name>` (letters, digits,
`-`, `_`; at most 32) gives an instance its own Hive boxes (settings,
profile, connect form, window bounds, folders, Jellyfin sign-ins, the
client id: two instances without it are one install, and the second takes
the first's member over) and logs under
`<app support>/profiles/<name>/`, and ` [<name>]` in the window title;
yt-dlp, shaders and caches stay shared (`AppDirs`, ARCHITECTURE "Desktop
UI"). Without it nothing changes. Run one plain instance and one with
`STARSYNC_PROFILE=b` (`flutter run -d linux` passes the environment on, or
start the built binary twice); one hosts, the other joins
`127.0.0.1:<port>`, or both join a `dart run` server. An unusable name is
ignored with a warning in the log.

Harnesses in `tool/` (own `pubspec.yaml`, `dart run tool/<name>.dart`):
`range_logger` (serve a file and log every Range request), `shaper`
(bandwidth cap, latency, `--kill-after` for outage tests), `fake_viewer`
and `e2e_check` (simulated viewers against a live server).

## Tests

Three suites, run from each package's folder:

- `cd packages/core && dart test` (a few seconds): protocol round-trips,
  what a player opens for a page (`YtDlpPlay`) and the cookie notes of a
  failed resolve against a stand-in yt-dlp (`cookies_test`, D11),
  the sync engine (clock, gate, presence and grace, correction, end of
  file), the `PresencePolicy` table, queue model and what's next (who
  puts an item up, the countdown on a fake clock), the library's L1
  (release and folder names, `groupLocal` over a real anime folder's
  names: shows across folders, holes, extras, a movie),
  relay pieces, updater, logging redaction, the watched rule (time In),
  yt-dlp and
  Jellyfin client parsing against captured fixtures.
- `cd packages/server && dart test` (well under a minute): live servers
  on loopback: auth and version refusal, identity, takeover and grace
  (`presence_test` on a fake clock), media and relay byte serving with
  source drops, Jellyfin relay against a fake, queue (and the shared
  countdown on a fake clock), session log,
  isolate `serve`, sharing (`share_test`: a listener attached and detached
  under the same members and Up next, the host key standing in for the
  password).
- `cd apps/desktop && flutter test test/<file>`: widgets (shell, library,
  controls, settings, schedule), pure app logic (`StateDiff`, the library's L2 matching against a
  fake AniList (`show_matcher_test`), `media.ref` producers,
  shader list, sound engine with a fake backend, invite addresses, the
  version gate, the media plan's table with the Jellyfin relay rule and
  the "Waiting for" status (`media_plan_test`), watch tracking and the
  device history (`watch_tracker_test`), what continues a file of a
  local show (`queue_logic_test`)), `singletons_test` (the `.instance` count, see
  ARCHITECTURE "Composition root"; lower its baseline when a use goes) and the real-mpv `*_e2e`
  tests plus `coord_presence`. The whole suite takes a couple of minutes;
  run it only before a restructure step lands, otherwise only the files
  related to what you changed.

Opt-in, skipped unless set: `JELLYFIN_TEST_*` (core `jellyfin_live` and
server `jellyfin_relay_live` against a real Jellyfin; read their headers),
`YTDLP_LIVE=1` (downloads yt-dlp and resolves a real tweet). Everything
else is offline: Jellyfin and link hosts are local fakes.

Real-mpv tests: `sync_playback_e2e`, `coord_presence` (drops through a
`FlakyProxy`: a half-open link and return, 10 flaps, `replaced`, `bye`,
a dead or restarted server; a restarted server that came back empty gets
what played back at its position, a link everyone opens and a file
passed on, nothing reopened, the watch and Up next carrying on), `video_reload_e2e` (a fresh player from the
host, the old one retired, leave releases them all),
`seek_drag_e2e`, `end_of_file_e2e`, `readahead_e2e`, `chapters_mpv_e2e`,
`ytdl_headers_e2e` (a page through the app's own resolve against a
stand-in yt-dlp and a Referer-checking CDN: the EDL, the headers and
cookies, subtitles without danmaku, a 403, the D11 error),
`media_switch_e2e` (commands during a switch wait and apply once, no mpv
errors), `relay_e2e` (a dedicated server with no file of its
own: a guest's file, links passed on or fetched by the server, a late
source, a source that drops and resumes; a seek past what a slow source
has sent, timed; a source that drops while a viewer seeks past
the buffer and another joins: no seek loop, "Waiting for", all resume
(D6)), `jellyfin_e2e` (account holders report what they watched, one
who sat out is not marked watched, the next episode continues for
everyone), `whats_next_e2e` (a file of a show continued by its next
episode with the gap said, the server's countdown on both screens, a
shared cancel, the watch history), `queue_switch_e2e` (times Up next switches
through the media pipeline against a delayed, rate-capped fake Jellyfin
and link host: an episode, a direct link, a link passed on and a
server-fetched one, each prepared and promoted; no mpv "error running
command" or "file cache" lines; `WT_SWITCH_PRELOAD=0` for the cold path,
`WT_SWITCH_DELAY_MS` / `WT_SWITCH_RATE_KBS` for the link). The sync,
reload and end-of-file ones expect `~/Videos/chiyo.mp4`; the others
generate media with ffmpeg into `WT_TEST_TMP` (default: system temp; all
desktop tests that write files use it). Headless mpv (no video output
attached) won't open video-only files, so test media needs an audio
track. Tests always log media_kit "S/W rendering" because they have no
display; that says nothing about the app. A headless player has no video
track selected (`vid=no`), and an mkv's cues list only the video, so
seek tests over a relay or HTTP use an mp4 with its index first
(`+faststart`); setting `vid=auto` on a headless player crashes mpv when
it is disposed. `sound_device_e2e` opens the
real audio device (flutter_soloud) and plays every sound of every preset
quietly (`WT_SFX_VOLUME`, default 0.1).

Bad links: `FlakyProxy` (`package:sync_relay_core/testing.dart`, so
core, server and desktop tests share it; not part of `core.dart`) sits
between a client and a server on loopback: `FlakyProxy.start(serverPort)`,
the client dials `proxy.port`, and each accepted connection is a
`FlakyLink` the test steers at any time: `pass()`, `blackhole()` (both
sockets stay open, every byte and a closing end are dropped: a half-open
link), `delay` (added latency each way, order kept), `holdNext(d, flow:)`
(the next chunk, and what queues behind it, arrives `d` late),
`cutAfter(n, flow:)` (n more bytes, then a reset) and `reset()` (RST via
SO_LINGER 0). `onConnect` steers a link before its first byte (blackhole
or refuse the next dial). It counts bytes each way and the dropped ones.
It is TCP only: a "frame" is one chunk as read (on loopback usually one
small WebSocket frame). Its own tests: core `flaky_proxy_test`; against
the server: server `flaky_link_test`. For manual runs with real apps use
`tool/shaper` instead.

Long durations on a fake clock: `SyncServer(clock:, liveness:)` and
`SyncEngine(clock:, liveness:)` take the engine clock and the server's
limits (`Liveness`: silence, grace, gone notice, joiner hold, joining
timeout; ARCHITECTURE "Sync model"), so a test can pass short limits or
step a fake clock through minutes: move the clock, then call
`ServerHub.heartbeat()` (or `SyncEngine.tick()`) yourself; the real 1 s
heartbeat still ticks and reads the same clock. On the app side
`Connection(now:, unstableAfter:, silenceLimit:, lostSoundAfter:,
reconnectDelay:, identity:)` (`connection_test` drives one against a
scripted fake server), and `AutoSitOut` takes the time on every call
(`session_logic_test` steps it through minutes).

Safety-net scenarios: the core flows every restructure step must keep
working. What covers them today and which step adds the rest (steps as
in [ROADMAP.md](ROADMAP.md)):

| Scenario | Covered today | Missing, added in |
|---|---|---|
| Drop and reconnect while sharing a relay | server `flaky_link_test` (blackhole: `gone` with ready, queue item and relay kept, the same member back; reset), `sync_wave_test` (takeover by client id, `replaced`, `stale`), `presence_test` (grace on a fake clock, restart), `relay_test` "the source drops (D6)" (`sourceGone`, buffer served, same `info` continues, another 4002, a second channel 4003, leave ends it); desktop `relay_e2e` "the source drops uncleanly and comes back" (gone past the server's silence, the relay kept, the source re-dials and continues), `coord_presence` (a half-open drop while playing: same member, no reopen, the state kept; 10 flaps: at most one lost/back sound; `replaced` is terminal; a restarted server gets the ready again, and what played if it came back empty), server `queue_test` (the first restore offer wins), `connection_test` (the hello's id, `seq`, caps, `feedAfter`) | |
| Join mid-playback | core `sync_engine_test` "D2: joiners" (never changes the transport while playing, at most 15 s while held, joining ends on error or timeout), `presence_test` (the table); server `relay_test` "a late joiner gets its own /r/ URL"; desktop `coord_presence` (the returning member plays on in sync) | |
| Sit out / Away and back | core `sync_engine_test` "away" (only oneself comes back, through joining), "return" (away survives a drop), `presence_test` (`isAlone`); server `hardening_test` (anyone sets anyone away, `forbidden`); desktop `server_isolate_test` (the host sat out through `presence` on your shared server), `notice_table_test` (the feed actions one-to-one, matched by id; sitting out gets only chat, nudges, "starting now", Up next and the chosen joins and leaves; alone no social sounds), `session_logic_test` (auto sit-out on a fake clock: never alone, a manual away stays), `player_status_test` / `shell_test` (the ready counter leaves away and gone out); core `watch_session_test`, desktop `watch_tracker_test`, `jellyfin_session_test` "sat out", `jellyfin_e2e` (sat out: not tracked as watched, P7) | |
| Swap, also while someone is Away or gone | core `sync_engine_test` "swap" (a gone member stays out of the gate, comes back joining), "away" (a swap leaves it away), `queue_test` (a swap takes its item, drops the `auto` one); server `queue_test` (a gone adder's item waits), `relay_test` (a swap drops the buffer); desktop `sync_playback_e2e`, `media_switch_e2e` (no command reaches a player mid-switch) | |
| Up next advance | core `queue_test` (skip, play request timeout, `auto` and `cancel`; the countdown: start, follow the first item, seek, cancel, hold for a gone performer or source, skip what nobody can put up), `whats_next_test`; server `queue_test` (the countdown and cancel shared, a skip by the server); `relay_test` "warm relay"; desktop `jellyfin_session_test` (end card), `jellyfin_e2e` and `whats_next_e2e` (the continuation and the countdown end to end), `queue_switch_e2e` (prepared and promoted through the media pipeline) | |
| Close the app cleanly, incl. `bye` | server `lifecycle_test` (a close keeps the member `gone`, `bye` leaves at once, server stop closes sockets); desktop `server_isolate_test` (stop frees the port; Stop sharing tells guests with 4016 and keeps you and Up next; a friend's server and back keeps yours), `coord_presence` (Stop sharing and your server's stop release their ports; leave sends `bye` and others see "left" at once, leaving for a restart keeps the member `gone`), `video_reload_e2e` (leave releases every player); the close smoke run on the built app (`tool/smoke_windows.ps1` in CI, `tool/smoke_linux.sh` by hand) | |

A test file whose first line is `// restructure: rewrite in step N` pins
behaviour that step of the restructure ([ROADMAP.md](ROADMAP.md)) changes;
the comment names the tests. Rewrite or delete them in that step, not
before.

CI (`.gitea/workflows/ci.yml`): analyze + test for core and server, plus
`dart compile exe` of the dedicated server (fails if Flutter creeps into
`packages/server`). Desktop tests are not in CI. The Windows job runs the
updater tests, the release build and the close smoke run on that build
(`tool/smoke_windows.ps1`, P32): the app starts with
`STARSYNC_SMOKE=<clip>` (a 5 s clip from ffmpeg, else a WAV the script
writes) under its own profile (`STARSYNC_PROFILE=smoke`), opens the clip
in a player with a video output through the media pipeline
(`platform/smoke.dart`), plays a second and closes the normal way; the
steps go to `STARSYNC_SMOKE_OUT` (`start`, `opened <ms> render=<mode>`,
`closing`, or `skip` / `fail` with why). It fails when the app does not
exit within 45 s or leaves a `starsync` process, skips with a warning
when the runner cannot bring the app or its video output up, and prints
the `smoke:`, `close:` and `mpv: render` lines of the app log.
`tool/smoke_linux.sh` is the same on Linux (needs a display; after
`flutter build linux --release`).

Traps:
- Never pump media_kit's `Video` in `flutter test`: the runner hangs (kill
  the `flutter_tester` by PID). `AppShell(videoBuilder:)` takes a stand-in,
  so shell tests run the real player layout without it; otherwise test pure
  logic (`StateDiff`, coordinator without widgets).
- A `SyncServer` started inside a test: relic reports an error writing a
  response (a relay response cut short when its relay is dropped at a
  swap or stop) to the zone the server started in, which fails the
  test; outside tests it is only logged. Start it in `runZonedGuarded`
  and fail on anything else (`queue_switch_e2e`, `relay_e2e`): a viewer's
  read is still in flight at the `stop` in tearDown.
- The Link page probes a filled-in link (network, yt-dlp), which never
  answers on the widget-test clock: pass `AppShell(linkProbe:)` /
  `LibraryTab(probe:)` a fake, or `pumpAndSettle` never returns.
- Never depend on a server-side WebSocket `onDone`; assert presence with
  deadline polling.
- `sub.asFuture()` can resolve before `onDone`; poll with a deadline.
- Tests must not assume a threat model beyond the friends trust basis.

## Releasing

User pushes tags; CI does the rest.

1. `tool/release.sh [patch|minor|major] [--dry-run]`: derives the next
   version from the latest tag, bumps the three pubspecs in lockstep, writes
   `updates/manifest.json` (per-platform `assets` URLs are predictable; `url`
   stays the Linux tarball for builds <= 0.2.1), commits `Release vX.Y.Z`,
   makes an annotated tag.
2. Review, then `git push --follow-tags`.
3. `.gitea/workflows/release.yml` runs one job per platform: Linux builds
   with `tool/package_linux.sh`, Windows (runner `yuuka-windows`, host mode,
   PowerShell only) with `tool/package_windows.ps1`. Each then runs
   `dart tool/release_publish.dart vX.Y.Z <archive>`, which creates the
   release if the other job hasn't yet and uploads (or replaces) its asset.
   By hand: package, then the same `dart tool/release_publish.dart` line.

Test builds (Linux, no tag, no CI): `tool/dev_release.sh [--minor|--major]
[--no-publish]` (token: `RELEASE_TOKEN` or
`~/.config/watch-together-release-token`, a Gitea access token with
repository read/write) builds the working tree here as `<next>-dev.N` (N
one past the published one; `<next>` the pubspec's next patch, or next
minor / major when asked, and once such a line is published later runs
follow it until a release moves the pubspec) and replaces the assets of the
`dev` prerelease with the tarball and its `manifest.json`. Dev builds
update from it ([Updater](ARCHITECTURE.md#updater)). A stable install
moves onto it once with the command the script prints (run with the app
open: it finds the install from the running process and copies the new
files over it).

Tokens come from the environment (`RELEASE_TOKEN`, or Actions-provided
`GITHUB_TOKEN`/`GITEA_TOKEN`). The manifest has no `sha256` by default; the
updater skips the check when absent. Workflows live in `.gitea/workflows`
(the forge reads `.gitea` before `.github`).

## Debugging your server

The app's own server runs on its own isolate (`ServerIsolate`,
`apps/desktop/lib/src/state/server_isolate.dart`, owned by `YourServer`)
in the same process, from start to close. Breakpoints in
`packages/server` work under `flutter run`: the debugger attaches to
spawned isolates too (it shows as `server`). Its log lines carry
`server.<logger>` (e.g. `server.relay`). Hot reload reloads the server
isolate's code too, but its state (members, clock, sockets) survives;
changes to startup code (`SyncServer.start`, `share`, routes) need a
restart of the app. Hot restart kills the server isolate (flutter_tools
kills every non-UI isolate first), so a `[server] server crashed: the
server stopped unexpectedly` line just before it is expected. Its
loopback port changes every run (the log's `listening on` line has it);
`STARSYNC_PROFILE` gives a second window its own server. Without the
app: `dart run packages/server/bin/server.dart`.

## Logs

After a session, read the log files rather than reproducing
("Logging" in [ARCHITECTURE.md](ARCHITECTURE.md) has what goes in them):
the app's are `~/.local/share/dev.foxyz.starsync/logs/app-*.log`
on Linux (on Windows `%APPDATA%\foxyz\Starsync\logs`; Settings → About → "Open logs
folder" finds it anywhere), with your server's lines
in the same file; a dedicated server prints its folder at start
(`--log-dir`). Users send theirs with Settings → About → "Copy
diagnostics".

Start with the session log when there is one: `session-YYYY-MM-DD.log`
in the server's folder (the hosting app's logs folder, or the dedicated
server's `--log-dir`), every member's lines and the server's merged in
server-clock order, each tagged `[name (id)]` or `[server]`. Any member
gets it with "Copy diagnostics" in a session. Find
`=== PROBLEM marked by` first (a member pressed Ctrl+Shift+B), then read
the lines around it from every side; `grep '\[Bob (m2)\]'` follows one
member. `[server] diag:` lines say who shares (with their app version)
and who doesn't, so a missing side is explained. Times are the server's
clock; a member's local log (`app-*.log`) is on its own clock.

For a "can't play" report, grep both sides around the
time: `swap by` (what went up and how), `relay channel` (when the
source dialled in), `media:` (each viewer's requests: status and time to
headers), `mpv:` (`cannot open the media` and ffmpeg's lines), `yt-dlp:`
(the resolve and its picked formats) and `upstream` (CDN refusals with
the headers sent). A viewer that got no bytes while the source was
slow to come up shows mpv's error with "no HTTP error logged".

For "the video is slow / shaders do nothing", grep `mpv: render` (what
each line holds: "Render mode" in [ARCHITECTURE.md](ARCHITECTURE.md)).
`render: gpu` with a real `GL_RENDERER` (not `llvmpipe` / `softpipe`) is
the good case; `render: softwareGl` is OpenGL on the CPU (Mesa's software
rasterizer: missing or blocked GPU drivers, `LIBGL_ALWAYS_SOFTWARE=1`);
`render: software` with no GL lines is media_kit's own fallback (it found
no usable EGL context: check `render env:` for an X11 session or a
`GDK_BACKEND` / `FLUTTER_LINUX_RENDERER` override). Its reason is only on
stderr: have the user start the app from a terminal
(`./starsync 2>&1 | grep VideoOutput`). `hwdec-current=no` on the
first-frame line means software decoding (no hwdec for that codec, or it
is off), not software rendering.

## Gotchas

- Relic gives Range as a typed `RangeHeader`; convert from unit + first range.
- A killed isolate (`Isolate.kill`) does not close its listening socket:
  the port stays bound in the process until exit. `SyncServer` binds with
  `shared: true` (both listeners) so a new one in the same process can
  take it over; a normal stop closes it.
- Relic server-side `onDone` does not fire for dead peers. Presence is the
  `isClosed` sweep + `onError` forget + `lastSeen` timeouts.
- `web_socket_channel` 3.x: `channel.ready` errors are unhandled on refused
  connections; swallow them and report through the stream's `onError`.
  Streams are single-subscription: one listener per socket.
- media_kit has no public `Player.setProperty`; the player host
  (`MediaKitHost`) reaches mpv through a dynamic call on
  `player.platform`, and nothing outside it imports media_kit except the
  `Video` widget glue. Cache size goes through
  `PlayerConfiguration(bufferSize:)`.
- Hot restart with any media_kit `Player` alive (session, thumbnails)
  used to SIGSEGV on mpv's `core` thread: each mpv handle's wakeup callback
  is a `NativeCallable` of the old isolate, freed by the restart, and media_kit
  then sends the leftover handles `quit`, which fires it. `fox_utils`' Linux
  plugin (from 0.1.8, debug builds only) clears those callbacks on the
  engine's `on-pre-engine-restart` signal, reading the handles from
  media_kit's debug-only `NativeReferenceHolder` buffer (address in
  `$TMPDIR/com.alexmercerind.media_kit.NativeReferenceHolder.<pid>`). Old
  players are leaked, not destroyed, until the process exits. Re-check this
  after a media_kit upgrade.
- mpv reconnect flags: comma form works, colon form is rejected. Re-verify
  through `setProperty` if touched.
- Overlays that are hidden but mounted keep focus (Space falls into a hidden
  button). Use `ExcludeFocus` on closed subtrees and unfocus on close; reuse
  the shared no-focus node for overlay buttons.
- `toggleFullscreenOnDoublePress: false` on the session controls is
  load-bearing: media_kit's double-click pushes its own fullscreen route with
  a second `Video`. A `GestureDetector` below media_kit's overlay never sees
  the click (its `MouseRegion` takes the hit) and one around it would delay
  every button click (double-tap holds the arena), so the double-click is a
  raw pointer observer (`DoubleClickListener`).
- The window is frameless: the party strip is the only drag area and holds
  the window buttons.
- Signal-backed singletons (`Profile`, `AppSettings`) and a test file's
  `AppGraph` live across tests; never cache a `Future` in them (each test
  runs in its own zone, and a Future from an earlier test never completes
  in the next).
- Widgets read the systems from `AppScope`: a widget test pumps its tree
  under one (`scoped(graph, ...)` from `test/test_graph.dart`; one
  `testGraph()` per file). A `State` that needs a system in `dispose`
  reads it before (`late final` touched in `initState`): the scope cannot
  be looked up from a deactivated element.
- Chat arrives twice from the server (see PROTOCOL.md); the client drops the
  textless feed copy.
- Tab traversal is disabled in the session player on purpose; Tab toggles
  chat & activity.
- After editing constants (ports, thresholds), grep to confirm the value landed.
