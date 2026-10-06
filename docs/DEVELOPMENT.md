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
```

`APP_VERSION` defaults to `0.0.0-dev`; `package_linux.sh` stamps it from the
desktop pubspec. Setting `DISCORD_WEBHOOK_URL` makes the packager post the
tarball to Discord (never commit it).

## Dev loop

Run a server without the app, then point apps at it:

```
dart run packages/server/bin/server.dart --port 8080 --secret x [--media FILE]
```

Prints `READY port=... room=...` and stops on SIGINT. Then Join from one or
more apps at `127.0.0.1:8080`. Or just Host from the app. mpv env override:
`SYNC_RELAY_HWDEC` (wins over the Settings choice). `SYNC_RELAY_VO` has no
effect with embedded video: media_kit forces `vo=libmpv`.

Harnesses in `tool/` (own `pubspec.yaml`, `dart run tool/<name>.dart`):
`range_logger` (serve a file and log every Range request), `shaper`
(bandwidth cap, latency, `--kill-after` for outage tests), `fake_viewer`
and `e2e_check` (simulated viewers against a live server).

## Tests

- `cd packages/core && dart test`, `cd packages/server && dart test`.
- `cd apps/desktop && flutter test test/<file>`.
- `sync_playback_e2e_test.dart` and `coord_presence_test.dart` use real mpv;
  the e2e one also expects `~/Videos/chiyo.mp4`. Run only tests related to
  what you changed.
- CI (`.gitea/workflows/ci.yml`): analyze + test for core and server only.
  Desktop tests are not in CI.

Traps:
- Never pump the session screen or media_kit `Video` in `flutter test`: the
  runner hangs (kill the `flutter_tester` by PID). Test pure logic
  (`RoomDiff`, coordinator without widgets) instead.
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

## Gotchas

- Relic gives Range as a typed `RangeHeader`; convert from unit + first range.
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
