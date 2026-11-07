# Development

Layout and rules: [ARCHITECTURE.md](ARCHITECTURE.md).

## Build

Prerequisites (the Flutter SDK, and the Linux or Windows toolchain and
libraries): [README "Build from source"](../README.md#build-from-source).
media_kit is the owner's fork (`github.com/Foxyz1302/media-kit`, a local
checkout sits beside this repo as `../media-kit`): git dependencies pinned
to one tag of it for every media_kit package the app uses, `media_kit`,
`media_kit_video`, `media_kit_libs_linux` (Linux: the system's libmpv,
`libmpv-dev`) and `media_kit_libs_windows_video` (Windows: a libmpv build
and ANGLE downloaded while building, checked by SHA-256). `media_kit` is
in `dependency_overrides` too, since `media_kit_video` asks for it from
pub.dev. Starsync patches none of it: a fix goes into the fork, which is
tagged; bump by changing `ref` in all five places of the desktop pubspec,
then `flutter pub get`. Test video output changes under X11
(`GDK_BACKEND=x11`, ideally a real X11 session) and Wayland. `flutter_soloud` (the app's
sounds) compiles SoLoud and miniaudio from source in its build hook with
that C++ toolchain (MSVC on Windows); it needs no audio dev headers (miniaudio
loads ALSA / PulseAudio / JACK at run time) and, with `no_xiph_libs` set in
the desktop pubspec, downloads nothing. `fox_utils` (drag & drop,
clipboard files and images; native Linux/Windows plugin) is the owner's
shared package, a git dependency pinned to a tag of its repo (`url` in
the desktop pubspec, as for `leaf_widgets`): bump it by tagging there and
changing `ref` in the desktop pubspec.

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
top folder `starsync-<version>/` (no names from before the rename:
"Updater" in [ARCHITECTURE.md](ARCHITECTURE.md)). The Dart
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
client id: without it a second start is the same install, so it hands
its arguments to the running app and ends; each profile is its own
instance) and logs under
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
`tool/make_sub_test.sh [out.mkv] [seconds]` (ffmpeg) writes a 720p test
video for subtitle placement and sharpness (default
`~/Videos/starsync-sub-test.mkv`): an .ass track with a top sign
(`\an8`) and bottom dialogue (English and Japanese), and an SRT track.

## Where a new setting goes

Anything new goes straight to its home in the settings layout
(ARCHITECTURE "Desktop UI", Settings; "Setting rows" for the widgets),
and every change is checked against someone who joins once from a link
and never opens Settings.

- **Prefer a good default to a new switch.** A choice earns a row only
  when people really differ on it; otherwise pick the default, or put the
  control where its effect is seen (the clock's click, the Latest row's
  ⋮).
- **A one-time joiner touches nothing**: the name prompt, Space or play,
  the volume and fullscreen are all they need, with the defaults right.
- **One home per setting**, in one of the six pages:
  - *Player*: how the video looks and sounds and how the controls
    behave (volume, subtitles, picture, controls, playback).
  - *Party*: you (picture, name, colour; More: how people look), your server for
    Invite, recent servers.
  - *Notifications & sounds*: what shows over the video and what makes a
    sound.
  - *Library & accounts*: where media comes from (Jellyfin, AnimeFlow,
    web links and their cookies).
  - *Updates*: what version you run and get.
  - *Help & about*: diagnostics and sharing them, keyboard shortcuts,
    about, developer tools.
- **Common rows first, the rest under More** (`SettingFold`) on each
  page; troubleshooting and tinkerer rows are always folded.
- **The player panel** shows only what you adjust while watching, with
  the same widget and label as Settings (dense under `SettingDensity`);
  never a second implementation of a row.
- A new key needs no schema step (missing means the default); renaming
  or dropping one does (ARCHITECTURE "Settings schema"). Strings that
  name a Settings path change with the page.

## Dev tools

Test builds and runs from source (a version with `-dev`) and debug runs
(`devTools`, `screens/home/ui.dart`) get Settings → Help & about → Developer;
releases never show it:

