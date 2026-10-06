# Development

Layout and rules: [ARCHITECTURE.md](ARCHITECTURE.md).

## Build

Needs the Flutter SDK (beta channel, Dart 3.13+) and, for the Linux desktop
build, the usual GTK toolchain (clang, cmake, ninja, pkg-config, libgtk-3-dev).
mpv libraries come from `media_kit_libs_video`.

```
cd apps/desktop && flutter pub get && flutter run -d linux
cd apps/desktop && flutter build linux --release --dart-define=APP_VERSION=<x.y.z>
tool/package_linux.sh [--skip-build] [--noupload]    # dist/*.tar.gz
cd packages/server && dart compile exe bin/server.dart -o watch-together-server
```

`APP_VERSION` defaults to `0.0.0-dev`; `package_linux.sh` stamps it from the
desktop pubspec. Setting `DISCORD_WEBHOOK_URL` makes the packager post the
tarball to Discord (never commit it). The packager always compiles the
dedicated server (with the Flutter SDK's `dart`) into the tarball as
`watch-together-server`, also with `--skip-build`.

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
effect with embedded video: media_kit forces `vo=libmpv`.

Harnesses in `tool/` (own `pubspec.yaml`, `dart run tool/<name>.dart`):
`range_logger` (serve a file and log every Range request), `shaper`
(bandwidth cap, latency, `--kill-after` for outage tests), `fake_viewer`
and `e2e_check` (simulated viewers against a live server).

## Tests

- `cd packages/core && dart test`, `cd packages/server && dart test`.
- `cd apps/desktop && flutter test test/<file>`.
- Real-mpv tests: `sync_playback_e2e`, `coord_presence`, `video_reload_e2e`,
  `seek_drag_e2e`, `end_of_file_e2e`, `readahead_e2e`. The sync and
  end-of-file ones expect `~/Videos/chiyo.mp4`; others generate media with
  ffmpeg into `WT_TEST_TMP`. Headless mpv (no video output attached) won't
  open video-only files, so test media needs an audio track. Tests always log
  media_kit "S/W rendering" because they have no display; that says nothing
  about the app. Run only tests related to
  what you changed.
- CI (`.gitea/workflows/ci.yml`): analyze + test for core and server, plus
  `dart compile exe` of the dedicated server (fails if Flutter creeps into
  `packages/server`). Desktop tests are not in CI.
- `packages/server/test/serve_isolate_test.dart` runs `serve` in a real
  isolate; `apps/desktop/test/server_isolate_test.dart` covers the app's
  host path (isolate server, raw WebSocket join, crash, rehost).
- Desktop tests that write files use `WT_TEST_TMP` (default: system temp).

Traps:
- Never pump the session screen or media_kit `Video` in `flutter test`: the
  runner hangs (kill the `flutter_tester` by PID). Test pure logic
  (`StateDiff`, coordinator without widgets) instead.
- Never depend on a server-side WebSocket `onDone`; assert presence with
  deadline polling.
- `sub.asFuture()` can resolve before `onDone`; poll with a deadline.
- Tests must not assume a threat model beyond the friends trust basis.

## Releasing

User pushes tags; CI does the rest.

1. `tool/release.sh [patch|minor|major] [--dry-run]`: derives the next
   version from the latest tag, bumps the three pubspecs in lockstep, writes
   `updates/manifest.json` (asset URL is predictable), commits `Release vX.Y.Z`,
   makes an annotated tag.
2. Review, then `git push --follow-tags`.
3. `.gitea/workflows/release.yml` builds the Linux tarball and runs
   `tool/release_publish.sh vX.Y.Z`, which creates the release and uploads it.
   By hand: `tool/package_linux.sh` then `tool/release_publish.sh vX.Y.Z`.

Tokens come from the environment (`RELEASE_TOKEN`, or Actions-provided
`GITHUB_TOKEN`/`GITEA_TOKEN`). The manifest has no `sha256` by default; the
updater skips the check when absent. Workflows live in `.gitea/workflows`
(the forge reads `.gitea` before `.github`).

## Debugging the hosted server

When hosting, the server runs on its own isolate (`ServerIsolate`,
`apps/desktop/lib/src/state/server_isolate.dart`), in the same process.
Breakpoints in `packages/server` work under `flutter run`: the debugger
attaches to spawned isolates too (it shows as `server`). Its log lines are
printed with a `[server]` prefix. Hot reload reloads the server isolate's
code too, but its state (members, clock, sockets) survives until hosting
restarts; changes to startup code (`SyncServer.start`, routes) need a new
Host. Without the app: `dart run packages/server/bin/server.dart`.

## Gotchas

- Relic gives Range as a typed `RangeHeader`; convert from unit + first range.
- A killed isolate (`Isolate.kill`) does not close its listening socket:
  the port stays bound in the process until exit. `SyncServer` binds with
  `shared: true` so a new hosted server in the same process can take it
  over; a normal stop closes it.
- Relic server-side `onDone` does not fire for dead peers. Presence is the
  `isClosed` sweep + `onError` forget + `lastSeen` timeouts.
- `web_socket_channel` 3.x: `channel.ready` errors are unhandled on refused
  connections; swallow them and report through the stream's `onError`.
  Streams are single-subscription: one listener per socket.
- media_kit has no public `Player.setProperty`; the code reaches mpv through a
  dynamic call on `player.platform`. Cache size goes through
  `PlayerConfiguration(bufferSize:)`.
- mpv reconnect flags: comma form works, colon form is rejected. Re-verify
  through `setProperty` if touched.
- Overlays that are hidden but mounted keep focus (Space falls into a hidden
  button). Use `ExcludeFocus` on closed subtrees and unfocus on close; reuse
  the shared no-focus node for overlay buttons.
- `modifyVolumeOnScroll: false` on the session controls is load-bearing for
  window drag (volume is the speaker button only). A `GestureDetector` below
  media_kit's overlay loses the gesture arena; the drag layer is a raw pointer
  observer on top.
- New screens must bring their own drag area and window buttons (frameless
  window).
- Chat arrives twice from the server (see PROTOCOL.md); the client drops the
  textless feed copy.
- Tab traversal is disabled on the session screen on purpose; Tab toggles the
  side panel.
- After editing constants (ports, thresholds), grep to confirm the value landed.