- **Danmaku preview** (`danmaku/danmaku_preview.dart`): the danmaku layer
  of "Notifications: Danmaku" (ARCHITECTURE "Danmaku notifications") to
  play with, starting from your own look; its knobs change only the
  preview. The button opens it over the full player when one is up
  (under the controls; the panel top right holds them up), else on a
  page with a moving stand-in picture and a mock control bar of the skin
  in use. The panel (`DanmakuPanel`) fires samples (chat, own, join,
  leave, Up next, starting, a burst), a random stream (Poisson arrivals
  at a rate, short to long lines, CJK and emoji; in a session half the
  senders are the party's real members), this session's own chat and
  notice toasts (mapped as the real feature maps them), every
  `DanmakuStyle` knob, and mock subtitles (a top sign and bottom
  dialogue). The mock dialogue moves with the subtitle lift's steps as
  the real subtitles do: over the player when the quick chat box opens,
  and on the stand-in page, which has its own quick chat box (Enter;
  what you send flies as your own line). Tests: `danmaku_test`.

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
  relay pieces, updater (signed manifests and checksums against a test
  key), the signed config (serial, saved copy, key handover;
  `remote_config_test`) and signatures (`signing_test`), logging redaction, the watched rule (time In),
  yt-dlp and
  Jellyfin client parsing against captured fixtures.
- `cd packages/server && dart test` (well under a minute): live servers
  on loopback: auth and version refusal, identity, takeover and grace
  (`presence_test` on a fake clock), media and relay byte serving with
  source drops, the read-once source (`shared_source_test`: its loopback
  range answers, a cut and resume with backoff, seeks of either reader,
  the two kept within one window, its memory bound), Jellyfin relay
  against a fake, queue (and the shared
  countdown on a fake clock), session log,
  isolate `serve`, sharing (`share_test`: a listener attached and detached
  under the same members and Up next, the host key standing in for the
  password).
- `cd apps/desktop && flutter test test/<file>`: widgets (shell, library,
  controls, settings, schedule), pure app logic (`StateDiff`, the library's L2 matching against a
  fake AniList (`show_matcher_test`), `media.ref` producers,
  shader list, sound engine with a fake backend, invite addresses, the
  `starsync://` links, the internet address lookup against fake
  services, the join prompt and one app per profile
  (`invite_links_test`), the version gate, the media plan's table with the Jellyfin relay rule and
  the "Waiting for" status (`media_plan_test`), watch tracking and the
  device history (`watch_tracker_test`), what continues a file of a
  local show (`queue_logic_test`), the video view's output size and
  subtitle lift steps and the dev-tools gate (`video_view_test`), danmaku
  lanes, style, the toasts that fly and an idle layer
  (`danmaku_test`), the quick chat box over the player (`quick_chat_test`),
  a picture and its loading edge read back as pixels (`avatar_test`),
  the player panel and the danmaku settings card (`player_settings_test`),
  any colour through "Custom…" and kept readable where it is used
  (`color_picker_test`)),
  `singletons_test` (the `.instance` count, see
  ARCHITECTURE "Composition root"; lower its baseline when a use goes) and the real-mpv `*_e2e`
  tests plus `coord_presence`. The whole suite takes a couple of minutes;
  run it only before a restructure step lands, otherwise only the files
  related to what you changed.

Opt-in, skipped unless set: `JELLYFIN_TEST_*` (core `jellyfin_live` and
server `jellyfin_relay_live` against a real Jellyfin; read their headers),
`YTDLP_LIVE=1` (downloads yt-dlp and resolves a real tweet),
`WT_SINGLE_FETCH=1` (server `single_fetch_e2e`: a link passed on read
once against twice, two real mpv against a fake CDN that cuts and locks
out; minutes; `WT_SF_SCENARIOS`, `WT_SF_PLAY` narrow it). Everything
else is offline: Jellyfin and link hosts are local fakes.

Real-mpv tests: `sync_playback_e2e`, `coord_presence` (drops through a
`FlakyProxy`: a half-open link and return, 10 flaps, `replaced`, `bye`,
a dead or restarted server; a restarted server that came back empty gets
what played back at its position, a link everyone opens and a file
passed on, nothing reopened, the watch and Up next carrying on), `video_reload_e2e` (a fresh player from the
host, the old one retired, leave releases them all),
`seek_drag_e2e`, `end_of_file_e2e`, `readahead_e2e`, `chapters_mpv_e2e`,
`live_e2e` (three players on a local ffmpeg live HLS stream with a 90 s
window, one on a CDN edge 3 s late: their spread in the stream's time
printed, a pause here only, a live screenshot, rewinds inside every
cache and to the window's start, a pause while rewound, Go live, the
stream's end; `WT_LIVE_URL=<a live page>` adds two players on a real
one through a downloaded yt-dlp, rewound 300 s and back when it allows,
network needed, no sign-in),
`screenshot_e2e` (ARCHITECTURE "Screenshots"),
`ytdl_headers_e2e` (a page through the app's own resolve against a
stand-in yt-dlp and a Referer-checking CDN: the EDL, the headers and
cookies, subtitles without danmaku, a 403, the D11 error),
`media_switch_e2e` (commands during a switch wait and apply once, no mpv
errors), `relay_e2e` (a dedicated server with no file of its
own: a guest's file, links passed on (read once: the source's player on
its loopback reader, nothing from mpv at the origin) or fetched by the
server, a late
source, a source that drops and resumes; a seek past what a slow source
has sent, timed; a source that drops while a viewer seeks past
the buffer and another joins: no seek loop, "Waiting for", all resume
(D6)), `jellyfin_e2e` (account holders report what they watched, one
who is out is not marked watched, the next episode continues for
everyone), `whats_next_e2e` (a file of a show continued by its next
episode with the gap said, the server's countdown on both screens, a
shared cancel, the watch history), `queue_switch_e2e` (times Up next switches
through the media pipeline against a delayed, rate-capped fake Jellyfin
and link host: an episode, a direct link, a link passed on and a
server-fetched one, each prepared and promoted; no mpv "error running
command" or "file cache" lines; `WT_SWITCH_PRELOAD=0` for the cold path,
`WT_SWITCH_DELAY_MS` / `WT_SWITCH_RATE_KBS` for the link). All of them
generate their media with ffmpeg into `WT_TEST_TMP` (default: system
temp; all desktop tests that write files use it); the sync, reload and
end-of-file ones share a 13.8 s clip (`test/test_clip.dart`). Headless mpv (no video output
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
limits (`Liveness`: silence, grace, gone notice; ARCHITECTURE "Sync
model"), so a test can pass short limits or
step a fake clock through minutes: move the clock, then call
`ServerHub.heartbeat()` (or `SyncEngine.tick()`) yourself; the real 1 s
heartbeat still ticks and reads the same clock. On the app side
`Connection(now:, unstableAfter:, silenceLimit:, lostSoundAfter:,
reconnectDelay:, identity:)` (`connection_test` drives one against a
scripted fake server), and `AfkWatch` takes the time on every call
(`session_logic_test` steps it through minutes, with the pure
`SpaceGesture` fed hold times).

Safety-net scenarios: the core flows every restructure step must keep
working. What covers them today and which step adds the rest (steps as
in [ROADMAP.md](ROADMAP.md)):

| Scenario | Covered today | Missing, added in |
|---|---|---|
| Drop and reconnect while sharing a relay | server `flaky_link_test` (blackhole: `gone` with its BRB, queue item and relay kept, the same member back; reset), `sync_wave_test` (takeover by client id, `replaced`, `stale`), `presence_test` (grace on a fake clock, restart), `relay_test` "the source drops (D6)" (`sourceGone`, buffer served, same `info` continues, another 4002, a second channel 4003, leave ends it); desktop `relay_e2e` "the source drops uncleanly and comes back" (gone past the server's silence, the relay kept, the source re-dials and continues), `coord_presence` (a half-open drop while playing: same member, no reopen, the state kept; 10 flaps: at most one lost/back sound; `replaced` is terminal; a restarted server gets the BRB again, and what played if it came back empty), server `queue_test` (the first restore offer wins), `connection_test` (the hello's id, `seq`, caps, `feedAfter`) | |
| Join mid-playback | core `sync_engine_test` "loading (joiners)" (never changes the transport while playing, waited for while held and wanting to play, loading ends on an error), "back from a drop" (the `return` line says what was missed; not after out, a pause or a seek), `presence_test` (the table); server `relay_test` "a late joiner gets its own /r/ URL"; desktop `coord_presence` (the returning member plays on in sync) | |
| BRB, AFK, Out and back | core `sync_engine_test` "the wish" (nothing starts by itself, one play for everyone, a pause holds at once), "BRB" (holds, plays again only if it wanted to, Wait for Bob, survives a drop and a swap, the last BRB leaving leaves a pause), "out and AFK" (only oneself comes back, loading at the current moment; AFK never while playing nor on BRB), "continue", `presence_test` (`isAlone`); server `hardening_test` (anyone sets anyone out, `forbidden`), `server_auth_test` (a 1.4.x hello gets the version refusal); desktop `sync_playback_e2e` (one Play, a pause and a BRB over real players; Space as the keys feed it: taps, the BRB hold, BRB too, continue without, Space in from out), `player_radial_test` (the radial: drag to pick, hold only (a plain right-click shows nothing, letting go always closes it), its places by standing; Space held through `AppKeys`: the fill, the words from 150 ms, repeats ignored, a lost key-up drops the press; the hold times from the settings), `server_isolate_test` (the host set out through `presence` on your shared server), `notice_table_test` (the feed actions one-to-one, matched by id; out gets only chat, nudges, "starting now", Up next and the chosen joins and leaves; alone no social sounds), `session_logic_test` (AFK and the Space gesture on a fake clock), `player_status_test` / `shell_test` (the pill's lines and keys, who is in while paused, the out card, the waiting display's pill, card and fading card, the party line leaves gone out), `player_settings_test` "how people look" (badges as icons or words, the top bar's row side by side or overlapping, the settings' defaults and persistence), `person_card_test` (Wait for / Don't wait for, Out / Join); core `watch_session_test`, desktop `watch_tracker_test`, `jellyfin_session_test` "sat out", `jellyfin_e2e` (out: not tracked as watched, P7) | |
| Swap, also while someone is out or gone | core `sync_engine_test` "swap" (waits for every video again, keeps the wish), "BRB" / "out and AFK" (a swap keeps them), `queue_test` (a swap takes its item, drops the `auto` one); server `queue_test` (a gone adder's item waits), `relay_test` (a swap drops the buffer); desktop `sync_playback_e2e`, `media_switch_e2e` (no command reaches a player mid-switch) | |
| Up next advance | core `queue_test` (skip, a play request asked again then skipped, `auto` and `cancel`; the countdown over the last 10 s ending at the end, a pause during it, after the end, follow the first item, seek, cancel, hold for a gone performer or source, skip what nobody can put up), `whats_next_test`; server `queue_test` (the countdown and cancel shared, a skip by the server); `relay_test` "warm relay"; desktop `jellyfin_session_test` (end card), `jellyfin_e2e` and `whats_next_e2e` (the continuation and the countdown end to end), `queue_switch_e2e` (prepared and promoted through the media pipeline) | |
| Close the app cleanly, incl. `bye` | server `lifecycle_test` (a close keeps the member `gone`, `bye` leaves at once, server stop closes sockets); desktop `server_isolate_test` (stop frees the port; Stop sharing tells guests with 4016 and keeps you and Up next; a friend's server and back keeps yours), `coord_presence` (Stop sharing and your server's stop release their ports; leave sends `bye` and others see "left" at once, leaving for a restart keeps the member `gone`), `video_reload_e2e` (leave releases every player); the close smoke run on the built app (`tool/smoke_windows.ps1` in CI, `tool/smoke_linux.sh` by hand) | |

A test file whose first line is `// restructure: rewrite in step N` pins
behaviour that step of the restructure ([ROADMAP.md](ROADMAP.md)) changes;
the comment names the tests. Rewrite or delete them in that step, not
before.

CI (`ci.yml`, on Gitea and [on GitHub](#ci-on-github)): analyze + test for core and server, plus
`dart compile exe` of the dedicated server (fails if Flutter creeps into
`packages/server`). Desktop tests are not in CI. The Windows job runs the
updater tests, the release build and the close smoke run on that build
(`tool/smoke_windows.ps1`, P32): the app starts with
`STARSYNC_SMOKE=<clip>` (a 5 s clip from ffmpeg, else a WAV the script
writes) under its own profile (`STARSYNC_PROFILE=smoke`), opens the clip
in a player with a video output through the media pipeline
(`platform/smoke.dart`), plays it, stays up 10 s from its start and
closes the normal way; the steps go to `STARSYNC_SMOKE_OUT` (`start`,
`opened <ms> render=<mode>`, `closing`, `quitting` just before the
window closes, or `skip` / `fail` with why). It fails when the app ends
by itself before `closing` or never reaches `quitting`, does not exit
within 45 s or leaves a `starsync` process, skips with a warning
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
  response (one cut short at `stop`: `/m`, `/j`; the relay's byte
  answers are written on the raw connection and end on their own) to
  the zone the server started in, which fails the test; outside tests it
  is only logged. Start it in `runZonedGuarded` and fail on anything
  else (`queue_switch_e2e`, `relay_e2e`): a viewer's read can still be
  in flight at the `stop` in tearDown.
- The window buttons, the strip's drag area and fullscreen need
  window_manager: tests pass `windowControls: false`, or give the graph a
  `FakeShell` (`testGraph(shell:)` in `test/test_graph.dart`: it records
  what the window was asked and serves Ctrl+V's clipboard) and keep them
  on (`app_keys_test`). `testGraph(links:)` stands in for yt-dlp.
- The Link page probes a filled-in link (network, yt-dlp), which never
  answers on the widget-test clock: pass `AppShell(linkProbe:)` /
  `LibraryTab(probe:)` a fake, or `pumpAndSettle` never returns.
- Never depend on a server-side WebSocket `onDone`; assert presence with
  deadline polling.
- `sub.asFuture()` can resolve before `onDone`; poll with a deadline.
- Tests must not assume a threat model beyond the friends trust basis.

## Releasing

The owner tags and signs; GitHub Actions builds and publishes the
archives in between. CI has no signing key ([Signing](#signing)), so the
manifest that makes a release visible to the apps is written and signed
on the owner's machine from the archives CI published, after checking
them. The steps, on `main`:

1. `tool/release.sh minor` (or `patch`, `major`).
2. `git push github --follow-tags`.
3. Wait for the `release` run on GitHub (Actions) to go green.
4. `tool/sign_release.sh 1.5.0 --push` (the new version).

What each does:

- **`tool/release.sh [patch|minor|major] [--dry-run]`** derives the next
  version from the latest tag, refuses when the [changelog](#changelog)'s
  Unreleased has no items (warns when it has no Highlights or no summary)
  and prints it; `--dry-run` stops there. Then it checks the signing
  key is there (stops without one), renames Unreleased to `X.Y.Z` under
  a fresh empty Unreleased, bumps the three pubspecs in lockstep, signs
  the config when it changed (`tool/sign_config.dart`), commits
  `Release vX.Y.Z` (with `CHANGELOG.md`) and makes an annotated tag. It
  does not touch `updates/manifest.json`: apps keep seeing the previous
  release until step 4.
- **The push** names `github`: `main`'s upstream may still be the Gitea
  (`origin`), whose `main` is another history.
- **GitHub's `release.yml`** ([CI on GitHub](#ci-on-github)) builds both
  archives on the tag and publishes the release `vX.Y.Z` with them (its
  text: the version's changelog section). By hand: package, then `dart
  tool/publish_github.dart vX.Y.Z <tarball> <zip>`.
- **`tool/sign_release.sh X.Y.Z [--push] [--no-bridge] [--dry-run]`**
  downloads both archives from the GitHub release (`STARSYNC_GITHUB_REPO`,
  default `Foxyz1302/starsync`), checks each is the bundle of that version
  (`starsync-X.Y.Z/starsync`, `.exe` on Windows), writes
  `updates/manifest.json` (per-platform `assets` URLs on GitHub and their
  sha256 in `assetSha256`; `url` stays the Linux tarball for builds <=
  0.2.1; `notes` is the section's summary, `highlights` and `changes` its
  lists, `protocol` the tagged code's), signs it (`manifest.json.sig`) and
  the config when it changed, commits `Publish vX.Y.Z: signed manifest`
  and builds the [1.4 bridge](#the-14-bridge) commit. Then it prints the
  two pushes, or with `--push` runs them: `git push github main` (remote
  `STARSYNC_GITHUB_REMOTE`), then the bridge to the Gitea. Apps see the
  release once the manifest is on GitHub's `main`. `--dry-run` does it all
  in a temporary folder: the manifest and its signature compared with the
  committed ones, the signature checked, the bridge commit built on no
  branch; nothing committed or pushed. A test run of the downloaded
  archive before this step is the check that what gets signed is the
  build.

Signing before the tag cannot work: the archives' sha256 is only known
once CI built them, and a manifest without it is refused.

Test builds (Linux, no tag, no CI): `tool/dev_release.sh [--minor|--major]
[--no-publish]` (token: `GH_TOKEN`/`GITHUB_TOKEN`, else `gh auth token`)
builds the working tree here as `<next>-dev.N` (N
one past the published one; `<next>` the pubspec's next patch, or next
minor / major when asked, and once such a line is published later runs
follow it until a release moves the pubspec; before the first dev build
on GitHub the numbering carries on from the old host's dev manifest,
`RELEASE_REPO_URL` or `origin`), writes its `manifest.json`
(`assetSha256` and, for test builds older than signing, a string
`sha256`; `highlights` and `changes`: the changelog's Unreleased, which
also becomes the prerelease's text), signs it and replaces the assets of
the `dev` prerelease of `STARSYNC_GITHUB_REPO` (default
`Foxyz1302/starsync`) with the tarball, `manifest.json.sig` and
`manifest.json` (`publish_github.dart dev`, manifest last). Without a signing key it stops before building;
`--no-publish` then builds and leaves the manifest unsigned. Dev builds
update from it on the Dev update channel, which a test build starts on
and keeps after a release ([Updater](ARCHITECTURE.md#updater)). Any
install switches channel in Settings → Updates → More; the command the script
prints is a shortcut that moves a stable install onto the test build at
once (run with the app open: it finds the install from the running
process, copies the new files over it and writes the `update-channel`
file that sets Dev).

Tokens come from the environment (`RELEASE_TOKEN` for the Gitea, GitHub's
`GH_TOKEN`/`GITHUB_TOKEN` or `gh auth token`, the Actions-provided
`GITHUB_TOKEN`).

GitHub, `https://github.com/Foxyz1302/starsync`, is the public home:
releases, dev builds, the website's downloads. Apps from 1.5.0 on read
their config and manifests from GitHub only (the signed config, else
`distribution.dart`: [Signing](#signing)). The Gitea (`origin`) keeps the
old history and serves 1.4.x through the [bridge](#the-14-bridge). It
runs its own `.gitea/workflows` (it reads `.gitea` before `.github`):
`ci.yml` on branch pushes, and `release.yml` only builds when run by hand,
on no tag, so a tag that reaches the Gitea publishes nothing there. GitHub
runs `.github/workflows` ([CI on GitHub](#ci-on-github)).

#### The 1.4 bridge

Apps up to 1.4.x have the Gitea's address built in (its
`updates/manifest.json` on `main`, under the Gitea's old name) and check
no signature. So `tool/sign_release.sh` puts the same `manifest.json` and
`.sig`, byte for byte, as one commit (`[skip ci]`) on top of the Gitea's
`main`, which is the old, pre-cleanup history: fetched, committed in a
temporary worktree, kept on the local branch `gitea-bridge`, pushed to
the Gitea's `main` over https with a token header (`RELEASE_TOKEN`, else
`~/.config/watch-together-release-token`; ssh to the Gitea is blocked).
The Gitea is `RELEASE_REPO_URL`, else `origin`'s https address; no Gitea
address is written in the tree. The manifest suits them: they read
`version`, `protocol`, `assets` (so they download from GitHub) and the
one-line `notes`, and ignore `assetSha256` and the `.sig`; it has no
string `sha256`, which they would check against whichever archive they
download. It reaches them only while the Gitea answers at that old name.

Once nobody runs 1.4.x: pass `--no-bridge`, then delete the bridge part
of `tool/sign_release.sh` and this section; the Gitea then serves nothing
the apps read.

### Signing

Every manifest and the config are signed with the owner's Ed25519 key
([Updater](ARCHITECTURE.md#updater), Signing and the config); from 1.5.0
on the app installs nothing else.

- **The key.** The private key is the 32-byte seed, base64, in
  `~/.config/starsync-signing-key` (mode 600), or in
  `STARSYNC_SIGNING_KEY` for a one-off shell. It is never committed,
  printed or logged. `dart tool/keygen.dart` made it once (it refuses to
  overwrite the file) and printed the public key, which is
  `trustedKeys` in `packages/core/lib/src/distribution.dart`. **Back it
  up** offline (a password manager or an encrypted USB stick): without
  it no update can be signed again, and the only way out is a manual
  reinstall of a build with a new key for everyone.
- **Tools** (`tool/`, `cd tool && dart pub get` once):
  `dart tool/sign.dart <file>...` writes `<file>.sig`;
  `--verify <file>...` checks against `trustedKeys`; `--check-key` says
  whether the key is there. `dart tool/sign_config.dart` sets the
  config's serial one above the committed one, checks the config,
  signs it and stages both files. Both take `--key <path>` (repeatable:
  one signature line per key). `tool/release.sh`, `tool/sign_release.sh`
  and `tool/dev_release.sh` use them and stop when there is no key.
- **Moving an address.** Edit `updates/starsync-config.json` (new
  address first, the old one kept while it still works), run
  `dart tool/sign_config.dart`, commit, push. Each app takes it at its
  next update check, from any address it already knows, and keeps it.
  For the config's own addresses (`configUrls`), publish the config at
  the new address too before the old one goes away; an app that missed
  every move still tries `distribution.dart`'s list. Signatures make any
  host safe to list: a host can withhold the config, never change it.
- **Key handover.** `dart tool/keygen.dart --out <path>` makes the new
  key; put its public key in the config's `nextKey` and sign with both
  (`dart tool/sign_config.dart --key ~/.config/starsync-signing-key
  --key <path>`), and sign manifests with both too. Apps that read that
  config trust the new key; the first config they read signed by the new
  key alone retires the old one in that app. Put the new key in
  `distribution.dart` for the next builds, and keep signing with both
  until apps older than that build are gone.
- **A fork** changes only `distribution.dart`: its own `trustedKeys`
  (from its own `tool/keygen.dart`) and its config and manifest
  addresses; then its own `updates/starsync-config.json`, signed.

### CI on GitHub

`.github/workflows` is CI for `Foxyz1302/starsync` on GitHub-hosted
runners (`ubuntu-latest`, `windows-latest`); it builds and publishes
every release ([Releasing](#releasing)):

- `ci.yml`: as on Gitea (core, server, `updater-windows` with the build
  and the smoke run); a newer push to a branch cancels its running check.
- `release.yml`: on a `v*` tag, `linux` and `windows` build the archives
  and keep them as run artifacts, then `publish`, only once both built,
  runs `dart tool/publish_github.dart vX.Y.Z <tarball> <zip>` (no
  manifest: the tree's is still the previous release's until
  `tool/sign_release.sh`). **Test builds**: Actions → release → Run
  workflow (any branch) builds both and publishes nothing; the archives
  are the run's artifacts `starsync-linux-x64` and
  `starsync-windows-x64` (kept 14 days; GitHub hands each out zipped),
  named and stamped with the run's `version` input (e.g. `1.5.0-dev.7`,
  so a test build's diagnostics never read as a release), else the
  pubspec's version (`gh workflow run release.yml -f version=…`). Both
  packagers take it as `VERSION` from the environment.
- `.github/actions/setup-flutter`: Flutter at `FLUTTER_REF` on PATH, the
  SDK cached per commit of that ref, the pub cache per lockfiles. On
  Windows it runs `tool/setup_flutter_windows.ps1 -Ref … -Dir …`, whose
  ATL step does nothing there (GitHub's image has the component).
- `FLUTTER_REF`, at the top of both workflows (keep them equal): a
  Flutter branch (`stable`, `beta`) or release tag. Pinned to
  `3.48.0-0.5.pre`, the Flutter the app is developed on, so releases are
  built exactly as tested (the Linux frame-pacing shim checks the engine's
  private layout and steps aside on any other version). Move it together
  with the local SDK.

`tool/publish_github.dart` (`vX.Y.Z <file>...`, `dev <file>...
<manifest.json>`) creates the release or refreshes its text, replaces each file and a
`<file>.sig` beside it, `.json` files last, and for `dev` deletes the
prerelease's other assets. `--dry-run` prints the plan without a token or
network; `--repo owner/name` outside Actions; token `GITHUB_TOKEN` or
`GH_TOKEN`, else `gh auth token`. It warns when a manifest's asset URLs
are not that release's downloads.

Secrets: `GITHUB_TOKEN` (built in; `publish` asks for `contents: write`)
and, optionally, `DISCORD_WEBHOOK_URL` (set, `tool/package_linux.sh` also
posts a release's tarball to Discord; Gitea's CI never did). No other.

`.gitea/workflows` go with the Gitea, once the
[1.4 bridge](#the-14-bridge) is dropped.

### Changelog

`CHANGELOG.md` is what people read: the update band, the What's new card
([Updater](ARCHITECTURE.md#updater)) and the release page. A version's
section is, in order: an optional one-line summary, `### Highlights`, then
`### Added`, `### Changed` and `### Fixed` (no other headings), each a list
of `- ` items in plain words for the people watching, not commit-speak
("Chat pop-ups stay away while the chat panel is open", not "Notifier:
suppress toasts when panel open").

A user-facing change adds a line to `## Unreleased` in the same commit,
under Added, Changed or Fixed: that is the full list. Internal changes
(tests, refactors, docs, CI) get no line. Highlights are written once, when
a release is cut, not per commit: 2 to 5 noticeable things, one short line
each, for someone who reads nothing else ("Your volume is remembered, and M
mutes"). The app shows them first, with the full list behind "All
changes"; the band shows the first three. Without them (`tool/release.sh`
warns) the app shows the first few items instead. The summary becomes the
manifest's `notes`, the only thing 1.2.x/1.3.x apps show (without it, the
highlights, else the first items); refresh it before cutting too. Versions
carry no date (the tag and release page have it).
`tool/changelog.dart` reads and cuts the file (`cut X.Y.Z`, `json
<version|unreleased>`, `markdown <version|unreleased>`); its tests are
`tool/test/changelog_test.dart` (`cd tool && dart test`).

### Third-party licenses

Starsync is MIT (`LICENSE`). What it ships of others is listed in two
places, from one list (`starsyncNotices`,
`packages/core/lib/src/third_party.dart`) plus Flutter's `NOTICES` (every
Dart package and the engine, which the build writes):

- **In the app**: Settings → Help & about → Open-source licenses opens
  Flutter's license page; `registerThirdPartyLicenses`
  (`platform/third_party_licenses.dart`, at start) adds Starsync's own
  entries: on Windows mpv and FFmpeg (the `libmpv-licenses.txt` the
  media_kit fork puts beside the exe, after a note with the
  corresponding-source link), ANGLE, SwiftShader, the Vulkan Loader and
  d3dcompiler_47 (their texts are assets in
  `apps/desktop/assets/licenses/`); on Linux a line saying the system's
  libmpv is used and not included; on both Anime4K (the MIT `LICENSE`
  beside its shaders) and the uosc credit.
- **In each archive**: `LICENSE` and `THIRD_PARTY_LICENSES.txt` at its
  root. Both packagers run `dart tool/third_party_licenses.dart
  <linux|windows> <bundle> <out>`, which writes the same entries, then the
  bundle's `NOTICES.Z` unzipped, in NOTICES' format; it stops when an
  asset or, on Windows, `libmpv-licenses.txt` is missing.

The libmpv the Windows build ships is LGPL-3.0-or-later, so its
corresponding source must stay downloadable: `libmpvSourcesUrl` (the one
place it is written) points at a copy in a release of
`Foxyz1302/starsync`, tag `libmpv-20261021-1`, asset
`libmpv-windows-20261021-1-sources.tar.xz` (SHA-256
`77e612c8110b1731c9b180cda840bb965939440c743d480f34cab957861e9d11`).
**Upload it once**, before the first public Windows build: download it
from freeKC's release
(`https://github.com/freeKC/libmpv-builds/releases/download/20261021-1/libmpv-windows-20261021-1-sources.tar.xz`,
266 MB), check the SHA-256, then `gh release create libmpv-20261021-1
--repo Foxyz1302/starsync --latest=false --title "libmpv 20261021-1
sources" --notes "Corresponding source of the libmpv-2.dll in Starsync's
Windows builds (LGPL-3.0-or-later)."
libmpv-windows-20261021-1-sources.tar.xz` (`--latest=false` keeps the
newest Starsync release the latest one). When the fork moves to another
libmpv build, mirror its sources the same way under a new tag and change
`libmpvSourcesUrl` and the freeKC release named in `libmpvWindowsNote`;
when it moves to another ANGLE, refresh the texts in
`assets/licenses/`.

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
on Linux (on Windows `%APPDATA%\foxyz\Starsync\logs`; Settings → Help & about → "Open logs
folder" finds it anywhere), with your server's lines
in the same file; a dedicated server prints its folder at start
(`--log-dir`). Users send theirs with Settings → Help & about → "Copy
diagnostics".

A Windows friend without a terminal habit: `tool/windows_report.cmd`
(one file: a cmd header that runs the PowerShell below it). Dropped into
the Starsync folder and double-clicked, it collects the app's logs,
Windows' crash events (1000/1001/1026), that install's file list (and
any other found on Desktop, Downloads, Documents, AppData, Program
Files) and a 20 s test start with its exit code, zips them to the
Desktop and copies the zip (Ctrl+V into Discord).

Where the session logs are (apps upload every 10 s and on leaving,
`POST /l/<sid>/<token>`, PROTOCOL.md "Diagnostics"; the server merges
them into its session log): a dedicated server keeps them on its machine
under its logs folder (`--log-dir`; ask the server's owner), a member's
own server (Invite) in that host's app logs folder (above).
`session-YYYY-MM-DD.log` is the day's; `server-*.log` next to it is the
server's own. Over HTTP, a member of that server can read it:
`GET /l/<sid>/<token>?hours=N`
(gzip text; `sid` is `default` on a dedicated server; "Copy
diagnostics" does this through `DiagShare.fetchSessionLog`).

Crashes and freezes: the session log can miss a crashed app's last
seconds and everything after a freeze; read that machine's own
`app-*.log` (written at once, its own clock). A native crash ends the
log without a Dart error; the next start logs `crash: previous run ended
without a clean close` (on Windows followed by `crash: windows crash
record: ...` with the faulting module and exception code), and the
`player: player #N ...` lines before it show which step the player was
at. `crash: event loop stalled` tells a frozen app from a network drop
(ARCHITECTURE "Logging"). More: on Linux `coredumpctl info starsync`
(with systemd-coredump), on Windows Event Viewer → Application
(1000/1001/1026) or `tool/windows_report.cmd`.

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

- Impeller on Linux (GL, no MSAA on the window's surface) leaves a
  rounded clip's edge jagged, smooth only in frames where a backdrop
  blur renders the frame offscreen; a filled shape's edge is smoothed
  without MSAA. Round pictures are therefore a `drawRRect` with an
  `ImageShader` (`AvatarPicture`), never a clip or a `DecorationImage`
  with a `borderRadius`. A `colorFilter` on that paint applies twice;
  darken on a layer instead.
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
