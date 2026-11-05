# Architecture

Plain overview first: [HOW-IT-WORKS.md](HOW-IT-WORKS.md). Wire format:
[PROTOCOL.md](PROTOCOL.md). Plans: [ROADMAP.md](ROADMAP.md).

## Packages

| Path | What | Rule |
|---|---|---|
| `packages/core` | protocol messages, sync engine (`SyncEngine`, with what's next: `whatsNext`), constants, config, Range parsing, logging, Jellyfin client, updater, the rules every side reads alike (`whats_next.dart`: who puts an Up next item up, who adds the continuation), watched rule (`WatchSession`), the library's L1 (`library/`: release and folder names, `groupLocal`); `testing.dart` (test support for all three packages, not in `core.dart`: `FlakyProxy`) | pure Dart, no Flutter |
| `packages/server` | Relic HTTP + WebSocket server (`SyncServer`, `ServerHub`, `Session`, media endpoint, relay buffer, Jellyfin relay), the `serve()` entrypoint, `bin/server.dart` (dedicated server) | pure Dart, no Flutter |
| `apps/desktop` | Flutter app: UI, `AppGraph` (composition root), `SyncClient`, `Connection`, `SessionCoordinator`, `Navigation`, `YourServer` (`ServerIsolate`), `MediaPipeline` (opening media), `QueueController` (what's next on this app), `WatchTracker` (watch tracking), `PlaybackController` (the session player's marks and commands), the player host (`PlayerHost`, `MediaKitHost`: the only media_kit user besides the `Video` widget glue), update UI (`UpdateController`) | ships with `starsync-server` |
| `tool` | harnesses: `range_logger`, `shaper`, `fake_viewer`, `e2e_check` | dev only |
| `deploy` | systemd unit for the dedicated server | |
| `third_party/media_kit_video` | upstream media_kit_video 2.0.1 with Starsync's patches (`starsync/README.md`: Flutter ≥ 3.38 EGL display on the platform thread, the X11 GLX step-aside, a `VideoController` that sets up without waiting for a next frame, texture names deleted in Flutter's context) | vendored; re-apply patches on update |

Guard: `packages/core/test/flutter_free_test.dart` fails if anything under
`core/lib` imports Flutter, `dart:ui` or `signals_flutter`; CI runs
analyze + tests for core and server on every push. Server has no such test but
the same rule; CI checks it with `dart compile exe` of `bin/server.dart`. The client
WebSocket (`web_socket_channel`) lives in `apps/desktop`; Relic has no client.

## Server lifecycle

One entrypoint: `serve(config, events:)` in `packages/server`. `config` is
an `AppConfig.toMap()` (primitives only, so it crosses isolates). It starts a
`SyncServer` (bound to all IPv4 interfaces, or 127.0.0.1 with an extra
`'loopbackOnly': true` key) and reports on the `events` port: `ready`
(with the port and a control SendPort), `error` (start failed), and every
log record as `log`. On the control port: `{'t':'stop'}` closes all
sockets and returns, and the isolate exits; `{'t':'file', 'path',
'reply'}` makes a local file the hosted one and answers its name and size
(`ServerIsolate.setFile`: a File put up here then sends a `swap` with that
name and size, which the server matches to the file); `{'t':'share',
'port', 'secret', 'jellyfin', 'reply'}` and `{'t':'unshare', 'reply'}`
attach and detach the network listener (below).

- **Your server** (`session/your_server.dart`, `YourServer`): every app
  runs one server for its whole life, started when the app starts
  (`Navigation.start`) as a `ServerIsolate` running `serve`: port 0 (a
  free one), loopback only, no password, a random `hostKey` per app run,
  named "<your name>'s server", its session log in the app's logs folder
  and its log records in the app's log as `server.<logger>` (see
  "Logging"). Nobody else can reach it. The isolate runs with
  `errorsAreFatal: false`: an uncaught async error is logged and the
  server keeps going. If the isolate dies anyway, `YourServer.crash` is
  set (the shell says so in a dialog) and, unless you are in a friend's
  server, the navigation starts a new one and goes home to it.
- **Listeners**: `SyncServer.share(port, secret, jellyfin)` attaches a
  second listener on every IPv4 interface at the port from Settings →
  Party → Your server (default 8080) to the running server (Relic serves the
  same routes on both), sets the password and the Jellyfin relay logins
  (one per linked account, `relayCredentialsFor`, so guests without an
  account watch Jellyfin items through the server with your sign-in on
  the item's own Jellyfin); `unshare` closes it. Nothing restarts for
  either: members on the loopback listener keep their sockets, the media
  and Up next stay. Unsharing sends everyone but the host out: each
  leaves at once (feed `leave`, reason `closed`) and its socket closes
  with 4016, so its app does not retry (see "Connection"); the password
  goes back to none. A port another program holds fails the share with
  its reason; nothing else changes.
- **Invite** (`session/invite.dart`): `YourServer.invite()` shares the
  server if it is not yet and returns an `Invite`: the host, the port, the
  name ("<your name>'s server"), whether a password is needed (not the
  password itself), the version and an `fp` field reserved for a pinned
  certificate (`wss://` with a self-signed one, later; always null). This
  machine's addresses are `inviteAddresses` over `NetworkInterface.list`:
  IPv4 only, no loopback, link-local (169.254/16) or proxy fake-IP
  (198.18.0.0/15, what TUN proxies like Clash hand out) address and no
  container or VM bridge (`docker*`, `br-*`, `veth*`, `virbr*`, `vmnet*`,
  `vboxnet*`, `cni*`, `podman*`, `lxcbr*`, `lxdbr*`, `vEthernet`,
  VirtualBox, VMware); 192.168 first, then 10/8 and 172.16/12, then a mesh
  VPN's 100.64/10, then any other (public) address. Sharing also looks up
  the internet address (`lookUpPublicAddress`, `session/public_address.dart`):
  plain-text "what is my IP" services over HTTPS (ipify, icanhazip,
  checkip.amazonaws, ifconfig.me), asked in order until one answers a
  public IPv4 address, 3 s each; that tells those services this network's
  address, nothing else. `YourServer.reach` (`InviteReach`) holds both: the
  internet address first, then this machine's, each with its
  `AddressKind` (internet, home network, VPN); `forwarding` when the
  internet address is not on this machine (behind a router: friends
  elsewhere get in only with the port forwarded). No UPnP. The invite
  carries the internet address when the lookup answers within 4 s
  (`publicWait`), else the best local one, switched to the internet one
  when it lands. `YourServer.inviteLink(invite)` is what Invite copies:
  the bare link with the password the server was shared with
  (`starsync://203.0.113.7:8080/?name=Bob%27s+server&pw=…`; the link is
  the key, nothing around it). The link format:
  [PROTOCOL.md "Invite link"](PROTOCOL.md#invite-link) (`InviteLink`:
  `parse`, `uri`, a `toString` without the password). `inviteIn` finds an
  invite in a text (a link anywhere, or a 1.3.x plain invite's address;
  never a bare address); `addressIn` reads `host:port` out of anything
  (the Join card's address field; a 1.3.x app pasting a link reads its
  address this way). `stopSharing` unshares.
- **Links and the join prompt** (`session/join_offers.dart`, `JoinOffers`,
  in the composition root): a clicked `starsync://` link (the app's start
  arguments, or a second start's, see "Single instance" under "App
  events and platform ports") and an invite on the clipboard when the
  window gains the focus (and at start) become `offer`: "Join Bob's server
  (203.0.113.7:8080)?" with the server's `/health` (its name, version,
  how many watch, the version gate's sentence, or unreachable). Not
  offered: links to your own server (`YourServer.isOwn`), to the server
  you are in, and the text this app just copied (`copied`). Join
  (`accept`) fills the Join card's fields (a link without a password
  takes the one saved for that recent server) and joins through
  `ConnectFlow` and `Navigation.join` (version gate, recents; no name
  yet: asked first, see "Join card"); a failure opens the Join card with
  its error. A clipboard invite joined or
  dismissed (Not now) is not offered again: the connect form box keeps the
  last 30 as fingerprints (a hash of the link), never the links; the
  clipboard's text is only parsed, never logged or stored.
- **Where you are** (`session/navigation.dart`, `Navigation`): `place` is
  `none` (starting, or between two servers), `yours` or `friend`. The app
  starts at home: your server, joined over 127.0.0.1 with the host key
  (the `hostKey` stands in for the password, so a password set later never
  locks this app out), `hostFile` set to `YourServer.setFile`. A join
  first reads the friend's `/health` (the version gate, below); an
  unreachable server stops there, still at home. Then this app leaves
  your server (`bye`) and connects to theirs; a join that fails or is
  cancelled goes home again. Leaving theirs (Leave), or theirs closing to
  friends (`ConnRefused` `closed`: "The host stopped sharing their
  server"), goes home. Your server stays up all the while: what plays
  there and Up next wait for you, and whoever you invited stays in it.
  A joined server's name and version (`serverLabel`, `serverVersion`)
  come from its `/health`, read at the join and again whenever it comes
  back restarted (an update); yours is this app's. The Join card's recents
  are the friends' servers that got in.
- **Version gate**: `/health` gives `protoMin`, `protoMax` and `version`
  (a proto 15 server only `proto`, used for both). `versionFit` against
  this build's range: ranges that meet are fine; a server whose newest is
  older than this app's oldest "runs Starsync 1.2.1 — they need to
  update", one whose oldest is newer "— you need to update", and then the
  Join card offers "Check for the update" (the updater, see "Updater").
  Nothing is dialled for either. A server that says nothing about its
  version is left to the hello's refusal (see "Connection").
- **Dedicated server**: `bin/server.dart` compiled with `dart compile exe`
  and shipped next to the app as `starsync-server`. It parses flags
  (`--port`, `--secret`, `--name`, `--media`, `--advertise-host`,
  `--jellyfin <file>`, `--[no-]yt-dlp`, `--yt-dlp-dir`, `--yt-dlp-cookies`, `--config`; default port 8080) into the same map and calls `serve`
  (`--log-dir` only picks where its log files go, see "Logging")
  (`--upgrade` / `--check-update` run the [updater](#updater) instead);
  SIGINT and SIGTERM stop it. A Flutter binary cannot run without a
  display, which is why the server is its own build.
- **App close**: after the players and the `bye` (see "Desktop UI",
  closing), your server stops (`stop`, then killed after 3 s).

`SyncServer` runs a 1 s heartbeat (`ServerHub.heartbeat`): closed-socket
sweep, the engine's sweep (silence, joining, gone notices, grace),
relay source state, warm relay, rates, state + feed broadcast. There is
one session, id `default`.

Passwords: the default secret is empty, which means an open server (a
warning is logged). Otherwise one shared secret, compared at hello; your
server's is the one from Settings, set when it is shared.

Host: the app generates a random `hostKey` per app run, puts it in your
server's config and sends it in its own `hello`. The member whose key
matches is the host (`members[].host`: the crown, art rights) and needs no
password. The address a connection comes from plays no part (so a reverse
proxy or tunnel on the same machine does not make everyone the host). The
dedicated server has no key, so it has no host. Nobody removes anyone:
members set each other away ("Presence" below), the host included, since
your server and its `/m/` file serving do not need the host's player;
only stopping sharing sends guests out.

## Composition root

`AppGraph` (`app/app_graph.dart`) is built once in `main.dart`
(`AppGraph.build`) and constructs and disposes the app's systems: the
`Ports` (the player host among them, handed to the coordinator), the sounds (`SynthSfx`), the `Notifier`, the `Connection`, the
`SessionCoordinator` (handed the settings and the watch tracker), the
connect form and recents (`ConnectStore`, `state/connect_prefs.dart`),
`YourServer`, `Navigation`, the join prompt (`JoinOffers`), the library's matches (`ShowMatcher`,
"Library", whose `refForPath` it hands the coordinator as `fileRef`, and
a `LocalNextFinder` over it as `nextFile`) and watch tracking
(`WatchTracker` with the device's `WatchHistory`, "Watch tracking"); it
wires them
through their constructors (and gives `Profile` the form and the push) and
has no logic or signals of its own. Widgets reach it through one
`AppScope` InheritedWidget (`AppScope.of(context)`, readable in
`initState`); `shutDownApp` gets it from `main` (`closeAppWith`). Tests
build their own (`test/test_graph.dart`). The app's remaining `.instance`
singletons (settings, Jellyfin accounts, the updater, the profile, Files'
folders, yt-dlp, recent links) may only lose uses: `singletons_test`
fails when one gains a use or a new one appears.

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
  `Connection.serverNow()` (= `SyncClient.serverNow()`: local clock plus
  offset), so a client whose clock is off still lands on the server
  position.
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
- **Ready gate** (HELD to PLAYING): the members that count for the gate
  (`SyncEngine.countsForGate`: in the set, no player error, and their
  presence counts, see "Presence") are not empty and every one is ready
  and has `buffered >= need`. `need` is 4 s
  (`minBufferSecs`), or near the end what is left minus 2 s
  (`endSlackSecs`, floor 0), since mpv cannot buffer past the end. So a
  lone viewer plays alone; with others present everyone must ready.
  While HELD, `state.hold` says why (`HoldReason`: a joiner within its
  bound, someone unready, a short buffer, the same with the relay's
  source gone, or nobody to start).
- **In-set** (`EngineMember.inSet`, who the gate may wait for): a member
  joins it on joining, or on coming back from `gone` or `away`, while not
  PLAYING (any media, the one the server started with included); joining
  while PLAYING it stays out (`ready=false`) until it readies. A swap puts
  every member in the set and keeps everyone's ready flag, so the next
  video starts once everyone ready has buffered (the client never
  unreadies itself on a swap; a reconnect restores a ready across one).
  A player error removes from the set; presence decides whether a member
  in the set counts.
- **Identity**: an install sends a random client id (`hello.client`,
  private: never broadcast, never logged) and a `seq` that rises with
  every connection. The server maps the client id to one member for its
  life: the same id and token on every reconnect (`welcome.resumed`),
  so the member keeps its ready flag, presence, queue items (`by`), the
  relay it serves and its picture. A hello takes the member over when its
  `seq` is not older than the member's; the older socket gets `replaced`
  and closes, an older hello gets `stale` (so two windows of one install
  cannot fight: the newest wins, the client stops on `replaced`).
  `welcome.instance` changes per server boot, so a client tells "the
  server restarted" from "my grace ran out" (both: `resumed` false).
- **Presence** (`Presence`, `members[].presence`; D1, D2):
  `joining` -> `in`, `away`, `gone`. What each counts for is one table,
  `PresencePolicy.countsFor(presence, Purpose)` in core
  (`presence.dart`), shared by the server and the app: `in` counts for
  the gate, the ready counter, watched tracking, preloads and social
  notifications; `joining` for all but tracking, and for the gate only
  while HELD and for at most `joinerHold` (15 s) after it started
  joining, never while PLAYING; `away` and `gone` for none.
  - `joining`: a new member, one back from `gone`, or one back `in` from
    `away`, while media is up (with nothing up it is `in` at once). It
    loads in the background; a report that holds the current media at
    the server position (within the 5 s seek threshold) with `need`
    buffered makes it `in`, already in sync, so a joiner during playback
    never pauses anyone (D2). A report error or `joiningTimeout` (60 s)
    ends joining too. Coming `in` while PLAYING it stays out of the set
    until it is ready (its own auto-ready follows its buffer); while
    HELD it keeps its place in the set. While HELD a joiner holds the
    start at most 15 s (bounded hold), then the others go on without it.
  - `away` (sat out): anyone sets anyone away (`presence` `away`, the
    host included); only the member itself comes back (`in`, through
    `joining`). Its ready flag and reports are kept but never count;
    `force` leaves it alone; a swap leaves it away. Away survives a drop
    (back from `gone` it is `away` again).
  - `gone`: its socket closed or fell silent. Kept for the grace
    (`Liveness.grace`, 10 min) with everything it had, its token working
    (`/m` `/r` `/j` URLs, the relay channel); out of the gate. The feed
    says `gone` only after `goneNotice` (10 s), so a quick reconnect is
    silent; back after that line it says `return`. After the grace it
    leaves (feed `leave`, reason `grace`); `bye` leaves at once (reason
    `bye`). Only a hello brings it back; frames of a socket that no longer
    holds the member are ignored.
- **Player error** (`EngineMember.error`, `report.error`,
  `state.members[].error`): a member whose player cannot open the current
  media says why in its reports; the server takes it out of the set at
  once (like away, but automatic: `ready`/`force` do not put it
  back, its ready flag is kept), so the others start without it; it also
  ends a `joining`. A report without it (the media opened, after a reload
  too) or a swap clears it: back in the set like a join while not
  PLAYING; while PLAYING at once if it is ready (the others then hold for
  its buffer), else from its `ready`.
- **Pause**: while PLAYING, any member counting for the gate who becomes
  not ready or under `need` buffered flips the server to HELD (feed action `pause` by
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
- **User seeks**: a hosted player's public `seek` is the user's (its
  `syncSeek` moves mpv): the session's seek bar (`ChapterSeekBar`, one `seek` per pointer
  move while dragging and one on release, like media_kit's), the arrow
  keys, skips, chapter jumps and `seekTo` all become explicit events. The player moves at
  once (scrub preview); `UserSeekGate` sends one `seek` intent with a fresh
  `seq` after 300 ms without another request (`seekDebounceMs`). While the
  user is seeking, and until the echo of the last sent seq arrives (3 s at
  most), server seeks never touch the player; the echo of our own seek is not
  applied either (the player is already there). A server seek that has not
  landed after 1.5 s is re-applied once (`_checkSeekLanded`), to the server
  position recomputed now, and only while its event is still current, the
  user is not seeking and the relay it reads has its source ("Viewer
  recovery" under "Media pipeline").
- **Liveness**: WS ping every 5 s; a socket without any frame for 15 s
  (`silence`) is closed (4015) and its member goes `gone`; the grace, the
  `gone` notice, the joiner bound and the joining timeout follow. The
  durations are a `Liveness` (core, `sync_engine.dart`; defaults
  `RelayConstants.silenceSecs` / `graceSecs` / `goneNoticeSecs` /
  `joinerHoldSecs` / `joiningTimeoutSecs` / `pingIntervalSecs`) given to
  `SyncEngine(liveness:)` and `SyncServer(liveness:)`; all but the ping
  are measured on the engine's clock (`SyncEngine.clock`,
  `SyncServer(clock:)`) by the 1 s heartbeat sweep, so a test with a
  fake clock steps through them; the ping is the socket's own real
  timer. Any frame counts (`SyncEngine.touch`). Closed sockets are polled
  with `isClosed` every second: Relic's server-side `onDone` does not
  fire for dead peers, so presence never relies on it. A half-open link
  is caught by the silence.
- **Client policies**: a drop is not the end of the session. The app
  keeps the last state (`SessionCoordinator.stateStale` while it
  reconnects or after the connection ended; the strip says
  "reconnecting…"), the player and its media, and a relay it
  serves; it reconnects with backoff and jitter and comes back as the same
  member (see "Connection" below). No frame for 3 s is "connection
  unstable", 9 s is lost (well under the server's 15 s). A welcome that
  resumed needs nothing re-sent; a new member (grace over, server
  restarted) gets the app's ready and sitting out again, and the media
  opens again only when it changed (or its URL named the old token). A
  restarted server that has no media while this app had some gets it
  back ("Server restart" below). The
  app's own `ping` every second keeps it under the server's silence limit
  even with nothing playing. Cancel during setup aborts the join. Leave
  and closing the window send `bye` (see "App close" under Desktop UI);
  Update and restart does not.
- **Server restart** (the queue stays in memory, the server stores
  nothing): a reconnect that finds another `welcome.instance` with no
  media, while this app had media up, holds it: the player plays on and
  states without media are not applied (the watch goes on with it, see
  "Watch tracking"). One app offers it back (`swap.restore`: the media,
  this player's position, whether it played); who goes first is read
  from the old state alone, so the apps agree: who put it up or passes
  it on after 0.5 s, the others by their old member id from 3 s on,
  1.5 s apart, each only while the server is still empty and only what
  it can put up again (`_offerBack`: a Jellyfin item with its own
  account, its file, the link it put up, a link everyone opens). The
  server keeps the first offer. When it is back as the same media under
  a new `mediaId`, the player keeps it unless its URL named the old
  token (a relay viewer's `/r/`, the host's `/m/`: opened again), and
  what this member passes on is served again (`MediaPipeline.resumeAs`:
  its file, its link, its Jellyfin item for viewers without an account);
  the watch, the Jellyfin reports and a cleared continuation carry over.
  Up next comes back too (`QueueController.restoreAfterRestart`): the
  app whose offer won adds the links everyone opens and the Jellyfin
  items, every app its own links passed on and files; a server-fetched
  link is lost with the old server. Nobody offering within 30 s: the
  app lets go of it.
- **Auto sit-out** (`AutoSitOut`, `session/auto_sit_out.dart`; Settings
  "Auto sit-out", `AppSettings.autoSitOut`, default on): not playing and
  no input for 5 min sets this member `away` (reason `idle`); minimised
  or hidden for 10 min does, playing or not (`minimised`): while playing
  idle input does not count, and watching is activity, so a pause after
  a long watch starts a fresh clock. Input (any key or pointer use in the
  window, `markInput`, from `AppShell` and the controls) or the window's
  focus brings
  it back `in` (without touching the ready flag), but only from an away
  it set itself: a manual one (own or someone else's) stays. Never when
  alone (`isAlone` in core: no other member connected, `in`, `joining` or
  `away`). The window changes come from
  `ShellPort.watchActivity` (focused, unfocused, minimised, hidden); the
  timings are `AutoSitOutTimes`.
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

## Connection

`Connection` (`session/connection.dart`) is the link to the server, made
in the composition root (`AppGraph`) and passed to the
`SessionCoordinator`. It owns the `SyncClient` socket, the first connect
(`begin` + `dial`), reconnects (`delayFor`: 1 s, doubling per failed
attempt up to 15 s, each ±20 % jitter), the epoch (`invalidate`,
`isCurrent`) that makes a cancelled connect or attempt stale, the 1 s
heartbeat (clock `ping`, the diagnostics tick, the silence check), the
diagnostics uploader (`diag`, started with the session, stopped by
`close` before the socket), "Stop reconnecting" (`cancelReconnect`),
"Retry" (`retry`) and setup cancel (`cancelConnect`).

Each hello is built by an injectable `HelloBuilder` (`defaultHello`):
this build's version range (`RelayConstants.protoMin` .. `protoMax`), the
install's `ClientIdentity` (`session/identity.dart`: a random 22
character base64url client id and a `seq` that rises with every
connection, both in the settings box, so per data folder and per
`STARSYNC_PROFILE`; tests get a fresh in-memory one per `Connection`),
`app` (the app version), `platform`, `caps` (source always; resolve when
the app's yt-dlp is there; jellyfin when an account is linked, checked by
the coordinator at each connect) and, on a reconnect to a server seen
before, `feedAfter` (the last `feed.seq`). The replay (`welcome.feed`)
reaches the activity log only, marked `replayed`; a welcome of another
`instance` (a restarted server) drops it and counts from 1 again.

`Connection.state` (a signal of the sealed `ConnState`): `ConnClosed`
(before a connect, after leave or a cancel), `ConnConnecting` (the first
dial), `ConnOnline` (welcome received, frames arrive), `ConnUnstable`
(the same socket, nothing for `unstableAfter`, 3 s), `ConnLost` (the
socket closed or errored, or nothing for `silenceLimit`, 9 s: the socket
is dropped, the next attempt scheduled), `ConnReconnecting(attempt)` (an
attempt dialling, and after it failed until the next one),
`ConnRefused(code, message)` (`version`, `secret`, `closed` for close
4016, the host stopped sharing their server, or empty for a first dial
that failed otherwise; nothing retries) and `ConnReplaced` (`err`
`replaced`, close 4013 or 4014: another window of this install holds the
member; nothing retries, "Retry" takes it back). The silence and the
lost sound are measured on `Connection.now` (injectable, UTC wall clock
by default); the heartbeat and the reconnect delay are real timers.

Refusals in plain words (`connectErrorText`, `versionText`): `version`
says whether the host runs an older or a newer Starsync (from the
server's `min`/`max`; a proto 15 server's codeless `proto mismatch` is
always an older host), `secret` a wrong password, `replaced` "Starsync
was opened in another window". Close code 4015 (the server found it
silent) and any other drop reconnect.

The state is the first input of the session's status (see "App events
and platform ports": "Connecting…", "Reconnecting…" with Cancel,
"Connection unstable…", the refusal or "replaced" with Retry; the strip's
"reconnecting…"); the coordinator also reads it as `reconnecting` (lost
or reconnecting), `unstable` and `stateStale`. A drop that lasted
`lostSoundAfter` (4 s; a silent link counts from its last frame) raises
`ConnectionLost`, the reconnect that follows `ConnectionBack` (each once
per drop, through the Notifier): a quick flap makes no sound.

The session's part of a welcome is the coordinator's `onWelcome`
handler (`_onWelcome`), called before the welcome's state goes out: the
first welcome and a resumed one need nothing; a new member after a drop
gets the app's intent again (`ready`, `presence` `away`) and the media is
forgotten (opened again from the state) only when it changed. The
incoming streams (`states`, `feeds`, `nudges`, `errors`), the send
methods, the `token`, `memberId` and `serverNow()` are read through it.
`close(bye:)` sends `bye` and waits briefly for the server's close, so
the frame goes out before the socket does.

## Media

Three sources, same sync. Any of them can also go through the relay
(below).

- **Link**: the media field holds an http(s) URL. It travels as `media.url`
  in `swap` and `state`, and as `mediaUrl` in `welcome`. Each app plays it
  directly (a web page through its own yt-dlp, see "yt-dlp"); the server
  is only the clock. A pasted link that
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

mpv settings (the player host, `platform/desktop/media_kit_host.dart`,
set on every player before its first open): `Player` with `bufferSize` 256 MiB
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
(older ffmpeg ignores `reconnect_max_retries`), `ytdl=no` (pages are
resolved by the app, never by mpv's Lua hook). A load that fails (mpv's
fatal "No video or audio streams selected", or an EDL track that cannot
be opened) before a duration is known is reported once per open
(`onLoadError`), with ffmpeg's HTTP status when this player gets
ffmpeg's log (ffmpeg logs through one mpv instance per process: the
first one, and once that is disposed the next one created; the host
passes the HTTP errors any player gets on as `httpErrors`). Since every
media gets its own player, the session player is often not that
instance: the status is a bonus, load errors are detected either way.
That, a page's resolve error (yt-dlp's words and the cookies it used,
D11, see "yt-dlp") and a failed open become the coordinator's
`playerError` in plain words (`playErrorText`, core
`link_probe.dart`: 412/precondition/login/cookies/sign in → "This site
needs cookies — Settings → Library & accounts → Web links → Cookies", 403 → "Not allowed
(403)", 404/410 → "Not found (404)", "Unsupported URL" → "Not a video
page yt-dlp knows", network errors → "Couldn't reach the site", anything
else as is; `withCookieNote` adds the cookies to the two sign-in texts).
It rides in `report.error` (see "Player error" in the sync
model) until the media opens (a new duration) or the server's `mediaId`
moves on; the pill shows "Can't play this: ..." with Retry (Reload
video). The cache is in RAM: `cache-on-disk=no` is pinned (media_kit
sets it on without a `cache-dir`, so mpv fell back to RAM anyway, warning
"Failed to create file cache." on every open). mpv
ignores invalid values silently, so every pin is read back and a mismatch is
logged and kept in `pinMismatches`. Measured against the `/m` endpoint
(`readahead_e2e_test`): a paused player buffers ~147 s ahead (10 s before).
media_kit has no public `setProperty`/`getProperty`; the host calls them
through a guarded dynamic call on `player.platform` (`HostedPlayer`). Hardware decoding comes from Settings (auto, off, custom)
and is passed to the `VideoController`; env `SYNC_RELAY_HWDEC` (e.g. `no`)
overrides it. Auto is mpv `auto` on Linux and `auto-copy` on Windows
(`autoHwdec`, also for a blank custom value): media_kit renders through
ANGLE there, where `auto` picks the dxva2 interop, which cannot create its
EGL surface ("Failed to create EGL surface"); `auto-copy` decodes on the
GPU (d3d11va-copy, dxva2-copy, ... whichever works) and copies frames
back, needing no interop. It is read per player, so a change applies on the next media,
join or Reload video.

Shaders (per viewer, local only, no wire change): mpv `glsl-shaders`, set
through the same dynamic `setProperty` and read back
(`PlaybackController.applyShaders`). The value is the platform path list
(`:` joined, `;` on Windows). The read-back is compared as a list
(`shaderListMatches`): older mpv (0.37 and before, the bundled Windows
libmpv among them) prints it `,` joined. One saved choice in `AppSettings`
(`shaderPreset`, `shaderQuality`, `customShaders`): applied on every player
creation (join, new media, Reload video) and live when changed from the session (the
player panel's Picture, Ctrl+0..6, both also save it). The Anime4K
v4.0.1 files live in `apps/desktop/assets/shaders/anime4k/` (only the 14
the presets use, plus its MIT LICENSE); mpv needs real paths, so
`extractAnime4k` copies them once per version to
`<app support>/shaders/anime4k-<version>-<revision>/` (a `.complete`
marker is written last; other `anime4k-*` copies are deleted), each
rewritten by `highpAnime4k`. media_kit renders through OpenGL ES (EGL
on Linux, ANGLE on Windows), where mpv declares `precision mediump
sampler2D`: a texture read is mediump and Anime4K's weights are bare
literals, so a network's `mat4(...) * go_0(...)` sums ran at half
precision (fp16 on NVIDIA). The VL networks of HQ overflow and round
there: shifted, posterised colours and a regular grid, strongest once
the upscalers run (output over 1.2x the video, so mostly with "Sharp
video" at a large size). The rewrite adds a highp identity function to
each pass and routes every `go_N` / `g_N` read through it; the result on
OpenGL ES then equals desktop OpenGL's (an mpv CLI frame grab,
`--opengl-es=yes` vs `no`, identical). Desktop GLSL ignores the
qualifiers. Custom shaders are passed as they are. `anime4kFiles` maps each mode to the file list of Anime4K's mpv
templates: HQ = the high-end GPU set (VL + M networks), Fast = the low-end
set (M + S). A missing file, a path containing the list separator, a
read-back mismatch, or an mpv `libmpv_render` error while shaders are on
turns shaders off (saved) with a toast.

A player with a video output opens media only once that output is up:
media_kit sets mpv's `vo=libmpv` before the output's render context
exists, and a media opened in between gets no video output ("No render
context set", black picture with sound). On X11 the context comes up
later, which widens that gap (joining with media already up). On Windows
the controller can report ready before mpv's render context exists, so
an open that still fails its video output that way (`cplayer`: "Error
opening/initializing the selected video_out") is opened again once,
500 ms later (`render: the video output was not up for the open`); the
player error it raised clears when the media loads.

A player whose HTTP stream lost the file's size (ffmpeg's "Seek failed
(to N, size -38)": a request of its that got no headers in time, from a
server without the relay's header rule, or the connection reuse above)
fails every seek until a fresh open, so the coordinator runs "Reload
video" once per media for it (`mpvStreamLost`, `onStreamLost`).

Output size ("Sharp video and subtitles", `AppSettings.screenResVideo`,
on by default, live; Settings → Player → Picture → More and the player
panel's Troubleshooting):
media_kit renders mpv into a texture the size of the video and Flutter
scales it, so libass subtitles, mpv's scaler and the shaders all work on
a 720p image for a 720p file. With the setting on and the GPU renderer
(`renderMode` gpu; never in software rendering, where every pixel is CPU
work, nor before the probe knows), the session view
(`shell/video_view.dart`, `VideoOutputSizer` around the `Video`) sends its
size in physical pixels to the host (`PlayerHost.setOutputSize`): at
once the first time, then once a resize has held 120 ms
(`outputResizeDelay`: a window drag, the chat panel, fullscreen, full ↔
mini). The host renders each output at the picture fitted in that view
(`fitOutputSize` over the video's display size, re-fitted when it
changes), not the whole view: the texture has the picture's aspect, so
while a resize settles Flutter scales the last texture to the new view
without a jump (a texture of the whole view, bars included, shrank
inside its own bars until the new one came, about 0.2 s later), and the
shaders work on no bar pixels. The side that fills the view is exact and
the other is rounded down to the view's parity, so the centred picture
sits on whole pixels and is drawn 1:1. It applies to every live output
and to each new one once it is up (`NativeVideoController.setSize`,
which only changes the size the next frame is drawn at); subtitles are
drawn at that size, inside the picture. media_kit's controller sets an output back to the video's
size whenever the video's parameters change (each new file), so the host
sends the size again after it, under the controller's own lock; a fresh
player's first frame or two show at the video's size. A paused player
draws no frame for the new size: the host nudges `video-pan-x` by a
millionth and back so mpv redraws. Off: each output at its video's own
size again (`setOutputSize(null)`). Measured on a GTX 1080, 1280x720
H.264 at 2560x1080 fullscreen: no difference past the noise in the
process's GPU (`nvidia-smi pmon`, 9 to 12 % either way) or CPU.

Render mode: media_kit's Linux/Windows video output creates mpv's render
context (OpenGL, else its software renderer) when the `VideoController` is
created, and nothing in its API says which. The host therefore requests
mpv logs at `v` while the first output of an app start is created
(`PlayerHost.video(probe: true)`): OpenGL init logs
`GL_VERSION` under `libmpv_render`
(`RenderMode.gpu`; "suspected software renderer" means llvmpipe,
`softwareGl`); none within 1.5 s of the controller being ready means the
software path (`software`, where shaders do nothing; the shader toast, the
menu and Settings say so). Into the app log (`mpv`, INFO, all starting
`render`): once per app start on Linux `render env:` (`XDG_SESSION_TYPE`,
`WAYLAND_DISPLAY`, `DISPLAY`, `GDK_BACKEND`, `FLUTTER_LINUX_RENDERER`,
`LIBGL_ALWAYS_SOFTWARE`, `__EGL_VENDOR_LIBRARY_FILENAMES`, `-` when
unset); from that `v` window only mpv's GL init lines (`GL_VENDOR`,
`GL_RENDERER`, `GL_VERSION`, `GL_SHADING_LANGUAGE_VERSION`, `Detected
...`); the mode decided at the end of it; and per player, at its first
frame, `hwdec-current` and the `hwdec` asked for (the first one per app
start also `mpv-version` and `ffmpeg-version`). Why media_kit fell back to
software it only prints on stderr (`media_kit: VideoOutput: ...`), which
the app does not capture. Otherwise a session player logs at `warn`
(`sessionLogLevel`; the host switches levels with
`mpv_request_log_messages` on media_kit's handle, the only raw mpv call
in the app): media_kit drains mpv's log on the UI thread, one message at
a time, so a chatty level, or ffmpeg logging every retry of a refused
request, could starve the UI. Shader errors are `error` lines and still
arrive. The host writes every session and preload player's warnings and
errors to the app log (`mpv`, a few per kind at a time, `preload `
before the prepared player's). Thumbnail players log nothing. The hardware path is
fragile: media_kit borrows whatever EGL context GDK left current on the main
thread (upstream media-kit#1404), so an X11 session or a Flutter/GDK change
can silently fall back to software.

**Player host** (`PlayerHost`, `platform/ports/player_host.dart`; the
desktop's `MediaKitHost`, one per app in `Ports.players`, tests make
their own): creates players by role (`session`: the full cache, `warn`;
`preload`: the prepared one, 48 MiB ahead, muted, `error`; `thumbnail`:
no outputs, no cache, no log) with every pin set before the caller's
first command (`pinMismatches` lists the read-backs that differ), gives
a player its video output (`HostedVideo`, with the hwdec policy:
`SYNC_RELAY_HWDEC`, else the setting, `auto-copy` on Windows) at the
view's size when asked (`setOutputSize`, see "Output size"), runs the
render-mode probe and its diagnostics (`renderMode`, also after leaving),
routes mpv's log, and owns the order players go in: `retire` (pause, let
the view drop the texture: two frames and a route pop, then dispose; a
new session player waits for the last one, so at most one old player
lingers), `dispose` (one no view showed) and `disposeAll` (app close:
every live player, each bounded). On Linux each disposal also trims
glibc's heap 6 s later, after media_kit's own deferred destroy of the
mpv core (5 s), one trim for a run of them (`native_heap.dart`,
`malloc_trim(0)`): what mpv's threads freed otherwise stays in the
malloc arenas, and the app's memory grew with every player. A `HostedPlayer` is one mpv: state and
streams (position, duration, buffer, volume, completed, width, log),
open, play/pause/stop, `seek` (the user's, see "User seeks") and
`syncSeek`, rate, volume, properties, commands, `pin` (set and read
back), its log level. Nothing else in the app imports media_kit except
the `Video` widget glue (`session_player.dart`, `videoControllerOf`).

**Media pipeline** (`MediaPipeline`, `session/media_pipeline.dart`, owned
by the coordinator): the one way to open media, plan → resolve → open →
ready.
- Plan (`planMedia`, `session/media_plan.dart`, pure; `media_plan_test`
  holds the table): from `state.media`, what this member serves (its
  `MediaOrigin`: a file or a link it passes on, a Jellyfin item it put
  up; set at its swap, claimed by the state that names it the relay's
  source), its own capabilities and who is present, where this app reads
  the media from (`SourcePlan`): your server's file (`/m`), a link
  everyone opens (`DirectLink`; a page is resolved here), another
  member's relay or the server's fetch (`/r`, `waiting` until it is fed:
  `relayWaitsForSource`), its own file or link (it plays its own copy and
  feeds the relay), a Jellyfin item (`JellyfinSource`: own account, the
  server's login `/j`, the member passing it on `/r`), or `Unresolvable`
  (a page on a device that cannot resolve: `LinkResolver.resolvesLinks`
  false; who can is read from `members[].caps.resolve`; desktop always
  can, so this is Android's plug-in point).
- Resolve: a Jellyfin item through this app's account (or the plan
  resolved ahead for Up next, `warmJellyfin`), else the server's login,
  else the member passing it on, else blocked (`openJellyfin`); a link
  this member passes on through its shared reader's loopback URL ("Read
  once" under "Relay"); a web page through the app's own yt-dlp (`LinkResolver.probe`: yt-dlp's
  stream URLs, an EDL of video and audio, the CDN's headers with its
  cookies, the subtitles; see "yt-dlp"), failing in plain words with the
  cookies that were used (`ResolveFailure`, D11); a relay not fed yet is
  opened once `relay.live`.
- Open: a player per media through the host. The prepared player
  (Up next's, see "Getting ready") is promoted when it holds the same URL
  and headers; else, when the session player already held media, a fresh
  one takes over (pins, volume, shaders; with the view up and the render
  mode known, its video output ready before the view swaps to it, else
  the view makes it and the probe runs on it); the same media again (a
  reconnect, joining back) keeps the player. Every hand-over is
  `PlaybackController.attach`: log, marks and track observers move over,
  the view swaps to the new output (`generation`), volume and shaders
  carry over, the old player is retired. The first open after join or
  Reload video uses the player just created; a dropped connection never
  touches the player. "Reload video" (button or Ctrl+R) retires the
  player, starts a fresh one and opens the media again (a page resolved
  afresh: its stream URLs may have expired). Cost (`SwitchTrace` `player`,
  headless, without the video output): 45 to 65 ms per swap for one app
  in the process, about 150 ms with three in one process
  (`queue_switch_e2e_test` with `WT_SWITCH_PRELOAD=0`), against a cold
  switch of about 1.6 s.
- Ready: the coordinator reports at once after an open (`onOpened`) and
  when the buffer reaches the gate's need while held, not on the next
  tick.
- Commands: play/pause/seek/rate come only from `StateDiff` actions, the
  play gate (`localPlayAllowed`: self in-set and ready) or the user's
  own seeks (see Sync model); a server seek within 0.5 s of the current
  position is skipped. They go through `PlaybackController.apply`: while
  a switch is under way (no player, or its media has no duration yet)
  they wait, the latest seek, transport and rate apply once to the new
  player when its media is in; mpv never gets a seek it cannot run
  (media_kit logged "error running command seek" / `event:5` for each).
  The volume is the controller's (`setVolume`), on every next player.
  Opens are paused (`play: false`). On media change (`mediaId` bump) the
  previous media stops at once (no old picture or sound while the new
  one resolves, is fetched or opens) and `StateDiff` seeks to 0, holds
  and resets rate. Leaving stops and releases the players.
- Being a relay source (`RelayFeeder`, `session/relay_feeder.dart`): the
  current media's channel and Up next's warm relay (see "Relay"), with
  the step-1 re-dial (a source rides through this app's own drop). A
  link it passes on is read once for its player and the relay
  (`SharedLinks`, `session/shared_links.dart`; "Read once" under
  "Relay"): the swap check's reader, else Up next's warm one, else a new
  one; it lives while the media does (a sit-out keeps it for the relay). A
  Jellyfin item this member put up is passed on only once someone
  present needs it (`jellyfinRelayNeeded`: the server's login does not
  cover it and a present member does not play that server with its own
  account; one whose `caps` say Jellyfin but whose `jf` is not reported
  yet is asked again with the next state), so a session where everyone
  has an account opens no relay channel.
- Viewer recovery (D6): while the relay this app reads has no source
  (`sourceGone`, or not live with the source away), it plays what is
  buffered. A seek past that (a server seek, a drift correction) is
  tried once; more wait, the seek check does not re-apply, and the
  report says nothing is buffered once this player cannot be where the
  server is (`starved`), so the server holds everyone with the reason
  `source` ("Waiting for Bob"; see "App events and platform ports").
  When the source is back, one seek to the server position resumes the
  player, and a player that never loaded meanwhile (it opened while the
  source was gone and its first bytes never came) opens again in a fresh
  player. Measured (`relay_e2e`, a source just above the bitrate that
  drops, a seek past what the server got, a member joining meanwhile):
  at most one seek per viewer while it is gone, nobody's player broken,
  all play from the seek once it is back.
  A read that waits on bytes nobody sends for longer than ffmpeg's
  reconnects (`stream-lavf-o` above: 4 tries per read, about 40 s with
  the 4 s header rule;
  measured with mpv 0.41 / ffmpeg 9.0.2) fails, and mpv takes that for
  the end of the file. The player stopping more than 3 s
  (`finishSlackSecs`) short of its duration says so
  (`PlaybackController.onEndedShort`; the bar then shows where it
  stopped, not full): a relay viewer whose server has not finished and
  is more than 10 s from the end (`shortEndOf`, `shortEndMarginSecs`)
  is reopened in a fresh player at the server's position ("Reload
  video"), at once when the relay has its source, else once it is back;
  at most 3 times per media. A longer reconnect budget for relay URLs
  was the other way: it only moves the limit (the source may be away
  for its whole grace), and a long `reconnect_delay_max` leaves ffmpeg
  asleep for that long after the bytes are there again.

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
- +1:30 (`skipForward`: the pill, ⋯ → Skip 1:30,
  Shift+Right) is a `nudge`, so repeated presses add up.
- Chapter steps (`chapterStepTarget`; PgUp forward, PgDn back, mpv's
  default keys): forward to the next start; back to the current start,
  or the previous one within 5 s of it (mpv's `chapter-seek-threshold`).
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
(`packages/server/lib/src/jellyfin_relay.dart`). The server holds its
logins as `JellyfinCredential`s (`ServerHub.jellyfinLogins`, at most one
per Jellyfin `serverId`; each: `baseUrl`, `serverId`, `token`, `client`,
`device`, `deviceId`, `version`; primitives, so they cross the isolate
boundary). The app sends one per linked account (not known expired, the
default first) when your server is shared (`share`): its own
app-obtained tokens and their device fields; the dedicated server has one,
read from `--jellyfin <file>` (YAML/JSON with those keys, keeps the
token off the command line) or a `jellyfin:` map in `--config`. An empty
`serverId` is looked up at start (`/System/Info/Public`); if that fails
that login stays unused. Tokens are never logged (`toString` and config
parse errors leave them out).

- Available (`state.relay`) only while the current media is a ref on a
  server one of the logins is for (`loginFor(serverId)`, which `/j` then
  uses); `state.relayNext` likewise for Up
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
| File, on your own server | `/m` from your server (no relay) |
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
path (sync, swap, reopen) as is. The source member's own player reads
the same tracks through its shared reader ("Read once" below).

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
- **Read once** (a link passed on: `SharedSource`,
  `packages/server/lib/src/shared_source.dart`, kept by the app's
  `SharedLinks`): the source reads each track from the site once. Per
  track a `RelayBuffer` on the source (64 MiB ahead and 16 MiB behind
  for all tracks, split by size like the server's, plus the pins:
  `sharedAheadBytes` / `sharedBackBytes`), filled by one sequential
  upstream reader, serves two readers: the source's own player, through
  a loopback endpoint (`http://127.0.0.1:<port>/<random secret>/<track>`,
  an mpv EDL for several tracks, no headers: the site's stay in the
  reader) answered with the server's own byte-answer code
  (`writeRelayRange`, below: headers within 4 s, `connection: close`),
  and the server's pulls (`SharedSource.upload`, served by the usual
  `RelaySource`). The player opens at once; the endpoint waits for the
  tracks' sizes. The two readers are kept within one window
  (`RelayBuffer.together`): while both have a request open, the one more
  than the track's `ahead` past the other waits without asking upstream,
  so one sequential read serves both instead of handing over at every
  slice. The server's read-ahead thus stops about 64 MiB past the
  source's player, and a source whose upload lags holds its own player
  there (viewers would wait at that point anyway); either reader alone
  reads freely, pinned slices always come. A seek (shared, so both
  readers go together) is a new upstream read there, as on the server.
  Upstream (`ResumingBytes`): a cut resumes from the byte it reached
  after 100 ms; an answer without a byte (412, 429, 5xx, a refused or
  dead connection, nothing for 20 s) backs off 0.5 s doubling to 8 s;
  60 s without a byte fails the read, and the buffer's own backoff asks
  again. 403/410/412 first resolve the page again (see "yt-dlp"). The
  source's player plays the relay's tracks, so the source and the
  viewers watch one format, and the reader sends the headers and cookies
  yt-dlp gave for it. The putter's swap check is this reader (its sizes
  are the media's: no second read); an Up next link passed on feeds its
  warm relay from its own reader, the preload player reads its loopback
  URL (one prepared on the site before the reader existed is prepared
  again), and the swap carries both on. Reload video opens the loopback
  URL again (the reader resolves an expired page itself). Not read once:
  a page with a pieces track (HLS/DASH, X's): its player plays yt-dlp's
  pick from the site and the relay reads the pieces itself, two fetches;
  a file passed on (disk) and a Jellyfin item (see "Media pipeline")
  keep their own paths. Measured (server `single_fetch_e2e`, opt-in: a
  real server and `RelaySource`, mpv 0.41 with the app's pins on
  loopback, a fake CDN with Bilibili's Referer rule and two tracks:
  60 s of 720p h264 at 4 Mbit/s and 128 kbit/s aac; 20 s of play, then
  a seek to 45 s and back to 5 s):

  | CDN / source | First frame: source, viewer | Viewer stalls | Viewer seek to 45 s | CDN requests (player + relay) | CDN MiB | 412s |
  |---|---|---|---|---|---|---|
  | clean, two fetches | 0.22 s, 0.46 s | 0 | 0.27 s | 8 (2 + 6) | 51.8 | 0 |
  | clean, read once | 0.27 s, 0.33 s | 0 | 0.29 s | 6 (0 + 6) | 25.9 | 0 |
  | cuts every 0 to 2 MiB, two fetches | 0.22 s, 0.38 s | 1 | 0.27 s | 64 (28 + 36) | 55.9 | 0 |
  | cuts, read once (29 resumes) | 0.22 s, 0.27 s | 0 | 0.27 s | 33 (0 + 33) | 25.9 | 0 |
  | cuts + 412 lockout (> 40 requests in 10 s), two fetches | 0.21 s, 0.39 s | 1 | 4.03 s | 49 (23 + 26) | 35.3 | 6 |
  | cuts + lockout, read once | 0.26 s, 0.33 s | 0 | 0.29 s | 33 (0 + 33) | 25.9 | 0 |
  | 768 KiB/s per connection, two fetches | 0.40 s, 0.59 s | 1 | 0.80 s | 12 (5 + 7) | 34.0 | 0 |
  | 768 KiB/s, read once | 0.40 s, 0.47 s | 1 | 0.76 s | 7 (0 + 7) | 16.9 | 0 |

  The source's own seeks took about what the viewer's did; back to 5 s
  took 0.25 to 0.29 s everywhere. The source's player stalled only on
  the slow CDN (once, in both modes).
- Upstream GETs (`HttpRelayBytes.read`) are split into back-to-back
  ranges of at most yt-dlp's `http_chunk_size` for the format, else
  10 MiB (`relayUpstreamChunkBytes`); a buffer pull stays one read.
  YouTube serves a range up to 10 MiB at full speed but throttles a longer
  or open-ended one to about twice the bitrate (measured 0.8 MB/s against
  8.6 to 12.5 MB/s); chunked, a 1080p relay seeks in under 0.8 s (4 to
  6.6 s unchunked) and even beats mpv reading YouTube directly, since the
  buffer reads ahead at full speed.
- The server keeps one buffer per track of a relayed media (one for a
  file), a `RelayBuffer` for bytes: 256 KiB slices in
  memory (`relaySliceBytes`), filled by one sequential pull at a time. Kept: the first and
  last 2 MiB (container indexes; mpv reads both on open and on seeks),
  64 MiB behind the slowest viewer and 256 MiB past the furthest, the
  same as each viewer's mpv buffer (the player host's pins), so a skip
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
  A failed pull is retried with backoff, as for bytes. Measured (mpv 0.41 through the
  dedicated server, loopback, ~30 MB/s upstream): Mux's TS HLS (1080p,
  one muxed playlist) opened in 0.8 s, seeks 0.07 to 1.1 s; Akamai's DASH
  (1080p + aac, two playlists, EDL) 1.3 s, seeks 0.03 to 1.4 s; an X
  video's HLS video + audio 0.3 to 0.75 s, seeks 0.03 to 0.4 s; A/V sync
  within 0.2 ms after every seek; a second viewer of the same pieces
  opened in 0.02 s from the buffer.
- Filling a byte buffer: a viewer blocked on a slice first (oldest wait
  first, handing the source over at slice boundaries), then the pinned
  slices, then read-ahead from the slowest viewer. A failed pull (the
  source's upstream dropping, a CDN refusing) is followed by the next
  one after 250 ms, doubling up to 8 s (`relayRetryDelay`), back to none
  once a slice or a pull completes: a failing CDN is not asked again
  every round trip (that drew Bilibili's 412/403). Read-ahead never
  fetches the slice that would be evicted next, and a long pull evicts
  as its slices come, so a buffer stays within its budget. A viewer reads the
  slice being filled as its bytes arrive, not once it is whole (mpv's
  demuxer, blocked in a read, takes a seek only once that read returns).
  Nothing is fetched while nobody watches through the relay (a Jellyfin
  source with only account holders uploads nothing).
- mpv leaves superseded requests open but unread after a seek: only a
  viewer's newest request moves its position or asks the source for
  anything; older ones still get bytes that are already buffered, and a
  request a newer one superseded stops holding the pull at once, so a
  seek's pull starts without waiting for the old slice to finish.
  Measured (`relay_e2e` "a seek past what a slow source has sent", a
  source at about 3x a 3 Mbit/s mp4, the gate's 4 s of buffer): a seek
  into what the source has not sent plays there after 2.8 to 2.9 s (4.0
  to 4.3 s with 1 MiB slices served whole and the superseded request
  holding the pull).
- Flow control on the source (`RelayWindow`): one in-flight budget per
  connection, 2 x delivery rate x min RTT (rate max-filtered over 2 s),
  clamped 256 KiB to 8 MiB; the server acks bytes as they arrive. A
  cancelled pull's unacked bytes are written off, and a cancel that lands
  while a frame is being read stops it before it is sent.
- Cleanup: the buffer is memory only. Any swap disposes it (its URLs then
  404, the source is closed with 4001 and stops), and so does server
  stop. A crash frees it with the process.
- Warm relay (`ServerHub.syncWarm`, run on every change; wire in
  [PROTOCOL.md](PROTOCOL.md) "Relay"): a second, small `ActiveRelay` for
  Up next's first item while it waits, keyed by its queue id, so viewers
  preload it (see "Getting ready" under "Up next"). A server-fetched
  link starts its fetch then; a link passed on or a file is fed by its
  adder's app (a second channel, `/r/.../source?q=<queueId>`), only
  while someone else is in the server and not for the host's own file;
  a Jellyfin item someone present cannot play (and the server's login
  does not cover) by the first member with an account that dials in.
  Its budget is 32 MiB ahead and 8 MiB behind its viewers
  (`relayWarmAheadBytes`, split by track size with the usual 8 MiB
  floor) plus the pins: about what a preload player reads, so the
  server holds at most that much on top of the current relay (there is
  no global relay budget; each relay is bounded by its own). Like any
  buffer it pulls nothing while nobody preloads. The swap that puts the
  item up (`swap.queueId`, from its source, or anyone for a fetch, with
  the same tracks) promotes it (`ServerHub.takeWarm`): the same buffer,
  feed and source channel become the media's relay with the full
  budget, `media.relay.queueId` names the item and the media keeps the
  item's name, so its `/r/.../<queueId>/...` URLs (and the preloads of
  them) stay valid. Any other swap of it, the item no longer first (a
  removal, a reorder, Play now of another), its adder leaving, or server
  stop drops it (its URLs 404, its source gets 4001); a restart starts
  with none. A manual swap to something else keeps it (the item is
  still first). A failed warm fetch is not promoted: the swap fetches
  again and reports the reason. The feeding app ends such a source with
  its item too, also when the 4001 was lost in a drop of its own
  (`RelayFeeder.onState`, every state: the item neither Up next's first
  nor the media's `relay.queueId` stops it), and asks before each
  re-dial (`RelaySource.beforeRedial`): the next state, after a
  reconnect the first one back, says whether the item is still on, so
  it does not dial an item already played.
- Before the source's channel is first up, a viewer request gets no
  answer (the server cannot send headers before it knows the size), and
  media_kit's mpv gives up on a silent request after 5 s
  (`network-timeout`) with "could not be opened". So viewers open a
  member relay's `/r/` URL only once `relay.live` is set, as for a
  server fetch (`relayWaitsForSource` in the media plan; "waiting for
  <name> to pass the video on…" meanwhile), unless the source already
  left (then they open what the server has); Up next preloads wait the
  same way. The putter starts
  its source before opening its own player, and the source reads its
  tracks' sizes at once.
- Source away (D6): viewers keep playing from the buffer; a request
  waits up to 60 s for missing bytes.
- A viewer's byte answer is written on the raw connection (relic
  `Hijack`, `_rangeResponse`): its headers go out with the first bytes,
  or after 4 s without them (`relayHeaderWaitMs`). ffmpeg gives up on a
  request whose headers do not come within mpv's 5 s `network-timeout`
  and then has lost the file's size for good (8.x and 9.0 do not restore
  it): every later seek fails with "Seek failed (to N, size -38)". With
  the headers in time, a stalled read only times out and is reconnected
  (`reconnect_*`, see "Media pipeline"), and plays on once the bytes come.
  The answer always says `connection: close` and closes after its body:
  ffmpeg asks for close, and ffmpeg 8.x, not told so, sends its next seek
  on the connection after reading a range to its end (an mp4 with a box
  after `mdat`, like X's clips: the 58-byte tail, then back to the
  start) and fails it the same way. Other answers say so too when asked
  (`closeWhenAsked`, every server route). A swap that ends the relay
  closes its viewers' answers plainly (`RelayEnded`, not logged as a
  broken read). The source member going `gone`
  does not end the relay: it lives through the source's grace
  (`media.relay.sourceGone`, `ServerHub.refreshRelaySource`). The source
  (`RelaySource`, kept by the media pipeline's `RelayFeeder` through the
  app's own drop) reconnects its channel with backoff (its token lasts
  through the grace; a half-open channel is caught by its 5 s WebSocket
  ping) and sends its `info` again, the same on every dial (the feeder
  passes the media's `name` and `duration`): the same as its first (sizes, piece
  shapes, kinds, and name and duration when given) carries on, the
  buffer filler pulling what is missing; another one is closed with
  4002 and ends the relay (`ServerHub.relayOtherMedia`); a second channel
  replaces the first (4003). The source's leave (grace over, `bye`) or a
  swap ends the relay: its buffer goes, `live` drops, `/r` answers 404.
  `state.media.relay.live` follows the channel. Viewers' status (see
  "App events and platform ports") says "Waiting for <name> to pass the
  video on" while it is down, "<name>'s connection dropped — playing what
  the server has (2 min)" while the source is `gone` (from `sourceGoneSince`;
  a viewer opening then opens the buffer instead of waiting) and "<name>
  left — playing what the server has" once it left the server; the source
  gone for 5 s (`sourceDropNotice`) or leaving is also a toast, once each.
  A viewer's buffer running dry holds everyone (`state.hold.reason`
  `source`: "Waiting for <name>"); the viewer's side, never seeking past
  what it has and resuming when the source is back, is "Viewer recovery"
  under "Media pipeline".
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
  status carries it (`Status.delivery`) and the members card
  (`shell/delivery_line.dart`) shows it as a source line and a dot per
  member; nothing goes on the picture. The source gets one toast
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
  it. `version`, `lastError`, `busy` and `changes` feed Settings →
  Library & accounts → Web links ("Update now" forces the check). Every
  failure is non-fatal.
  Folders: the app's is `<app support>/yt-dlp` (`AppYtDlp`, warmed up at
  start), shared with your server; the dedicated server's is
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
  own drop target is off on Settings so only this box takes the file); your server shares the folder,
  so it uses them too. A player gets them through the app's resolve
  (the format's cookies as its Cookie header), never on its own. The dedicated
  server: `--yt-dlp-cookies <file>` / `ytDlpCookies` converted into its
  folder at start; without it the copy and browser setting are removed.
  Values are never logged and never leave the machine.
  A resolve that fails in a way that may be about signing in (cookies,
  log in, "No video formats found") says which cookies it used (D11,
  `YtDlp.cookieNote`, `YtDlpException.cookies`, `LinkProbe.cookies`,
  `withCookieNote`): none; the file and how many of its cookies are for
  the site (`cookieSite`); a browser and how many cookies for the site
  yt-dlp reads from it (one run without a URL, `--cookies-from-browser
  <spec> --cookies <private file>`, which writes the browser's jar to a
  0600 file in the yt-dlp folder, counted and deleted at once), or that
  it could not read them. "No video found: it may need signing in (used
  Firefox's cookies, which have none for bilibili.com: sign in to
  bilibili.com there)".
- **Resolve** (`YtDlp.resolve`, `resolveArgs`): `yt-dlp -J --no-playlist --no-warnings
  --ignore-config -f bv*[height<=1080]+ba/b --write-subs --sub-langs
  all,-danmaku` plus the cookies, 25 s timeout: title, uploader, duration,
  thumbnail, live or not; what a player opens (`YtDlpPlay`: yt-dlp's
  `requested_formats`, else the top-level format; http(s), HLS, or a DASH
  manifest; one URL, or an mpv EDL of the video and the audio; the first
  format's `http_headers` plus its `cookies` as a Cookie header; the
  requested subtitles but Bilibili's danmaku, an XML comment feed); and
  what a relay reads (`pickTracks`), each format with its URL,
  `http_headers` plus its `cookies` as a Cookie header (what a player
  sends) and `http_chunk_size`. For a relay only plain http(s)
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
  Link preview (kept on disk too; see "Tabs" under Desktop UI) and the swap: a page is named by its title, never its URL
  tail, and its thumbnail goes up as its art (see "Media art"). A link with a
  problem, or one the probe cannot reach ("Couldn't reach the site"), is
  not put up in any mode: the Link page shows the reason (preview and
  under the button) and offers "Put it up anyway" (`LinkMedia.anyway`),
  for when the server or a friend with cookies may still open it;
  `swapLink` refuses it the same way for any other caller.
- **Everyone fetches it**: the swap sends the page URL. Every app
  resolves it with its own yt-dlp (the media pipeline's resolve step,
  `LinkResolver.probe`, waiting for the download on first use). A page
  whose relay tracks are plain files (`SharedLinks.fits`) plays through
  a reader of this app's own, as alone with no relay
  (`SharedLinks.local`: a `SharedSource` without the upload, "Read once"
  under "Relay"): its tracks with yt-dlp's headers and cookies, resumed
  after a cut, backed off on 412/429/5xx, the page resolved again on
  403/410/412, so a CDN cutting a long read (Bilibili: "Stream ends
  prematurely", then a refused reconnect that ffmpeg treats as fatal)
  never reaches the player. The reader is opened with its sizes (15 s);
  one that cannot (a refusal, a pieces track, a live stream) leaves the
  player on what yt-dlp picked (`YtDlpPlay.mpvUrl`) with its headers as mpv's
  `http-header-fields` (media_kit's `Media.httpHeaders`), for every
  track of the EDL: Bilibili's CDN answers 403 without the Referer. The
  session player's and the preload's readers stay, any other closes
  (`trimLocal`); Reload video makes a new one. Its
  subtitles are added once the media is in (`sub-add <url> auto`). mpv's
  own Lua yt-dlp hook is off (`ytdl=no`): one resolve path for every mode,
  cookies and headers always the app's, and a libmpv without Lua plays
  links the same. A resolve that fails is a player error in plain words,
  with the cookies it used. Stream URLs are bound to the resolving
  machine, so each app resolves its own; a page is resolved again at
  Reload video and for Up next's 30-minute refresh (they expire).
- **Through me**: the putter's probe must give tracks, and a pieces
  track's playlist must be readable, else the swap is refused ("Live
  streams can't be passed on", DRM, or nothing a relay can read) with a
  hint to use "Everyone fetches it". The swap names the tracks; its relay
  source reads them with yt-dlp's headers and cookies (`PageRelayMedia`),
  and the putter's own player plays those same tracks through the one
  reader ("Read once" under "Relay"), not yt-dlp's `requested_formats`:
  the putter sees the relay's pick (HEVC first) like the viewers. On
  403/410/412 (expired format URLs, 6 h on YouTube; signed segment URLs;
  Bilibili's 412) from any track it resolves the page again once for all
  tracks (not again within 60 s: a further refusal fails the read and is
  backed off), finds the same
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
  the video…" until then; see "Relay" for why).

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
  opens Settings → Library & accounts over the session; linking (or reconnecting) the
  account retries by itself. A 401 marks the account expired. The member
  list shows "via server" for members whose `jf` is false for the current
  item (see "Relay", Stats). A reconnect to the same item with `OwnPlay` keeps playing as is.
- **Progress** (`JellyfinProgressReporter`, `OwnPlay` only): Playing once the
  file is open and mpv has picked its tracks; Progress every 10 s and at
  once on pause, resume, a seek (position more than 3 s from where playback
  should be) or a track change; Stopped on swap, leave, sitting out, window close
  (bounded to 1.5 s inside the graceful leave) and at `finished`; seeking
  back from the end sends Playing again. Reports carry `PositionTicks`
  (see "Watched on Jellyfin"), `IsPaused` and mpv's `aid`/`sid` as Jellyfin
  stream indices (`jellyfinIndexForMpvTrack`, `SubtitleStreamIndex -1` =
  off). They go out in order on one chain; failures are logged, one quiet
  toast per session, playback is never touched; a 401 marks the account
  expired and ends reporting.
- **Watched on Jellyfin**: the watch of the item is the session's (see
  "Watch tracking"); `JellyfinProgressReporter` reads its verdict and
  never samples itself. Jellyfin decides played from
  positions alone (10.11): Playing sets a resumable item unplayed, a
  Progress or Stopped position past "max resume" (90 %) marks it played,
  one in between keeps a resume point. So the reporter
  (played before = `UserData.Played` read at open with
  `/UserItems/{id}/UserData`, handed to the watch with the resume point):
  - played (before, or by the rule at an earlier stop of this opening):
    `UserPlayedItems` right after Playing, Progress without
    `PositionTicks` (leaves the saved position and played state), Stopped
    without `PositionTicks` (Jellyfin marks it played), then
    `UserPlayedItems` again and the resume point cleared
    (`/UserItems/{id}/UserData` `PlaybackPositionTicks: 0`): a position an
    earlier Progress left would otherwise keep it in Continue;
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
  (also `<` `>`, Shift+P / Shift+N; next is Up next's first item when
  there is one); from `nextPromptStart` (the ending's
  start when one is known, see "Skip rules", else the last 2 min of the
  runtime) a floating "Next episode" pill shows while the controls are up
  (see "Player controls"). Any of them puts that episode up with the
  clicker's account (through Up next when it is the continuation there).
  At the end, the next episode continues the item by itself (see "What's
  next"). Guests (relay, blocked) see none of it.
- **Tracks**: the controls' Audio and Subtitles buttons (or ⋯ when
  hidden from the bar) list `PlaybackController.tracks`. A pick is applied, reported, and saved as a `TrackChoice`
  (language, title, codec, channels, forced/HI: from the Jellyfin streams
  with `OwnPlay`, else from mpv's track list) per series and as the global
  fallback in the `track_prefs` Hive box. On the next Jellyfin item it is
  matched with `matchTrack` against the source's streams (mapped to mpv ids
  with `mpvTrackId`) or mpv's track list, and selected locally. Nothing goes
  on the wire.
- **Change video**: the player's ⋯ → Change video opens the Library tab;
  Link goes through `mediaForLink`, a Jellyfin pick as a ref, a file
  through `ServerIsolate.setFile` (host) or the relay (`swapFile`).

## What's next

One system decides which item plays next and when, and has it prepared
ahead. The server holds the decision (`SyncEngine.whatsNext`, on every
tick and queue change; wire in [PROTOCOL.md](PROTOCOL.md), "Queue"); each
app's `QueueController` (`lib/src/queue/`) adds to the one list, puts an
item up when the server asks it, shows the countdown and keeps the next
item ready ("Getting ready" under "Up next").

- **One list**: the queue, Up next's items, then at most one `auto`
  item, the continuation of the media playing (`for` its `mediaId`).
  Everyone sees it; any swap that does not put it up drops it.
- **The continuation**: added by the app that put the media up (or, when
  that member is not `in`, the first member who is: core's
  `mayAddContinuation`), when it knows what comes next and the setting
  "Play the next episode automatically" is on there: a Jellyfin episode
  played with its own account continues with the series' next one
  (`adjacentEpisodes`), a file this app put up with the next episode of
  its show (`LocalNextFinder`: the library the Files page saw this run,
  else the file's own folder scanned and grouped; `LocalShow.nextAfter`,
  so the numbers skipped on the way are said in its second line, "skips
  66–107"). It goes up like any item of its kind (a Jellyfin ref, the
  adder's file), with a picture, and adds no feed line. A `cancel`
  (Clear, or Cancel on the end card) drops it for everyone, and no app
  adds it again for that media (the feed's `advance-cancel`).
- **When**: with nothing up, the first item is asked for at once. When
  the media finishes with an item first, the server's countdown starts
  (`state.advance`, 10 s, the same on every screen); a new first item
  takes it over with the same end; a seek, `cancel` (shared) or a swap
  ends it. At its end the server sets `queuePlay` and the app that puts
  the item up (`queuePerformer`) swaps it in. It holds while that member
  is `gone` (in its grace) or nobody is around, or while the item's warm
  relay waits for a `gone` source, and asks once they are back. An item
  asked for that nobody here can put up (its adder left, nobody has its
  Jellyfin server) is skipped by the server (feed `queue-skip`, actor
  `server`), and the countdown goes on with the next one.

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
- **Who puts an item up** (core's `queuePerformer`, from `state` alone,
  so the server and every app agree): a link passed on or a file, only its adder (`gone`:
  the item waits for it through its grace; left for good: skipped, "Bob
  left"); a Jellyfin item, its adder when it plays that server with its
  own account, else the lowest present member id that does (`jf`, which
  lists every working account; nobody: skipped); a link everyone opens
  or the server fetches, its adder when present, else the lowest present
  member id (present: `in` or `joining`, `isPresentMember`). An item asked
  for that nobody can put up is skipped by the server (see "What's
  next"); an item whose swap fails is taken off by the app that tried,
  with the reason; the feed's `queue-skip` toasts on every screen.
- **Advancing**: at `finished` with something next, every screen shows
  `UpNextCard` (picture, title, who added it and how; the server's
  countdown with Cancel while `state.advance` runs, "Waiting for Bob"
  when it ran out without the one who puts it up, else Play now only;
  see "What's next"). The app that puts the item up does when the server
  asks (`state.queuePlay`), with a swap naming it (`swap.queueId`), so
  the server takes it off in the same step and a second swap of it is
  ignored. "Play now" anywhere (a row, the card, the Up next button's ⏭,
  `>` / Shift+N) swaps directly from the app that can, else sends `play`
  and that app reacts to `state.queuePlay`. With nothing up at all, the
  server asks for the first item as soon as it is added. The swap goes through the usual paths
  (`swapPicked`, `swapJellyfin`; a server-fetched item through
  `swapQueued`, without the URL, its picture as the art), so relays, art
  and refusals work as for any swap; when it fails the item is skipped
  with the reason. A swap without `queueId` (a manual one) leaves the
  queue alone. A member who puts its own link or file up while sitting
  out comes back first; any other queued swap leaves the swapper out.
- **Getting ready** (`QueueController._warm`): every app keeps the one
  item that plays next ready all the time, its own copy, so a skip, Play
  now or the end of the media starts it at once. That is the queue's
  first item (Up next's, else the continuation, which is in the queue
  for everyone); while sitting out only the probe
  of a link this app puts up (its swap reads it). Per
  kind: a Jellyfin item is resolved with this app's account
  (`resolveJellyfinRef`: PlaybackInfo and the item) into
  `SessionCoordinator.warmJellyfin`, which the media pipeline's resolve
  (`openJellyfin`) takes instead of asking again when the same ref goes
  up within 35 minutes and the
  account is unchanged; without an account it is the server's `/j` URL
  when `state.relayNext` says the server's login passes it on (see
  "Jellyfin relay"). A link everyone opens is that link; the app that
  puts it up also probes it (`AppYtDlp.probe` with `keep`: kept 35
  minutes instead of 10, a refresh replaces it only once it is in; swaps
  read it from there). A link passed on "through me" and a file on
  their adder's app (the link, the path; not the host's own file, which
  plays from `/m`), which also feeds the server's warm relay of it
  (`QueueController._feedWarm`, `RelayFeeder.feedWarm`; a
  Jellyfin item's from the member who puts it up, with its resolved
  stream, when the server asks for one); everyone else, and everyone
  for a server-fetched link, preloads that warm relay's URL
  (`MediaPipeline.warmRelayUrl`) once `queue[0].media.relay.live`
  says bytes can flow (see "Relay"). At the swap the adder's app skips
  re-reading the link's sizes (its warm source has them) and that
  source carries on as the media's. It
  is resolved as soon as it is first there, again every 30 minutes, and
  dropped when it stops being first.
  **Preload**: once resolved, the stream is opened early by the media
  pipeline (`MediaPipeline.prepare`, a page through the same resolve as
  any open) in a second, hidden player (the host's `preload` role):
  paused at the start, muted, with its own video output when the
  session view is up (media_kit starts a player with `vid=no`; the
  output decodes the first frame), the same pins and hwdec as the
  session player but a 48 MiB forward and 8 MiB back cache
  (`preloadAheadBytes`), mpv log at `error`. One at a time; it waits
  until the media playing has started here
  (`MediaPipeline.settledMediaId`: opened, failed or nothing to
  open), so it never competes with that open and a preload a swap is
  about to take is never replaced first; a removed, reordered or replaced
  first item swaps or drops it then, a manual swap to something else
  keeps it (still next). A link is opened again at the 30-minute refresh
  (stream URLs expire); a failed preload is not retried until then and
  changes nothing (the usual open follows). When the pipeline opens the
  same URL and headers, the preload is promoted instead of a fresh
  player: it becomes the session player through the same hand-over (see
  "Media pipeline" under "Media"), unmuted and with the full cache pins
  (`PlayerHost.promote`), its subtitles added. Its buffer comes along,
  so the report sent right after the open already passes the gate: the
  start no longer waits for anyone's open. A promoted player is no
  longer the first mpv of the process, so ffmpeg's HTTP status reaches
  it only when it happens to be the instance ffmpeg logs through (load
  errors themselves are still detected; see "Media"). Off with env
  `SYNC_RELAY_PRELOAD=0`. Measured (`queue_switch_e2e_test`, a fake
  Jellyfin and link host answering after 120 ms at 24 Mbit/s, two
  account holders and a `/j` guest): ⏭ to the server playing 74 to
  87 ms for the next episode and 35 ms for a direct link, against about
  1.6 to 1.8 s cold; at 300 ms and 12 Mbit/s 52 and 103 ms against about
  2.9 s. Relayed, from the warm relay (same setup, loopback server): a
  link passed on 36 to 38 ms, a server-fetched link 46 to 53 ms, against
  about 1.6 s cold.
  `SwitchTrace` (env `SYNC_RELAY_TRACE_SWITCH=1` prints it) times each
  phase of a media change: state, resolved, open, player (a fresh
  player is up; see "Media pipeline" under "Media"), opened or
  preloaded, buffered, playing.
  The row of the item shows a dot on its picture's corner (a tooltip
  says which): hollow waiting, pulsing getting ready (resolving, then
  preloading its first 4 s), filled ready, red failed (tried again every
  2 minutes).
- **Continues with**: the continuation (the `auto` item, see "What's
  next"), greyed under Up next for everyone, ▶ plays it now; "Clear"
  drops it for everyone (`cancel`). Under it, on an app playing a
  Jellyfin episode with its own account, the series' further episodes
  (`/Shows/{id}/Episodes`, cached), "+" adds one to Up next.
- **UI**: `UpNextButton` is one of the player's top-bar controls, before
  the window controls (see "Player overlay" under Desktop UI), in the look
  of the skin's buttons (`UpNextLook`); it shows and hides with the controls,
  which an open popover holds up: the first item's picture (`QueueThumb`,
  the rows' faint box and icon until it arrives), "UP NEXT" over its
  title, a +n count, ⏭ plays it now; without Up next the continuation
  (its picture, "NEXT · S1E8" (its second line) over its name, ⏭ plays
  it); nothing when both are empty. Resting on it 600 ms (popover closed)
  shows `UpNextPreview` under it, right edges aligned, in `AppGlass`:
  the picture large, title, second line, "length · added by (avatar)
  name · how" (an episode: series, length, overview), how ready it is
  here (the row's dot and words, else who puts it up) and the `>` key;
  it stays while the mouse is on either, holds the controls up
  (`ControlsHold`) while shown, and a click on it opens the queue. Its
  title opens the queue as a
  `LeafPopover` (package `leaf_widgets`, a git dependency like `fox_utils`;
  an overlay rather than a route)
  hanging under it, right edges aligned: the app's glass (`AppGlass`),
  the menus' paddings and row hover, 64 px rows with an 80 px 16:9
  picture, title, second line, "length · added by (avatar) name · how", a drag handle
  (`ReorderableListView`, reordered here at once and sent as `move`), ▶
  and × floating in on hover, right-click for Play now, Remove, Copy
  title, and Copy link / Open in browser only for a link known here
  (`QueueController.linkOf`: a link everyone opens, or one passed on by
  this app, which only its adder has; never a server-fetched link or
  another member's) and Open in Jellyfin for an item of a server linked
  here; "Continues with". The panel itself holds focus on open, inside a
  `KeyboardClaim` (`widgets/text_focus.dart`: focus under it counts as a
  text field's, so the player's keys and Space rest while it is up; Esc
  closes). Ctrl+V there adds the clipboard's video files, else the links
  in its text, at once (an ordinary paste while typing in the field); "+ Add
  link" opens a small field (Enter adds, Esc closes it); links and video
  files can be dropped on it. Each addition is a row of its own under
  the items: the link's title and thumbnail as soon as they are known
  (`cachedLinkPreview`: a kept preview at once, else the same probe the
  add runs), "Adding…", then "Added" (gone shortly after, the item itself
  being in the list) or why not (× dismisses). Being no route, it holds
  the shell's own drop and paste handling off while open
  (`handoffHolds`). "Add to queue" elsewhere, on every source: the Link
  page's button next to Put it up (in the chosen mode), a right-click
  `showAppMenu` (Put it up / Add to queue / Play next) on recent links,
  Jellyfin cards (home rows, libraries, search), series episodes and
  details-panel episodes, Files videos and Schedule cards that can be
  put up, a button in the Jellyfin details panel (right-click: play
  next), and Add to queue / Play next on the drop and paste card (videos
  in order, a link in the Link page's mode). All go through
  `QueueController.add`. None of it offline.

## Library

Local videos as shows, device-owned (the three-way truth: library, match
corrections and watch history live on the device). Two layers:

**L1, local identity** (`packages/core/lib/src/library/`, pure and
offline): `parseReleaseName` reads a file name (title, group, season,
episode, year, extras: OP/ED, Opening/Ending, NCOP/NCED, OVA, specials,
PV, Menu, numbered; movies: `Movie N`, `The Movie`, `Gekijouban`, a
title with a year), `parseFolderName` a folder name (title, season and
its name from a parenthetical read before brackets go, `(Season 3 -
Alicization)`, an episode range `001-055`, a season-only or extras
folder). `groupLocal(files, roots:)` keeps the videos (anything else,
`.lnk` shortcuts included, is counted as ignored) and reads each
(`readLocalFile`): the file's own name wins, the folders between it and
its watched folder are hints, nearest first (a bare `01.mkv` takes the
folder's title, a file under `Season 2` its season). Files group into a
`LocalShow` by `normalizeSeries` of their title, across folders (Bleach
in three folders is one show), with `LocalSeason`s as numbered (a null
number is an absolute run, kept as found), extras and the show's movies;
a movie of no show here stands alone, anything else is "other". Each
season knows its holes (`EpisodeGap`: before the first episode, between
episodes, and up to a folder range's end), so `LocalShow.nextAfter(key)`
gives the next episode and the numbers skipped on the way. Keys are
stable across rescans (`show|s<season>|e<n>`, extras and movies alike);
ordering is deterministic (titles, then numbers, then names). The app's
scan (`files/scanner.dart`, `FolderAccess.scan`) only walks and pairs
subtitles; the Files page groups its `LocalFile`s.

**L2, match** (`apps/desktop/lib/src/library/`, `ShowMatcher`, made by
the composition root, cached in the Hive box `library`, `LibraryStore`):
a show's season (by show key, season and season name) is searched once
on AniList (`AniListClient.searchAnime`: titles, synonyms, format,
episodes, art, the SEQUEL / PREQUEL TV entries and episode titles) with
the season's name or "season N" as hints; `scoreMatch` weighs titles and
synonyms (`Re.Zero` finds `Re:ZERO -Starting Life in Another World-`),
the season marker in a name (`4th Season`), the format (TV for episodes,
MOVIE for movies) and AniList's own order; below a threshold nothing is
kept ("none", asked again after 3 days). A season the search misses is
the show's first entry walked along its sequels. Episode numbers
(plus the user's offset) map onto AniList along the run: past an
entry's episode count, its sequel's (a TVDB season AniList splits into
cours, SAO S3 25 = War of Underworld 1), or, when signed in to
AnimeFlow, its `anilist_map` runs for that season (which also give the
TVDB id). Corrections win over everything and survive rescans: a pin of
the show everywhere (`pin:show:<key>`) or of a folder and what is below
it (`pin:folder:<path>`, more specific), and an episode offset per show
and season ("these files are episodes N.."). Requests are lazy (cards
and pages on screen ask, `want`), one at a time, 800 ms apart, paused a
minute after a 429; failures are retried after 5 minutes; everything
answers from the cache offline. Episode and show names, cover and banner
come from the matched entry.

**Media identity** (`media.ref`, [PROTOCOL.md](PROTOCOL.md) "Media
identity"): what a media is, independent of where its bytes come from.
Producers: a local file, `ShowMatcher.refFor` (L1 kind and numbers, the
match's title, AniList entry and episode, the TVDB id from AnimeFlow;
L1 only before a match); a Jellyfin item, `jellyfinMediaRef` (kind,
series title, season and episode, the AniList / Tvdb provider ids of the
show or movie, `ProviderIds` in the item fields; from a pick's lines,
`jellyfinPickRef`, when the item was not at hand); a link,
`linkMediaRef` (its name read as a release name, else a movie of that
title). Swaps (`swapFile`, `swapJellyfin`, `swapLink`) and Up next adds
carry it; Up next names a file item by it. Consumers: receivers' now
playing title and episode line (`refTitle`), the swapper's art (by the
AniList id), the watch tracking's records (see "Watch tracking").

## Watch tracking

What this device watched, by D3: watched means at least as good as
Jellyfin's own, and a peek, skipping around or a screenshot visit never
counts. The truth is split: the device holds its watch history, Jellyfin
its played state and resume point (reported now), AniList its list
(later).

- **The rule** (`WatchSession` in `packages/core/lib/src/watch_session.dart`,
  pure): one per opening, sampled every second with the position,
  whether the media plays here (the server's transport is playing and
  this player plays it) and whether this viewer is In (its presence in
  `state`). The basis is time In: wall time it played while this viewer
  was `in`. Time sat out (Away), joining, gone, paused or held never
  counts, nor does a jump (skipping around adds only what was played);
  samples more than 10 s apart add nothing. A resume carries the earlier
  watch: when what played starts within 60 s of the resume point, the
  time up to it counts too. At a stop: played before -> keep played;
  time In >= 70 % of the runtime, or the ending reached (furthest
  position while In past the Outro / ED start or into the last 15 %, at
  most 4 min, whichever is earlier) with time In >= 40 % -> played;
  under max(2 min, 5 %) (at most a quarter of a short item) -> a peek;
  else part way, resuming at the last position seen while In. An unknown
  runtime never makes it played.
- **The tracker** (`WatchTracker`, `lib/src/watch/`, made by the
  composition root): one watch per media of the server (`mediaId`), fed
  by the coordinator's 1 s tick, also through drops (the player goes
  on); a reconnect or a server restart never ends it while the media
  plays on (it follows the media to its new `mediaId`, and goes on while
  a restarted server waits for it, see "Server restart"); another media
  or leaving closes it, the end of the media
  (`finished`) records it as it stands (a seek back goes on with it).
  Each record (`WatchRecord`: key, title, `media.ref`, verdict, time In,
  runtime) goes out on `records`, where AniList progress will listen,
  and to the device's history. Keys (`WatchKey`): a file this app put up
  by its path, a Jellyfin item by its ids, a link this app put up or
  everyone opens by its URL, else name and size (someone else's file).
- **The history** (`WatchHistory`, Hive box `watch_history`): files and
  links only (Jellyfin keeps its own): played, or a resume point (a part
  way watch of an item played before keeps it played); a peek changes
  nothing. Played before (and the resume point) for the next opening
  come from it; the Files page's "Next" follows the newest watched
  episode of a show, else the last one opened (Recent).
- **Jellyfin**: the reporter reads the same watch (see "Jellyfin in a
  session", "Watched on Jellyfin"); Jellyfin's played state and resume
  point read at open become the watch's "before".

## App events and platform ports

**Status.** What the session is like right now is one computed value,
`SessionCoordinator.status` (`session/status.dart`, `statusOf` over
`StatusFacts`; nothing sets it): the connection's `ConnState`, the
server's state (members and self presence, `state.hold` through who is
in the set and their buffers, the relay's `live`, `fetch`, `sourceGone` /
`sourceGoneSince`), this player's facts (`playerError`: it cannot open the
media; `playerFault`: a "Reload video" failed; `jellyfinPlan`: it plays a
Jellyfin item with its own account, so the relay is not its concern),
`fetchFailedFor` (the server's `fetch-fail` for the current media),
`restarts` (reconnects that found another `welcome.instance`) and a clock
that moves by the minute. `Status.line` is the player's pill (most
pressing first: reconnecting with Cancel, unstable, refused or replaced
with Retry, connecting, your player's fault or error with Reload, the
server getting the video, everyone held for the relay's source
("Waiting for <name>": `state.hold.reason` `source`, a viewer's buffer
ran dry while it is gone; for everyone, own-account viewers too), the
relay's source dropped / left / not passing it on yet, finished, someone loading, someone who cannot play
it, you not ready, who everyone waits for; nothing while it plays and
everyone is fine, and only connection lines while you sit out), each
with a `StatusLevel` (ok and info never colour anything, warn amber,
error red). `Status.party` is the strip's line ("connecting…",
"reconnecting…", "ready 2/3"), `Status.delivery` the members card's
source line ("Relay", Stats). `StatusWatch` turns the transitions worth a
notice into events (Status → Notifier, never back): the relay's source
gone for 5 s or left, another window took over (`Replaced`), the server
restarted, a media starting for the first time (`PlaybackStarted`, seen
held before); the coordinator runs it on every status change and every
second.

**Events.** Everything that may become a toast, a sound, a window
attention request, a system notification or an activity-log line is an
`AppEvent` (`session/app_events.dart`, a sealed type, pure Dart): the
server feed as typed `FeedEvent`s (`FeedEvent.of`, one per feed action:
joins, leaves (`bye` or `grace`), gone (lost signal), return, sat out
(`away`: by oneself, by someone else, or by this app's auto sit-out), back
(`in`), ready/unready, force ready/play/hold, swap, seek, pause, resume,
finished, chat, rename, avatar, queue add (with the item's picture from
the state that came first)/remove/skip, fetch failed; `own` when this
member is the actor; people are matched by `actorId` / `targetId`, never
by name), the session's (nudged, a member can't play, slow source, relay
started/failed, the source dropped, starting now, connection lost/back,
server restarted, replaced, a server refusal, Jellyfin progress not
saved) and the app's (shader message, added to Up next, a put-up or
queue add that failed (the Library's card errors too), Schedule results,
problem marked, copied / copy failed, update available). Code with news
calls `SessionCoordinator.notify` (= `Notifier.notify`,
`session/notifier.dart`); nothing else writes toasts, plays sounds or
sends system notifications (Settings' sound preview aside).

**Notifier policy.** `noticeFor(event, NoticeContext)` is the whole
policy, one `Notice` per event: its `NoticeCategory` (chat, nudge, start,
upNext, people, party, problem, self, app), the toast text, its actor and
picture, the `SfxCue`, attention, the system notification, the feed line
for the activity log. The context: self presence (in, away, gone), alone
(core's `isAlone` over the others' presence), the window
(`WindowActivity` from `ShellPort.watchActivity`, wired in `main`),
playing, the user's choices (`NotifyPrefs`: chat pop-ups All / Only when
paused / Off, and `notifyPeople`, joins and leaves while away or in the
background, default off). The coordinator gives the session's part
(`Notifier.session`). The rules (D1, D4, D9):
- Every feed line is logged (`Notifier.feedLog`, the last 100); lines a
  reconnect replayed (`replayed`) are only logged.
- Toasts (D4): joins, leaves, lost connection (after the server's
  delayed `gone` line) and returns, swaps, Up next adds (title, the
  item's picture, who) and skips, chat, being sat out by someone else or
  by auto sit-out, nudges, problems (someone can't play it, the source
  dropped, a slow or failed relay of yours, a server refusal, the server
  restarted, replaced) and the app's notices; the rest (ready, seeks,
  pauses) only in the activity log. Your own joins, swaps and Up next
  adds pop up nothing (the app already said so); your own chat pops up
  without a sound.
- Sitting out (D1): only chat, nudges, "starting now", Up next, your own
  and the app's notices, plus joins and leaves when chosen; the rest is
  logged without a sound.
- Alone (D9): no social toasts or sounds (people, chat, ready and the
  like, "starting now"); the app's notices, problems and your own show.
- "Starting now" pops up only while you sit out or the window is in the
  background.
- Chat pop-ups follow the setting (it is in the chat either way), and
  none show while the chat panel is open in a focused window
  (`Notifier.chatOpen`, set by the shell); the chat sound has its own
  switch and still plays.
- The window in the background (unfocused, minimised, hidden): what
  reaches a member who sits out (chat, nudges, "starting now", Up next,
  joins and leaves when chosen) also goes out as a system notification
  (title the person, body the rest; silent, the app plays its sound). A
  click brings the window up (`ShellPort.focus`) and, for chat, opens the
  chat (`Notifier.chatRequests`, read by the shell). They are paced
  (`SystemNotePacer`), since desktops refuse an app that sends several
  within seconds (KDE Plasma: `ExcessNotificationGeneration`): the first
  after a quiet spell goes out at once, what comes in the next 4 s
  (`systemGap`) waits and then goes out as one (`SystemNote.merge`: the
  shared title, else "Starsync", a line each, at most 5; a later one with
  the same tag replaces a waiting one; a click opens the chat when any is
  chat), which starts the next gap. What still waits when the window
  comes back to the front is dropped (its toasts show it).
- A nudge also asks for attention; an available update makes no notice
  (the update band shows it, off the full player while a video is on).
- The unread badge counts chat in the log (never on the picture while it
  plays).
The Notifier owns its toasts' timer: `Notifier.toasts` holds what is on
screen, each dropped `toastLife` (5 s) after it came (`dismiss` earlier, a
click on a chat toast); cleared on connect.

**Ports.** UI and session code reach the platform through interfaces
(`platform/ports/`), made once in the composition root
(`AppGraph.ports`, `desktopPorts()` in `platform/desktop/`) and
handed on from there (the coordinator gets its `Notifier`, `Connection` and
`LinkResolver` as constructor arguments):
- `ShellPort` (`DesktopShell`): window start (remembered bounds, the
  close request routed to `shutDownApp`), fullscreen, minimize/maximize
  and their changes, the window's activity for auto sit-out
  (`watchActivity`: focused, unfocused, minimised, hidden; window_manager's
  focus, blur, minimise and restore, and the shell's own `hide`, wired to
  `SessionCoordinator.windowActivity` and `Notifier.window` in `main`),
  bringing the window up and focusing it (`focus`, with another start's
  activation token, see "Single instance" below), dragging (`WindowDragArea`), close, the way out
  (save, hide, quit), attention, the clipboard paste (files, else text), the clipboard's
  text alone (`readClipboardText`, for the join prompt)
  and drop targets (fox_utils).
- `UrlOpener` (`DesktopUrls`): `xdg-open`, `open`, Windows' `url.dll`.
- `FolderAccess` (`DesktopFolders`): folder and file dialogs
  (file_picker), the Files scan, folder exists, file stat, showing a
  folder in the file manager. Paths for now.
- `LinkResolver` (`AppYtDlp`): the app's yt-dlp, link probes (what a
  page plays, see "yt-dlp"), whether this device resolves pages
  (`resolvesLinks`, the media plan's capability), warm-up.
- `PlayerHost` (`MediaKitHost`): the media players ("Player host" under
  "Media"); Files' thumbnails make theirs with it too
  (`thumbnailPlayers`, set in `main`).
- `SystemNotifications` (`DesktopNotifications`,
  `platform/desktop/desktop_notifications.dart`): `show(title, body, tag,
  payload)` and `onClick(payload)`, through flutter_local_notifications'
  platform plugins, picked by the OS: Linux `org.freedesktop.Notifications`
  over D-Bus (pure Dart; the bundled 256 px icon, else the launcher
  entry's icon by name; a click is the default action), Windows toast
  notifications (WinRT, app id `Foxyz.Starsync`; an unpackaged app keeps
  no history, a click activates it while it runs). Silent; anything that
  fails (no notification daemon) is logged and dropped.
- `AppDirsPort` (`DesktopAppDirs`): where Hive and the logs live
  (`AppDirs`, "Desktop UI"), and the copy of the data from before the
  rename; resolved in `main` before the composition root exists, so not a
  `Ports` field.

**Single instance** (`platform/single_instance.dart`, `InstanceLock`): one
app per profile folder (`<app support>`, or `profiles/<name>/` with
`STARSYNC_PROFILE`, so each profile is its own instance). `main` claims
it right after resolving the folders, before the log or the window: an
exclusive `RandomAccessFile.lock` on `instance.lock` (the OS drops it
when the process ends, a crash too) and a loopback listener whose port,
a random token and the pid go in `instance.json`. A start that finds the
lock held sends its arguments and activation token there (one JSON line
with the token) and ends at once through the runner (`exit` on the
`starsync/window` channel: `_exit` / `TerminateProcess`, no exit
handlers) before its window ever shows; the running app brings its
window up (`ShellPort.focus(activation:)`) and hands the arguments to
`JoinOffers`. Bringing a window up from another process needs the
desktop's permission: on Linux the second start's `XDG_ACTIVATION_TOKEN`
(Wayland) or `DESKTOP_STARTUP_ID` (X11), which the runner keeps before
GTK takes it (`launchToken`) and the running app presents its window
with (`present`: `gdk_wayland_display_set_startup_notification_id` /
`gtk_window_set_startup_id`, then `gtk_window_present`; the launcher
entry has `StartupNotify=true` so launchers hand one out); on Windows
the second start calls `AllowSetForegroundWindow` for the holder's pid
(`platform/desktop/windows_api.dart`). While the app closes it answers
"closing" and a new start waits for the lock (up to 20 s; 5 s without
any answer), then starts anyway; Update and restart gives the lock up
before starting the new binary. Invite links among the arguments are
not passed on to that restart (`launchArgs`).

**Link handler** (`platform/url_scheme.dart`): on Linux the launcher
entry ("App icon and launcher entry") lists
`MimeType=x-scheme-handler/starsync;` with `Exec=... %u`, and
`xdg-mime default dev.foxyz.starsync.desktop x-scheme-handler/starsync`
runs when `xdg-mime query default` names another (then
`update-desktop-database` on the applications folder). On Windows
(release builds) `HKCU\Software\Classes\starsync`: default value
`URL:Starsync invite`, `URL Protocol` empty, `DefaultIcon` and
`shell\open\command` = `"<install>\starsync.exe" "%1"` (`starsync.exe`
next to an old-named `watch_together.exe` copy when it is there),
written per user (no admin) through `RegSetKeyValueW` at start only when
the command differs (first start, a moved install, an update from an old
name).

Still direct: the updater's restart
(`Process.start`), the session's own file reads for what it plays or
relays (`QueueController`, thumbnails, cookies import), app-private
caches.

## Desktop UI

One window, `AppShell` (`lib/src/shell/`), wherever the app is
(`Navigation.place`: your server, a friend's, none while it moves). The
window comes back as it was
(`platform/desktop/window_memory.dart`, settings key `windowBounds`, saved on
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
menu; the player controls' track, chapter and ⋯ menus are on it too.
Material's own menus (the Jellyfin sort and server switch) get the same
surface from `AppMenuStyle.theme`.
Reusing what the app shows (`widgets/copy_open.dart`): one wording
(`ReuseText`: Copy link, Copy title, Copy message, Open in browser, Open
in Jellyfin) in every right-click menu that offers it, and a toast
confirming a copy ("Link copied"); a browser that will not start copies
the link instead. Offered on recent links and the Link preview (one
menu for both: Put it up, Add to queue, Play next, Copy link, Copy title,
Open in browser), Up next rows (see "Up next"), the
now-playing title (Copy title; with the link known here,
`SessionCoordinator.currentLink`: one this app put up, or one in the
state, Copy link and Open in browser; a Jellyfin item of a server linked
here, Open in Jellyfin), Jellyfin items (Copy title, an episode with its
series; Open in Jellyfin: `jellyfinWebUrl`, the item's page on its
server's web UI, no credentials; see "Jellyfin item actions") and chat
messages (Copy message, and a link in it). Menu rows can carry the
action's own icon (`AppMenuItem.icon`, the same as its button's).

- **Party strip** (`party_strip.dart`, 60 px): your avatar (profile card; 42 px like the party's),
  the Library / Schedule / Settings tabs with a growing underline (an
  `HScroll` when narrow; the version in the Settings tab's tooltip, at
  the bottom of every Settings page and in About), then the party. Alone
  on your server (D9, `SessionCoordinator.alone`: nobody else connected)
  it is a plain player's: no ring on your avatar, no avatars or chat, Join
  a friend (the Join card; "Join" under 1100 px) and Invite (disabled until
  your server runs), plus a "Sharing · port 8080" chip while it is shared
  (it opens the members card). With others there, or in a friend's server:
  `AvatarStack` (host first, then ready; spreads on hover; 5 shown, 3
  under 1100 px; each avatar its person's card, see "People cards"), the
  server name ("Your server", else the joined one's
  `/health` name, else its address) and `Status.party` ("ready n/m": who
  the ready counter counts, `countsForReady` in `session/party.dart`, on
  `PresencePolicy`, so not away, gone or errored; "connecting…",
  "reconnecting…"; hidden under 1100 px), chat with an unread badge, then
  Invite on yours or Leave on a friend's (asks first, then you are home).
  Invite (`inviteFriends`, `shell/your_invite.dart`) shares your server if
  it is not yet and copies the invite link ("Invite link copied"); a port
  it cannot open
  is a notice pointing at Settings. The server name and "ready n/m" (a
  click), "+N" and a people card's "Everyone in the server" open the
  members card (the server's version under its title: yours is
  this app's, a joined one's from `/health.version`; the source
  line, then per member status, route and buffer dot (see "Relay",
  Stats), their Starsync version (`members[].app`, amber when it is not
  this app's; also on their people card), host / relay pills; "joining…", "sitting out", or for a `gone` member
  "reconnecting… (2 min)" with how long; per member force ready, Nudge and Sit
  out (anyone, the host too), your own row Sit out / Join back; at the
  bottom, on yours: not shared, "Only you can reach it" and Invite;
  shared (`YourInvite`), Copy invite link (filled; the address the app
  picks, `InviteReach.best`, in its tooltip) and Stop sharing; one line
  only when something needs the user ("Looking up your internet
  address…"; the router's address: the port needs forwarding to this
  computer; no internet address found: the link works on the home network
  only); "Other addresses" (folded, only with more than one) lists each
  address of `YourServer.reach` (Internet, Home network, VPN) to pick
  what Copy copies; on a friend's, "Copy invite link" (the dialled address,
  its name and the password you joined with: the link is the key there
  too))).
  Empty strip space is the window
  drag area; the window buttons sit at its end.
- **Avatars** (`avatar.dart`): `StatusAvatar` draws a ring outside the
  picture with a gap in the background colour (both scale with the size):
  green ready, amber buffering (with a spinner), grey not ready, a little
  faded joining, dimmed with a dark ring `gone` (reconnecting, last in
  the stack), dimmed with a moon ("away") sitting out; a crown for the host (`members[].host` in the state; your own
  app also knows before the first state) and a tower for the member
  passing the video on. `memberAvatarImage` is the one picture lookup: yours from the
  profile, anyone else's from `coordinator.avatars` by `avatarHash`.
  Colours are local: yours is picked in the profile, others' come from
  their name. A toast's or danmaku line's avatar (`LineAvatar`) is
  looked up again while its picture is missing, so a picture that lands
  after the line (fetched from `/a/` once the member is seen; a failed
  fetch retries) still shows on it.
- **People cards** (`person_card.dart`): one card for a person wherever
  they show: the strip's and the fullscreen `AvatarStack`, the members
  card's rows (picture and name; no link back to it), chat lines
  (picture and name), toasts (the picture: `ToastColumn` puts a
  `PersonHover` over it, the rest of a toast still lets clicks through)
  and danmaku lines (their sender's avatar and name). `PersonHover`: the
  mouse resting 450 ms shows it under the person (over them when the
  room below is short) as an overlay, moving into it keeps it, leaving
  both hides it after 220 ms; a click pins it (`showPersonCard`, a popup
  route: a click outside or Esc closes it). Danmaku lines move too fast
  to rest on: `DanmakuPersonTaps` around the player's controls asks the
  layer where each line's sender is now (`DanmakuController.senderAt`,
  from the flow's own positions) and pins the card on a click there,
  while the controls still get the click. The card is frosted glass
  (`AppGlass`, 312 px) read live from the state by member id (else by
  name; the place's own `AvatarInfo` once they left: "Not in the
  server"): a 64 px `StatusAvatar` (with a picture, a click shows it full
  size, `showPictureView`), name ("you"), presence (Watching, Away ·
  sitting out, Gone · reconnecting (2 min), Joining…), host / passing
  the video on pills, ready (or can't play, buffering), their route and
  buffer, what they pass on ("Passing on <now playing>", or "Hosts" the
  file, with the source line's numbers), their Starsync version
  (`VersionText`), their actions (`memberActions`: Force ready /
  unready, Nudge, Sit out, Join back; the members card's ⋮ shows the
  same list) and "Everyone in the server". In fullscreen an open card
  holds the controls up. The status pill's avatars keep a plain name
  tooltip (a click there is the pill's).
- **Join card** (`connect_cards.dart`): recent servers as one-click rows
  that poll `GET /health` every 10 s while the card is open
  (`health_probe.dart`: online, name, viewer count, "needs update" with
  the version gate's sentence as its hint), then address, port and
  password; an invite pasted into the address fills the port too
  (`addressIn`). Submit state (busy, cancel, the error) is `ConnectFlow`,
  owned by the shell so an attempt and its error outlive the card; the
  version gate's refusal says who has to update and, when it is you,
  offers "Check for the update". The card closes itself once in the
  friend's server. It says to paste a friend's invite link (it carries
  the password) or their address and password, that no account or Jellyfin is needed and that your own
  server stays as it is. A join with no profile name (any way in: the
  Join card, a link or the clipboard's invite) first asks for one
  (`ConnectFlow.askName`, the shell's `askYourName`): `NameCard`, "Wait,
  what do we call you?", with the profile card's picture and colours
  (`ProfilePicture`, `ProfileColors`) and a name field prefilled with
  `suggestedName` (the OS user name), focused; OK saves the name and the
  same join goes on, Cancel (Esc, a click outside) drops it.
- **Profile** (`profile_card.dart`, `session/identity.dart`): a card
  tinted with your colour: picture (hover "Change" opens `CropPicker`:
  drag, wheel or slider zoom, previews at 88/42/24 px, exports a 256 px
  PNG), name edited in place, colour swatches, links to the Settings pages.
  `Profile` stores the name in the connect form and the PNG and colour in
  the `connect_form` box (an old picture path is shrunk once and kept as
  bytes). Online, a name change (once typing settles) or picture change
  goes out through `Profile.push` (`coordinator.updateProfile`).
- **Welcome** (`welcome.dart`): alone on your server the Library opens
  with `WelcomeBand` over the source switch, only for newcomers (no
  Jellyfin account, no recent server, not dismissed with "Don't show
  again"; sizes away once others are there): the app
  icon, Starsync and "Watch together, in sync", then three `WayCard`s,
  Join a friend first (filled), Invite friends, Watch on your own (opens
  Files, or Jellyfin when linked); beside the name from 940 px, under it below,
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
  cross-fades between items): banner, meta, "Put it up · S1E3" and the
  item's actions (see "Jellyfin item actions": a show's marks are the
  whole show's, an episode's its own), overview, the episode list under
  the season picker and the season's own actions (click picks the
  episode, double-click puts it up, right-click its menu). A double-click
  on a card puts it up (a series: `playableFor`, its next episode). Link
  (`library_link.dart`): paste field, a preview (a page's yt-dlp title,
  uploader, length and thumbnail, else the file name; see "yt-dlp"), the relay modes online ("Through me",
  the controller's default, as the main card; "Everyone fetches it" and
  "Server fetches it" under "Other ways", open while one of them is
  picked, closing it goes back to Through me), and the
  last 12 links put up, here or from the drop and paste card
  (`recentLinks` in the `connect_form` box: URL,
  title, thumbnail, the preview's second line, when). A link seen before
  previews at once, without yt-dlp: `LinkPreviewStore` (`linkPreviews` in
  the same box) keeps what a probe found for up to 200 links that looked
  playable (title, second line, thumbnail URL and when; never cookies or
  resolved stream URLs), else a recent link's card stands in. Older than a
  day it is still shown and probed again quietly behind it (a site out of
  reach keeps it; a problem replaces it and is not kept). Putting it up
  or queueing resolves as before (reusing a probe still in memory); when
  that fails although the kept preview looked fine, the preview is
  probed again and shows why, with "Put it up anyway" when it is a
  problem. Files
  is `FilesPage` (`files/`), a library over the watched folders
  (`FolderStore`, each scanned in an isolate when first needed): places
  on the left (chips when narrow): Library (every folder together, the
  default), Recent, then each folder (`showFilesFolder` opens one from
  outside). A place is poster cards (2:3, like the Jellyfin browser's;
  the AniList cover, else a frame of the first episode) for its Shows and
  Movies, then the Other videos as 16:9 cards; a show card says how many
  episodes, or the next one after the last played here (right-click: put
  that one up or queue it, or open the page). A click on a show opens its
  page (`files/ui/library_view.dart`, kept open per place for
  the app session, Back returns): a banner header (AniList banner, else a
  frame) with the proper name, what the files are (seasons, episodes,
  extras, group, folders), the match ("AniList: …", "files say …",
  pinned), the gap prompt ("66–107 aren't in your folders — skip to
  108?") above the next-episode button, Wrong show? and Episode
  numbers…; then season chips (more than one season), the season's
  episodes as rows ("12. Name" with AniList's episode title, else
  "Episode 12"; one click plays, right-click: put it up, and in a server
  queue it) with the holes as
  muted rows, Extras and the show's Movies. With nobody else
  in the server (`alone` on the Library, Files and Schedule, D9) the
  buttons say Play, Link has no relay modes and a link goes up direct,
  Files has no relay notice; a put-up before your server is up waits for
  it. Schedule (`schedule/`) is a week of day columns built
  from AniList's airing schedule (`anilist.dart`: pages cached 10 min in
  memory and 1 h on disk, stale data shown on 429 or failure) matched
  against AnimeFlow (`animeflow.dart`, app API with the Jellyfin token;
  `/library` marks shows on Jellyfin it doesn't track, through every AniList
  entry of a season (`anilist_map`: a season AniList splits has several)) into a status per
  episode (`schedule_model.dart`). AnimeFlow's `missing` (aired,
  monitored, no release grabbed yet; AnimeFlow grabs it by itself once
  one appears), and its `upcoming` past the AniList air time, read
  "waiting for release" (with "searched N min ago" from the episode's
  `last_searched_at`, or "release rejected" with AnimeFlow's `reason`
  sentence on hover when it found releases it won't take); Request is
  offered only for an `unmonitored`
  episode (and "Request series" for a show AnimeFlow does not track).
  Air dates (AnimeFlow's `air_date`, midnight Japan time; Jellyfin's
  premiere date)
  are date-only and matched as Japan calendar days (`sameAirDay`; a slot
  before 05:00 JST also matches the day before), never as local days. An
  aired episode of an untracked show on Jellyfin reads "on Jellyfin" only
  when Jellyfin has it: the season plus AniList episode + the run's
  offset, checked against the series' episodes seen by the linked
  account (`jellyfinScheduleEpisodes`, one request per series memoised
  3 min; `confirmOnJellyfin` is the pure step); absent reads "aired · not
  on Jellyfin yet", unknown (no linked account, lookup failed) "aired",
  neither with Put it up. The same lookup covers AnimeFlow's available
  episodes (AnimeFlow's season and episode, else the one premiered that
  day) and gives every episode found this user's `UserData`: a watched
  one has the library cards' green check on a slightly dimmed cover, a
  started one a thin bar to its resume point. A stop report
  (`JellyfinAccounts.watched`) drops the memo and reloads the page. Put
  it up resolves the Jellyfin episode (`resolveJellyfinEpisode`:
  AnimeFlow's numbering, else the season and offset, else the air day)
  and goes through the shell's put-up; right-click queues it the same
  way. Requests and the owner's inbox are in `requests_sheet.dart`. It refreshes every minute; mouse drag and
  Shift+wheel scroll the board sideways, the plain wheel scrolls a column.
  Settings (`settings_tab.dart`, `SettingsSection`) has a left nav with
  icons (icon chips under 760 px) over pages of rounded Material cards
  (`SettingsPanel`) drawn with the setting rows (see "Setting rows"),
  one help line under every setting; each page shows its common rows
  first and folds the rest under More (`SettingFold`). Ctrl+, opens the
  page last shown, Player at first. Every setting has one home (where a
  new one goes: DEVELOPMENT "Where a new setting goes"):
  - **Player**: Sound (Volume, `playerVolume`), Subtitles (size, above
    the controls), Picture (Upscaling shader with HQ / Fast; More: custom
    shader files, sharp video, hardware decoding), Controls (player
    design, controls size, progress line; More: the bar's optional
    buttons), Playback ("Play the next episode automatically": whether
    this app adds the continuation, see "What's next"). A line says the
    player's ⚙ opens these while watching.
  - **Party**: You (picture, name and colour edited in place with the
    profile card's `ProfilePicture` / `ProfileColors`; the profile card's
    Settings link opens this page), Away (auto sit-out), Your server
    (port and password, used the next time it is shared, in the connect
    form), Recent servers (Forget, as on the Join card).
  - **Notifications & sounds**: Over the video (Notifications: toasts or
    danmaku, Chat pop-ups, Joins and leaves too; More: the danmaku look
    with its preview strip and what pops up when), Sounds (App sounds,
    Sound set; folded: each sound with a preview, its own set and a
    switch).
  - **Library & accounts**: Jellyfin servers, AnimeFlow (`/me` via
    `AnimeFlowClient.fromAccounts`), Web links (yt-dlp and its cookies).
  - **Updates**: status, Check now, Show update; More: the channel.
  - **Help & about**: Something wrong? (Copy diagnostics, Mark a
    problem, Open logs folder, Share diagnostics with the server),
    Keyboard shortcuts (the player's; folded: anywhere and the library),
    About, Developer (dev builds).
  No row for what has a fixed default or a place in context: the
  controls hide after 3 s, a swap never unreadies, update checks always
  run (D8), the clock's click switches elapsed / remaining, the Latest
  row's ⋮ hides re-releases (stored values: "Settings schema").
- **Drop and paste** (`handoff.dart`, `fox_utils`): the shell is one
  `DropTarget` (a "Drop to open" overlay while dragging) and a
  `HardwareKeyboard` handler for Ctrl+V outside a text field (clipboard
  files first, then text). `classifyHandoff` (pure) turns paths or text
  into videos (the Files extensions, `kindOf`), a folder, an http(s) link,
  an image or nothing; videos win over folders, folders over images.
  `HandoffCard` opens as a popover at the pointer. Putting up is one
  click, like Add to queue: a video or a link goes up through the shell's
  put-up (Play when alone), a link in the Link page's relay mode (named on
  the card; alone direct), probed and refused like there (a toast says
  why; the link is left in Library → Link for "Put it up anyway"), and
  then on the Link page's Recent (`rememberPutUpLink`). A video can add
  its folder to Files instead; a link can open in Library → Link ("Open
  in Link" alone, "Other ways…" with others, to see it first or pick
  another mode); a folder is added to Files and opened. In a server,
  videos and links also get Add to queue / Play next. While others are
  watching something (`replaces`: not alone, a video on and not
  finished) Add to queue is the filled first button and the put-up reads
  "Put it up now" (its tooltip: it stops what is on for everyone), since
  replacing what everyone watches is the bigger step; otherwise Put it up
  leads. Images are ignored.
  Nothing happens while a dialog or popover is over the shell.
- **Sounds** (`sfx/`): the `Notifier` plays an `SfxCue` for ready,
  unready, force-ready, join, leave, swap and others' chat (feed
  events), being sat out by someone (the `kick` sound), a nudge (always,
  whatever its switch), auto sit-out setting you away (`warn`), and
  connection lost / back (once per drop that lasted a few seconds).
  Nothing for what the video already says (play, pause, seeks, the end),
  nothing about the party while watching alone, and while sitting out
  only for what still reaches you (see "Notifier policy").
  The sounds are synthesized, not sampled: `synth.dart` renders voices
  (plucked strings with bends, glass and star bells, a singing bowl,
  hollow knocks, wooden clacks, filtered-noise air and stardust, a long
  dark space reverb) to quiet WAVs; `sound_bank.dart` voices every event
  in three presets (`SoundPreset`: Cosmic, Abyss, Wood & glass) in one
  shared key, so mixed presets still agree. `SynthSfx` renders a sound on
  first use (on a worker isolate, to WAV bytes in memory) and hands it to
  `SoundEngine` (`platform/audio/sound_engine.dart`), which loads it into
  flutter_soloud (SoLoud mixing into a miniaudio output device; voices
  overlap) once per slot (sound and ready index); a different preset in a
  slot replaces and frees the old sound. Each play is at
  `AppSettings.soundVolume` (as v^6, SoLoud's linear gain: the square curve times mpv's cubic volume the sounds used to play through, so the slider sounds as before) unless
  switched off in `soundsOff`. The device opens 2 s after startup
  (`warmUp`), so neither startup nor the first sound waits on it; if it
  can't open, the engine logs `no sounds: audio init failed` once and drops
  every play. App close disposes the engine (deinit, 500 ms bound)
  before leaving the server. Settings → Notifications & sounds → Sounds has App sounds (also in the player panel), the
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
  nor remounted. The mini has no control skin: its `Video` gets an empty
  controls builder (never null: media_kit keeps the last controls on
  null, which left the full player's bars under the mini). Hovered it
  shows the title with expand and ×, the status line, the full player's
  play button (`controlIcon`/`togglePlay`: ready in a server) with the
  time, and a 4 px bar (track, cached, played) that seeks; otherwise a
  3 px played line along the bottom edge. A tab sends the full player to mini; × on the mini sits
  out (the player unloads and shows the join-back card, `SitOutCard`, over
  the still mounted `Video`); × on that card closes the player, the strip
  brings it back, and joining back with it closed shows the mini. Fullscreen
  is `windowManager.setFullScreen` with the strip hidden (party avatars in
  a corner while paused); F, Esc and double-click on the picture toggle it.
  The player keys (Settings → Help & about → Keyboard shortcuts) work while the player is
  full and nothing is in front of it; ↑ / ↓ step the volume, M mutes. Space (ready)
  and Tab (chat) are app-wide: `AppKeys` (`widgets/app_keys.dart`, around
  the shell) takes them first while in a server, unless a text field (or
  a `KeyboardClaim`, see "Up next") has focus or a dialog or menu is in
  front. Tab reaches the shell's chat
  toggle through `ChatKey` (the strip while shown, the player in
  fullscreen). The app's shortcuts map Tab / Shift+Tab to nothing, so focus
  never lands on a button Space would press. The arrow keys never take
  focus onto the strip (a `FocusTraversalGroup` that is not traversable)
  and the window buttons never take focus at all (`ExcludeFocus`), so
  Enter never presses them. While the full player has the keys it keeps
  the arrows, PgUp / PgDn, Enter and every key it acted on from the focus
  system until they are let go (`FocusManager` early handler), acted on
  or not (a debounced press, no chapter to go to, sitting out): no focus
  moves, no focused button is pressed, nothing behind it scrolls. Something coming up while the player
  is closed opens it: full right after joining or after putting it up
  here, else mini. Both control skins show `NowPlayingTitle` top left
  (`now_playing_title.dart`: 2:3 cover, title, episode line from
  `coordinator.nowPlaying`, art through `artBytes`; it fades through when
  the media changes); the mini shows title and episode without the cover.
  Until playback first starts on a media (server not playing, position
  under 1 s) `StartBanner` (`start_banner.dart`) lies under the controls:
  the banner (else a blur of the cover, else dark), darkened, with cover,
  big title and episode; it fades out on play and stays gone for that
  media; under 320 px tall (the mini) it drops the cover and shrinks the
  title. One status pill (`player_status.dart`) sits centred in the
  action area (see "Player overlay"): it shows `Status.line` (see "App
  events and platform ports"), connecting only after 2 s: reconnecting
  (Cancel), refused or replaced (Retry), your player's problem (Reload),
  the relay, finished, someone loading (below
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
  between kinds. The mini shows its short line in its hover bar. ⚙ in
  the bar (both skins, "Player settings") toggles the player panel
  (`controls/player_panel.dart`, `PlayerControlsModel.panelOpen`): a
  312 px `AppGlass` column docked at the right of the full player,
  between the top bar and the control bar (it never covers the bar),
  sliding and fading in from the right; it stays open while the controls
  hide and show, until its × or Esc (the player's Esc closes it first),
  and leaving the full player closes it. The mouse on it holds the
  controls up (`ControlsHoldRegion`). It draws Settings' own widgets
  (see "Setting rows"), dense, in sections (`PanelSection`) that fold
  (their titles toggle; folded ones are kept for the app's run, Over
  the video and Controls start folded): Sound first (Volume, the
  video's, on the bar's `VolumeBar`; App sounds, `soundVolume`, with a
  line saying it is the app's cues, not the video), Subtitles & audio
  (the subtitle and audio tracks, remembered as from the track menus;
  Subtitle size, mpv `sub-scale` from `AppSettings.subScale`, set on
  every player; Subtitles above the controls, see "Subtitle lift"),
  Picture (Upscaling shader, HQ / Fast under an Anime4K mode; folded
  under Troubleshooting: Sharp video and subtitles, see "Media", and
  Hardware decoding, set live on mpv's `hwdec`, with the custom value's
  field), Over the video (Notifications: Toasts / Danmaku, Chat
  pop-ups, and with Danmaku the look's knobs folded, see "Danmaku
  notifications") and Controls (Player design, Controls size, Progress
  line when hidden). At its foot All settings and Mark a problem: All
  settings opens the Settings page of the section last opened or
  clicked in (`settingsPageFor`, through the shell's `_openSettings`,
  which takes the player to the mini as any tab does); all apply live.
  The progress line (`AppSettings.progressLine`) is
  what the bottom controls leave while hidden: Standard a 2 px line,
  Minimal its collapsed timeline. Fullscreen adds the
  `WindowButtons` to the top bar while the controls are up (restore
  leaves fullscreen).
- **Player overlay** (full player, both skins; `session_player.dart`):
  everything over the picture has a fixed place on one grid (16 px from
  the sides, the bars' inset), so nothing floats on its own. The top
  bar (part of the controls): now-playing title left; right the Up next
  button (`UpNextButton`), ⋯ ("Video and session", see "Player
  controls"), back-to-library or exit fullscreen,
  then the window buttons in fullscreen, all in that skin's button
  look. Under it at the right, in fullscreen (the strip is hidden), the
  party's `AvatarStack`: it comes and goes with the controls (fades with
  `controlsShown`, takes no clicks while hidden), moves left of the
  player panel while that is open, and works as the strip's (people
  cards, "+N" or a card's link for the members card; the mouse on it and
  an open card hold the controls up); with the controls down and unread chat,
  the unread chip top right. The action area: one band just above the bottom controls
  (`_actionArea`; their height per skin and size, `controlsBottomHeight`,
  16 px gap), sliding down to
  16 px from the bottom while they are hidden (`AnimatedPositioned`,
  the shell's `ease` / `easeTime`); in it the status pill centred
  (moved left only as far as it must to clear the right end, never
  overlapping it) and at the right end the end card (`UpNextCard`, which
  stays up) or the action pills (Skip OP / ED /
  1:30 over Next episode, `PillGate`). The Jellyfin blocked card sits in
  the middle. Two surfaces: cards and popovers use `AppGlass`
  (`widgets/app_menu.dart`, the menus' recipe: blur, dark tint, hairline
  border, 12 px radius, shadow); pills use `PlayerGlass`
  (`AppGlass.pill`: a stadium, lighter tint, no shadow): the status
  pill, the unread chip and `FloatingPill` (the action pills, 44 px
  tall like the status pill without avatars). The mouse on any
  floating element counts as the mouse on the controls: a
  `ControlsHold` (`controls/controls_probe.dart`) held by
  `ControlsHoldRegion`s (and by the open Up next popover or its preview) keeps the
  controls up (`ControlsFrame.holdBy`), and lets them hide on their
  usual countdown once released.
- **Chat** (`chat_panel.dart`): a 340 px panel sliding in at the right
  (strip button or Tab): chat with avatars; the "Activity" chip (off by
  default, `showActivity`, kept for the app's run only) adds the other
  feed lines between them. Its field shares the quick chat box's draft
  (see "Quick chat"). Opening focuses the field; Tab or Esc in it
  close the panel and focus goes back where it was. Unread chat badges
  the strip's and the player controls' chat buttons; in fullscreen with
  the controls down and the video not playing a glass chip
  (`PlayerGlass`) top right shows it (while it plays nothing sits on the
  picture).
  **Toasts** (`toasts.dart`): the `Notifier`'s toasts bottom left, with
  the avatar of their `ToastItem.actor` (feed and chat toasts; the app's
  own have none) and an Up next item's picture (`ToastItem.thumb`, from
  the queue's picture cache); each slides in, stays while the Notifier
  keeps it (5 s), then slides out and collapses its gap. A click on a chat
  toast opens the chat; the others let clicks through, but for the
  sender's picture (their people card). They never cover
  the player's controls: over the full player (both skins, windowed and
  fullscreen) they sit `toastInset` (16 px) above the control bar
  (`controlsBottomHeight` of the skin and size in use) while the controls
  are up and come down to 16 px from the edge while they are hidden
  (`AnimatedPositioned`, the shell's `ease`; the player reports its
  controls through the shell's `controlsShown`); elsewhere 16 px from the
  bottom left. What pops up at all is the Notifier's policy. Each
  `ToastItem` carries its `NoticeCategory` and whether it is your own
  (`own`); the shell leaves out those flying as danmaku and your own chat
  coming back for a line the quick chat box already showed
  (`PartyToasts.skip`).
- **Quick chat** (`shell/quick_chat.dart`): Enter in the full player
  (not the mini: it is a corner thumbnail while you are elsewhere in the
  app, where Enter belongs to that page; nor while sitting out) opens a
  small box at the bottom centre, 16 px up, in the control bar's place,
  without opening the chat panel. Enter is a `HardwareKeyboard` handler
  of the player, so it works whatever plays and whatever button kept
  focus; a `FocusManager` early handler swallows that Enter so the
  focused button does not act on it too. `QuickChat` (the shell's, it
  outlives the player's modes) holds the state: the draft is the chat
  panel's `TextEditingController` (typing in either shows in both, a send
  from either clears both), its `FocusNode` takes focus at once (keys
  typed right after go to the box; `textInputFocused` keeps Space, Tab,
  F and the arrows off the player meanwhile), and it closes by itself
  after `idleClose` (8 s) without typing, Esc, or an empty Enter, keeping
  the draft for the next Enter. Enter with text (an input method's
  composing Enter excepted) sends it (`sendChat`) and closes. The box
  (`QuickChatBox`) starts 300 px wide and widens with the text up to
  640 px (or the room there is), then wraps up to four lines, growing
  upward; your avatar leads it; it fades and slides in on the shell's
  curve and stays mounted while closed (invisible, ignoring the pointer)
  so focus is immediate. What you send comes back like everyone's chat:
  your own chat toast while the chat panel is closed (no sound), or your
  own danmaku line. While the box is up the controls are
  held hidden (`ControlsFrame.suppress`: drawn hidden, `shown` false, the
  cursor still follows the mouse) and the action area rides above the
  box. Typing is not mouse activity: the frame wakes the controls only
  on real pointer movement (an enter or hover at the last seen position,
  as when the box comes or goes under a still pointer, does nothing), and
  the field's I-beam stays hidden until the mouse moves over it, so
  Enter, typing and sending never show the cursor or the controls.
- **Subtitle lift** (`video_view.dart`): bottom subtitles move above what
  covers the bottom of the full player: the quick chat box (always), and the control bar while it is up when
  `AppSettings.liftSubtitles` is on (off by default; Settings → Player →
  Subtitles and the player panel, "Subtitles above the controls"); 8 px above it.
  `SubtitleLift` steps the covered height toward each new target in
  `liftStepCount` (4) eased-out steps `liftStepGap` (42 ms) apart, the
  first at once: about one step per frame of a 24 fps video, so each
  lands on its own video frame (a `sub-pos` change per screen frame
  landed unevenly on the video's frames and looked choppy).
  `SubtitleLifter` turns each step into mpv `sub-pos` (`subtitleLiftPos`:
  only as far as the letterbox under the picture leaves no room, at most
  half the picture), back to 100 when nothing covers and for a new
  player. What each mpv property does, on `tool/make_sub_test.sh`'s file
  (mpv 0.41, libmpv as the app uses it): `sub-pos` moves bottom ASS
  dialogue and SRT lines up and leaves `\an8` signs in place (with
  `sub-ass-override` at its default `scale` or `yes`; `no` ignores it
  for ASS); `sub-margin-y` moves SRT only (ASS only with
  `sub-ass-override=force`, which restyles every line, signs too);
  `sub-ass-style-overrides=MarginV=...` moves top signs down as well;
  `video-margin-ratio-bottom` shrinks and moves the picture itself (with
  `sub-ass-force-margins` the dialogue goes into the new black band).
- **Danmaku notifications** (`danmaku/`): Settings → Notifications &
  sounds → Over the video → Notifications: Toasts (default) or Danmaku
  (`AppSettings.notifyStyle`, live; also in the player panel). With
  Danmaku and the full player up (not sitting out), what
  `fliesAsDanmaku` picks (chat, joins, leaves, lost connection and back,
  "starting now", Up next news someone caused) flies right to left
  across the picture (`DanmakuNotices` under the controls feeds new
  toasts to a `DanmakuLayer` through `danmakuForToast`); nudges,
  problems, your own state and the app's notices stay toasts, and so does
  everything with the player small. The player sets the shell's
  `danmakuActive` so the toasts leave the flying ones out. The layer:
  lanes in a band of the height (`DanmakuStyle.bandTop` / `bandBottom`,
  default 10 to 45 %, under top signs, never down into the dialogue);
  each line takes the topmost free lane (`DanmakuLanes`, pure: the last
  line in a lane must have fully entered with a gap, and the new one, at
  its own speed, cannot catch it before it leaves); at most
  `maxOnScreen` fly, the rest wait in order (dropped after 15 s, 60 at
  most); every line crosses in `crossSecs`, so long ones move faster;
  white text at the chosen weight (`weight`, 400 to 900, the name a step
  bolder) with a dark outline and no box, the sender's avatar and
  coloured name first, the app's own notices without one, own lines in
  an accent frame (a click on the sender: their people card); the
  layer's own clock (lines fly on while paused),
  ticking only while lines fly or wait. Each line is a widget moved by a
  `Flow`: per frame only paint runs. The look (`AppSettings.danmakuStyle`,
  one map, `DanmakuStyle.toJson` / `fromJson`, which clamps every value
  to `DanmakuStyle.limits`) has every knob in `DanmakuKnobs`
  (`danmaku_settings.dart`: crossing time, at once, lanes, opacity,
  size, boldness, outline, avatars before the lines, frame my own lines,
  reset; the same words in the player panel), in Settings under a
  preview strip (a moving stand-in picture, a top sign, bottom
  dialogue and sample lines in the current look; it plays for 16 s after
  it opens or a knob moves, then rests until clicked).

**Setting rows** (`widgets/setting_rows.dart`; which page and fold a new
one gets: DEVELOPMENT "Where a new setting goes"): every setting is one
widget, drawn the same way in Settings and in the player panel with the
same label: `SettingRow` (label, help under it, the control at the
right, `below` for an extra line), `SettingSwitch`, `SettingTrack` (a
slider or the volume bar with its readout) and `SettingFold` (rows
folded under "More", or a named fold such as the panel's
Troubleshooting). Under a `SettingDensity` (the panel) they are dense:
smaller type, the help becomes the label's tooltip and only an optional
`brief` line shows, a track's label sits at its left. The player
settings are in `controls/player_settings.dart` (with `setVideoVolume`,
`applyShaderChoice`, `applyHwdecLive`), the notification ones in
`shell/notice_settings.dart`.

Settings persist in two Hive boxes: `connect_form` (last form, recent
servers and links, the profile picture and colour; saved even when a join
fails) and
`settings`. Where Hive and the logs live is `AppDirs`
(`platform/ports/app_dirs.dart`, resolved once in `main` by the
`AppDirsPort`, `DesktopAppDirs` on the desktop): `<app support>/hive` and
`<app support>/logs`; with `STARSYNC_PROFILE` (DEVELOPMENT "Dev loop")
`<app support>/profiles/<name>/hive` and `logs`, and the window title gets
` [<name>]`. yt-dlp, shaders and caches stay shared. The app support
folder is path_provider's: Linux `~/.local/share/dev.foxyz.starsync` (the
application id), Windows `%APPDATA%\foxyz\Starsync` (the exe's company and
product name).

**Data from before the rename** (`platform/data_migration.dart`, run by
`DesktopAppDirs.resolve` before Hive opens and the log starts; its lines
are logged once the log is open): once per support folder (the marker
`<app support>/migration.json`: `migratedFrom`, `hiveFrom`, `boxes`,
`files`), the first existing old support folder (Linux
`moe.senkochan.watch_together`, then `watch_together`, next to the new one;
Windows `%APPDATA%\com.example\watch_together`) is copied in whole
(profiles, logs, shaders, yt-dlp; modes kept, so `cookies.txt` stays 0600;
symlinks as links), and the app's own Hive boxes (`appHiveBoxes`:
`settings`, `connect_form`, `files`, `jellyfin`, `track_prefs`, `.hive`
and `.lock`, by name only, never other apps' boxes there) from the
documents folder, where `Hive.initFlutter()` kept them up to 1.2.x, into
`<app support>/hive`. Copied, never moved (1.2.x keeps working), never
over a file already there. Lines name paths and counts, never contents.
The caches folder (thumbnails, the AniList schedule) is not copied: it
refills.

**Settings schema** (`state/settings_schema.dart`): the `settings` box
stores `schemaVersion`; `migrateSettings` (run when `AppSettings` loads)
applies the ordered `settingsMigrations` steps past the stored version up
to `settingsSchemaVersion`, stamping the version after each. 1 is the
layout of 1.2.x (a box without a version is at 1); 2: auto sit-out
replaces the idle switch; 3: the video volume is kept (`playerVolume`,
100 % when missing); 4: the settings cleanup deletes `controlsHideSecs`,
`unreadyOnSwap` and `autoCheckUpdates` (`droppedSettingKeys`: their
defaults hold; an older build reading the box finds them missing and
uses the same defaults), while `timeDisplay` and `hideReReleases` stay
(the clock's click, the Latest row's menu). A box from a newer build is
left alone. Link media names are a web page's title (see "yt-dlp"), else
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
  same ServerId. `accounts_panel.dart` is the Jellyfin card of Settings →
  Library & accounts.
- `browser.dart`: back stack of `BrowseRoute`s (Home rows, library grid,
  series) kept alive under `Visibility(maintainState)` so back keeps
  scroll and loaded pages; search (300 ms debounce) overlays them. Where
  it is (server, stack, a data version that moves after watched-state
  changes so rows, grids, search and the panel reload in place — a mark
  or Remove from Continue, or `JellyfinAccounts.watched` once a
  playback's Stopped report went out —, the Continue keys) is a
  `BrowseController` shared with the header chips and the details panel.
  It also keeps the watched marks made here (`marked`: an item, or every
  episode of a marked season or show, shows watched or unwatched with no
  resume point at once, for 30 s, while the lists load again; the newest
  mark wins).
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
  drop out unless nothing else is left; "Remove from Continue" hides the
  series (`dismissed:<serverId>` in the `jellyfin` box) until it is
  played again and clears its resume points (the item's, or each of the
  show's in Resume: Jellyfin has no hide-from-resume of its own). "Latest in X" loads single
  items (`groupItems=false`) and `latestCards` makes one series card per
  series (its poster, "S1E1" or "N new"); with `hideReReleases` (the
  row's ⋮ menu, default on) items added over 30 days after they aired are left
  out. "Show all" opens the library sorted by date added, newest first.
- **Jellyfin item actions** (`item_actions.dart`): one list per item kind,
  `jellyfinActions`, read by every place an item shows: the right-click
  menu of cards (Continue, Latest, library grids, search), the show page's
  episode tiles, the panel's episode rows and the show page's season
  chips; the details panel's buttons (Put it up, the queue, the mark,
  Remove from Continue, the show page; compact, one line) and its ⋮
  beside Close (the whole list, so it is the right-click menu); the show
  page's header and the season's buttons.
  Episodes, movies and videos: Put it up (Play alone), Add to queue, Play
  next (in a server), Mark watched or Mark unwatched (by its state),
  Remove from Continue (its show is in the row, or it has a resume
  point), Open the show page (episodes; not while that page is open),
  Copy title, Open in Jellyfin. Shows: the same, with Put it up for its
  next episode and Mark show watched / unwatched (every episode:
  `UserPlayedItems` on the series; asks first, `confirmShowMark`).
  Seasons: Mark season watched / unwatched (no question), the show page,
  copy and open. Libraries and folders: copy and open. Each has its name
  and icon in menus and on buttons. `JellyfinItemActions.run` does them:
  put-up and queue through the Library's callbacks, marks and Continue
  through the `BrowseController` (`setPlayed`, `removeFromContinue`),
  errors under the panel's buttons or as a toast from a menu.
- Picking an item gives a `JellyfinMedia` (serverId, baseUrl, itemId,
  mediaSourceId?, title, subtitle, runtime; no credentials). The library
  remembers the last pick in the `jellyfin` box and puts it up as a ref
  (`putUpJellyfinMedia`, `swapPicked`); your server gets the relay
  credential when it is shared (`relayCredentialFor`: the default
  account, not expired; its token with
  exactly `JellyfinAccounts.clientInfo`'s device fields).
- Browser location: every navigation saves the route stack per server
  (`browse:<serverId>` in the `jellyfin` box, `encodeBrowseStack`: ids,
  names and the fields pages start from), so the library and the next
  start open where the browser was. A `BrowseStart` overrides it: "Change
  video" opens the library on the series of the episode playing, its
  season selected and the episode highlighted.

Player controls (`lib/src/controls/`): one controls model, two skins.
- **Model** (`model/`): `PlayerControlsModel` (built by `SessionPlayer`,
  wired to the coordinator once) holds what the controls show, as
  signals (`play`: `PlayState` playing / waiting (you are ready, the
  others not) / paused / finished, from `state.transport` and your ready
  flag; position, duration, buffered, chapters, current chapter, tracks,
  volume, skip offer, render mode; the shell's fullscreen, chat open and
  unread count) and what they do (`togglePlay` = ready, as Space;
  `seek` through `player.seek`, the user path; `nudge`, `skipForward`,
  `skip`, `stepChapter`, `pickChapter`; `next` = the queue's first item
  (Up next's, else the continuation), else the next episode, `previous`; volume set / step (flashes) / mute;
  `pickTrack`, `pickShader`; the clock's click (elapsed / remaining); fullscreen, chat, change
  video, collapse, leave, reload, mark everyone ready, link). The
  player keys call the same actions. `ControlsSnapshot` (computed) is
  what the layout depends on.
- **Layout spec** (`model/controls_layout.dart`, pure): `ControlsLayout`
  is the bar's order, left cluster play / pause, previous / next episode,
  previous / next chapter, volume, time; right cluster subtitles, audio,
  ⚙ (the player panel, "Player settings"; filled while it is open),
  chat, fullscreen. `barControls` drops what does not apply (no
  episode, no chapters) or what the user hid (`OptionalControl`:
  chapter buttons, subtitles, audio, chat); the rest keep their order, so
  play is always first and fullscreen last. `menuActions` is the top
  bar's ⋯ menu ("Video and session"; `ControlAction`, fixed order):
  change video, copy link (when `currentLink` has one), reload, Skip
  1:30 (with a duration), chapters (with chapters), the hidden track
  lists and chat, mark everyone ready (not alone), mark a problem,
  leave. Icons, tooltips (with keys) and the clock text (`clockText`)
  are defined there too, once.
- **Shared pieces**: `ControlsFrame` (`frame.dart`): when the controls
  are up (real mouse movement shows them, see "Quick chat"; `suppress`
  holds them hidden; 3 s without movement, `hideAfter`, or the
  mouse leaving hides them and the cursor), holds (`hold` during a seek
  drag, `holdDuring` / `holdWhile` around menus and popovers, `holdBy`
  the session's `ControlsHold`), and the double-click on the picture
  (`DoubleClickListener`, not on the bars) that toggles fullscreen; it
  reports `shown` for the overlay. `control_menus.dart`: the track and
  chapter lists and the ⋯ menu on `showAppMenu` (anchored on the button,
  holding the controls), and `runControlAction`. `volume.dart`:
  `VolumeControl` (the skin's speaker button, click mutes; a `VolumeBar`
  beside it whenever the bar has room for it next to every button and
  the Standard clock at its widest, `volumeSliderRoom`; narrower it
  slides out on hover in the room left, or not at all; the wheel on it
  steps), `VolumeReadout`. `SessionControls`
  (`session_controls.dart`) puts the skin the settings pick into one
  frame, live, and gives the overlay the bars' heights.
- **Standard skin** (`standard/`): Material-style. A top gradient with the
  top bar (72 px); at the bottom a gradient with `ChapterSeekBar` (played
  and buffered track in the theme's primary, a diamond at each chapter
  start, hover tip with the time and the chapter title, a press holds the
  frame and every drag move seeks) over a 56 px row of round white icon
  buttons in the layout's order (badges for track counts and unread
  chat, the clock as a text button). Hidden, a 2 px progress line.
- **Minimal skin** (`minimal/`, inspired by uosc, github.com/tomasklaen/uosc,
  LGPL-2.1; the drawing and values are our own): the buttons sit in two
  glass capsules (`MinimalCapsule`, the pills' tint and hairline;
  `MinimalButton` rounded squares, the play button a filled accent
  circle) above `MinimalTimeline`, a 36 px band across the bottom: the
  played part tinted in the theme's primary (40 %), the position a white line,
  the part not downloaded yet (from `buffered`, or the position when
  that is behind, to the end) in thin stripes, chapter starts as dots on
  the top edge with a dark cut through the band (a press within reach of
  a dot jumps to it), elapsed time left and the total or the time left
  right (the bar's clock lives here; a press on its text switches, the
  rest of the band, its end too, seeks), "12s" by
  the position while under a minute is buffered ahead (and the cache does
  not reach the end). Hover: a faint line and a glass tip with the time
  (the chapter title above it). A press seeks, every drag move seeks,
  after release the line stays at the target until the position catches
  up (at most 2 s). Hidden, it shrinks (120 ms) to a 3 px progress line
that is the band itself, smaller: the same dark band, the same played
tint (40 % of the accent), so growing or shrinking never changes colour;
the stripes are stronger on the line (a few pixels of each show) so the
part not downloaded still reads; chapter cuts are a light dark line.
  We know only the end of mpv's cache, so a dropped back buffer is not
  shown.
- **Settings** (`AppSettings`, `model/controls_prefs.dart`, all live):
  `controlsSkin` (`ControlsSkin` standard / minimal; a stored
  `mpvControls: true` from before becomes minimal), `timeDisplay` (set
  by the clock's click), `controlsSize` (normal / large: the bottom bar
  ×1.25), `hiddenControls`, `progressLine`. The player panel has the
  skin, the size and the progress line; Settings → Player → Controls has
  them too and, under More, the bar's buttons.
- Pills (Skip OP / ED / 1:30, Next episode) and cards live outside the
  controls, in the action area ("Player overlay"). The cards stay up; a
  pill (`PillGate`) shows only while the controls are up (the frame's
  `shown`) or the mouse is on it (which holds the controls up too), and
  Skip OP / Skip 1:30 also for 5 s when an offer of a new kind appears
  (Skip ED and Next episode never without the controls).
- Volume: mpv's `volume-max` is pinned to 150 per player by the host
  (`PlaybackController.maxVolume`); the volume is the controller's and
  goes to every next player; it starts at `AppSettings.playerVolume`
  and the controls' `setVolume` (bar, panel, wheel, keys, mute, M)
  stores it there (written 400 ms after the last change); `VolumeBar` runs 0..150 with a tick at 100 and the
  part above in amber; the wheel and ↑ / ↓ step 5 % (`volumeStep`),
  clamped. The wheel works anywhere on the full player (`VolumeWheel`
  around the player's stack): `WheelSteps` makes a mouse notch one step
  and adds up small smooth-scroll deltas, ignores mostly-horizontal
  scrolls, and claims the event through `pointerSignalResolver`, so
  anything under the mouse that scrolls (lists, menus, popovers in their
  own routes) or the volume control itself take it first. A wheel or key
  step flashes `VolumeReadout` (a glass pill under the top bar) for 1 s
  (`VolumeFlash`).
- The `Video` gets the controls as its controls builder (with
  `StartBanner` under them); media_kit's own controls are not used, so
  its keys, double-click route and seek bar are out of the picture.

Window chrome is frameless (`window_manager`, behind `ShellPort`): the party strip is the drag
area and holds the min/max/close buttons (`widgets/window_buttons.dart`,
never focusable);
fullscreen has no drag area and shows the buttons in the player's top bar.

App close (`platform/app_shutdown.dart`, `shutDownApp`; the close button,
Alt+F4, and Update and restart): the window position is saved and the
window hides at once. Then every mpv player goes, before the engine does
(a live one calls its wakeup callback into a dead isolate): the session
player, the preload and the player still retiring
(`MediaPipeline.disposeAll` → `PlayerHost.disposeAll`, 1.5 s each, via
`SessionCoordinator.releasePlayers`, which keeps the position for the
Jellyfin stop report), the Files thumbnail jobs (`cancelAllThumbnails`)
and the sound engine (500 ms), side by side, then anything the host
still holds (the host owns the disposal order); on Windows 300 ms more,
since media_kit_video frees a video output on a thread of its own after
dispose returns, and an output still up when the engine stops blocks the
plugin's teardown (`~VideoOutput` waits on a texture callback that never
comes). Then `Navigation.leave`
(Jellyfin stop report, last diagnostics, then `bye`, flushed: the app
waits up to 600 ms for the server to close the socket, so others see
"left" at once) and your server's stop (`YourServer.stop`), 3 s in all. Update and
restart leaves without `bye` (`shutDownApp(restart: true)`): the member
stays `gone`, and the restarted app, with the same client id, takes it
back within the grace when it joins again; it then closes Hive (the
identity's `seq` is stored) and starts the new binary. Last the window closes the normal
way (`setPreventClose(false)` + `close`), so the engine and plugins are
torn down inside the platform's main loop, and the runners end the
process without `exit()`'s handlers: Linux `_exit` after
`g_application_run` (NVIDIA's EGL exit handler segfaults inside `exit()`),
Windows `TerminateProcess` after the message loop (no DLL detach
handlers, which can hang on threads already gone). Every step is bounded
and logs (`close: ...`) when it is slow or fails. Backstops, so no process
stays behind a hidden window: 20 s after `shutDownApp` starts the app
kills itself whatever it is still waiting for (a step's timeout only
stops waiting, and asking the window to close has none); 3 s after asking
the window to close the
app kills itself (`Process.killPid`, no exit handlers; it only gets there
if the close did not go through); the runners end the process 15 s after
the first close request (Linux: a `delete-event` handler connected before
window_manager's; Windows: the first `WM_CLOSE`), and Windows also 3 s
after the window is destroyed, while the engine and plugins go (only
with an engine: `Win32Window::Create` runs `OnDestroy` before the window
exists, and a timer armed there ended every start at 3 s).

## Logging

`packages/core/lib/src/logging.dart`, one setup for the app and the
dedicated server (`package:logging` loggers named by area: `relay`,
`yt-dlp`, `link`, `server_hub`, `media`, `queue`, `session`, `mpv`,
`app`).

- **Where**: the app writes `<app support>/logs/app-YYYY-MM-DD.log`
  (Linux `~/.local/share/dev.foxyz.starsync/logs`; with a
  profile `<app support>/profiles/<name>/logs`, see `AppDirs` under
  "Desktop UI"); your server's records arrive over the isolate's
  `events` port and go in the same file as `server.<logger>` (`relogLine`). The dedicated server
  writes `server-YYYY-MM-DD.log` in `--log-dir`, else `logs` next to
  `--config`, else `logs` next to the binary (systemd:
  `$STATE_DIRECTORY/logs`), else `~/.cache/watch-together/logs`; it
  prints the folder at start. Both also print every line to stdout.
  The session log (below) sits next to them: your server writes it in
  the app's logs folder, the dedicated one in its log folder.
- **Files** (`LogFiles`): one per day, the next `.1.log`, `.2.log` once a
  file passes 10 MiB; files older than 7 days, then the oldest beyond
  100 MiB in all (the app's or server's files and the session log's
  together, the oldest of either first, never the other writer's file of
  today), are deleted whenever one is opened. A line is
  `2026-10-12 18:44:27.202 LEVEL logger: message`, the error and stack
  trace on the lines below. Writes are synchronous appends (nothing lost
  in a crash). Lines from before the folder is known (the app finds it
  once Flutter is up) are kept and written first.
- **Redaction** (`redactLog`): every line, in one place
  (`formatLogLine`), before console or file: URL query strings cut to
  their parameter names (signed CDN links, Jellyfin `api_key`, an invite
  link's `pw`: `starsync://` counts as a URL),
  `user:pass@` in URLs, member tokens in `/r /m /j /a /i /l` paths, and the
  values of passwords, secrets, tokens, API keys, cookies,
  `Authorization` / `X-Emby-*` headers (`name=value`, `"name":"value"`,
  `Name="value"`, `Name: value`) and `Bearer` credentials. Code logs
  members as `name (id)`, never their token, headers by name only, and
  yt-dlp's cookie source as `--cookies <file>`.
- **Floods** (`LogThrottle`): a few lines per key per 30 s, the next one
  says how many were dropped: mpv's warnings and errors, upstream
  refusals per host and status, each member's media requests per route
  and outcome.
- **What is logged**: the server: joins and leaves, every swap (who, how
  it plays, a link with its query cut), relay channels up and down (who,
  tracks and sizes, how long, the close frame), relay live changes, warm
  relays created, promoted and dropped, server fetches (start, tracks,
  time, failure reason), each member's `/r /m /j` requests (status,
  range, bytes, time to headers: a 503 after 60 s is a source that never
  came up), broken viewer reads, a member's `report.error` as it changes,
  queue ops, and relay stats every 30 s (source rate, need, buffered,
  each reader's rate). The app: `debugPrint` (routed into the log at
  start), uncaught errors, each media opened (relay, the host's file,
  Jellyfin, a link fetched here), mpv's warnings and errors (`mpv`; why a
  media could not be opened, and whether ffmpeg logged an HTTP status),
  probes, yt-dlp runs (arguments, time, exit code, the tail of stderr,
  the picked formats with protocol, host and header names), the relay
  source (media opened and how long it took, channel up and down,
  reconnects, upstream refusals with the header names sent, re-resolves
  of expired format URLs).
- **Crash and freeze evidence** (`platform/crash_watch.dart`, the
  players' lines in `media_kit_host.dart`): a native crash (mpv, the
  video output) ends the process without a Dart line, so the app leaves
  its own trail. Each session or preload player logs `player #N <role>:
  created | setup done | promoted | open | first frame WxH | dispose
  start | dispose end (<age> ms, live <n>)` (logger `player`; no media
  name) and has the waiting diagnostics sent at once
  (`DiagUploader.flushAllSoon`, at most one post per 2 s, the rest at the
  end of that gap), as does the start of the close. `running.json` next to
  the logs folder (`<app support>`, or the profile's) is written at start (version, time, pid), gets
  `closing` when the close starts and `quit` once the close is done
  (only the window and the engine's teardown are left); a start that
  finds it without `quit` logs `previous run ended without a clean
  close[, while closing]: <version>, started <time>, pid <pid>` (logger
  `crash`). On Windows that start also reads the Application event log
  (`wevtutil qe Application ... /f:xml`, events 1000/1001/1002 of the
  last 3 days, 5 s at most, in the background; `starsync.exe` and the
  1.2.x name `watch_together.exe`) and logs the app's records; after a
  run with `quit` it logs only records newer than that (`windows crash
  record while quitting: ...`, a crash in the teardown). Records read
  `windows crash record: crash (1000) at <time>
  version=... module=... exception=... offset=...` (the event data, not
  the localized description; no paths). Lines logged out of a session
  this way (`DiagUploader.carry`) wait for the next session's first
  batch. A 1 s timer logs `event loop stalled: the 1 s timer fired N s
  late` past 3 s (the UI isolate was blocked, or the machine slept) and
  sends at once: a freeze, not the network.
- **Never logged**: chat text (the server relays it without a log line,
  the app does not log it), and no user-typed free text other than a
  problem mark's note. Names, media titles and links (query cut) are.
- **The session log** (`packages/server/lib/src/session_log.dart`,
  `packages/core/lib/src/diag_share.dart`): one shared log per server so
  a problem can be read afterwards from every side. While in a session
  the app (`DiagUploader`, owned by the `Connection`) keeps its own
  records (not your server's `server.*`, which the server logs
  itself), redacted, and sends them every 10 s from the connection's 1 s
  heartbeat and when it leaves (before its token goes, at most 1.5 s), as
  gzip batches to `POST /l/<sid>/<token>` (PROTOCOL
  "Diagnostics"), timestamps moved to the server's clock with the ping
  offset (`ClockSync`), the app version in every batch. Until it can
  send (reconnecting, no clock sample yet) it keeps up to 2 MiB, the
  oldest dropped and counted. The server (`SessionLog`) takes every
  member's lines and its own records, holds them 15 s and writes them in
  server-time order to `session-YYYY-MM-DD.log` (day and time on the
  server's clock; a line later than that, a reconnect's backlog, goes in
  with its own time, a little out of order). A line is
  `HH:MM:SS.mmm [who] logger: message` (`LEVEL logger` from WARNING up),
  `who` = `name (id)` or `server`, continuation lines indented; every
  line is redacted again on the server. The server notes once per member
  `Bob (m2) shares diagnostics (<version>)` or `Bob (m2) doesn't share
  diagnostics`, and `N lines dropped` when the app's buffer overflowed.
  Limits and rate caps: PROTOCOL "Diagnostics"; a refused batch stays in
  the app's buffer for the next try.
- **Opting out**: Settings → Help & about → "Share diagnostics with the
  server" (default on). Off: no lines are kept or sent; one batch per
  connection says so (`share:false`), and problem marks still go. The
  local log is unchanged.
- **Mark a problem**: Ctrl+Shift+B (`AppKeys`), the player's ⋯ and panel, and
  Settings → Help & about open a small card with an optional note (200
  characters, one line); the mark goes at once with the lines waiting,
  opted out or not, and the server writes `[who] === PROBLEM marked by
  <name>: <note> ===` at its time. The app's own log gets
  `=== PROBLEM marked: <note> ===` (logger `problem`, never sent). Out
  of a session only the app's log gets it. The toast says which.
- **Getting it**: Settings → Help & about → "Copy diagnostics" puts the app and
  OS versions, mpv/ffmpeg and yt-dlp versions, whether yt-dlp has
  cookies, and the last 6 hours of the log (up to 4 MiB) on the
  clipboard, already redacted, and saves the same text as
  `diagnostics-<time>.txt` in the logs folder (kept 7 days); "Open logs
  folder" opens it. In a session it first asks whether to add the
  server's session log of the same 6 hours (`GET /l/...`). Any member
  may read the session log, not only the host: friends trust each other,
  and it is redacted and holds no chat.

## Health reporting

Every failure must show in the UI with a cause and a next step; nothing
stalls silently. The session's status (`SessionCoordinator.status`, see
"App events and platform ports") says it: connecting, reconnecting, wrong
password, version mismatch, replaced, the player's problems, the relay's
source and who everyone waits for.
Errors are logged with a stack trace at the boundary, then turned into a
displayable state. The server's `GET /health` returns JSON (`ok`, `name`,
`proto`, `viewers`, `bytesServed`, `uptimeSecs`); it is unauthenticated, so
it carries nothing sensitive. The Join card's recent servers poll it for live
status.

## App icon and launcher entry

`assets/icon/icon.svg` is the source; `icon_<size>.png` and the Windows
`app_icon.ico` are rendered from it (rsvg-convert, magick). The GTK
application id is `dev.foxyz.starsync` (also the X11 `WM_CLASS`, from
`g_set_prgname`), which Wayland uses as the window's `app_id`; compositors
take the icon from the `.desktop` file of that id. A tarball install has
none, so on start a Linux release build (`platform/desktop_entry.dart`,
skipped in debug) writes
`~/.local/share/applications/dev.foxyz.starsync.desktop` (Exec = the
running binary with `%u`, `StartupWMClass` and `Icon` = the id,
`StartupNotify`, the `starsync://` link type: "Link handler" under "App
events and platform ports") and the icons into
the hicolor theme, only when they changed, and deletes the entry and
icons 1.2.x wrote under its id `moe.senkochan.watch_together` (those exact
files only). The runner also sets the window icon from the bundle (X11).
Windows: the exe's version resource (`windows/runner/Runner.rc`) says
company `foxyz`, product `Starsync`; the window class is
`STARSYNC_WINDOW`.

## Updater

One implementation, `packages/core/lib/src/updater.dart` (pure Dart, tested
in `packages/core/test/updater_test.dart`), with two front ends: the app and
the dedicated server. Both binaries ship in the same archive, so either one
updates the whole install folder. Reads a manifest (`version`, `protocol`, `url`, optional `sha256`, `notes`,
optional `changes`) from `updateManifestUrl`, compares versions, downloads the tarball, checks
sha256 when present, then extracts into a staging dir inside the install
folder (same filesystem, so moves are renames; the folder must be
user-writable). Each top-level entry is moved aside and the new one moved in,
with rollback on failure (writing the running executable fails with ETXTBSY;
rename works). A packaged install is detected by `data/` and `lib/` next to
the binary (app or server, same folder; Windows: `data/` and
`flutter_windows.dll`), whatever the binary is called; anything else exits
with "update manually". The archive (`starsync-<ver>-<platform>`, top
folder `starsync-<ver>/`) must contain the running binary's name; an old
name (`watch_together`, `watch-together-server`, `.exe` on Windows: the
names up to 1.2.x) is also satisfied by the new one (`starsync`,
`starsync-server`). **Names before the rename**: archives up to 1.4.x
also carried those names (Linux launchers, Windows copies); none does
now. `removeOldNames` deletes each, with its `.old` copies, from the
install when its new binary is next to it (a running one, an app
started from an old shortcut on Windows, is renamed to `.old` instead,
swept on a later start), and never fails the update. It runs after a
successful apply and in `cleanupUpdateLeftovers` (each update check of
the app, and before `--upgrade` applies): a 1.4.x updater swaps in only
what the archive has, so the update away from 1.4.x leaves the old
names for the new version's first check to remove. After an update the
app restarts `relaunchExecutable(...)`: the running binary, or for an
old name the new one next to it. `update.sh` / `update.bat` run
`starsync-server`. A manifest whose
protocol is newer than the local one is a required update. Windows apply
renames in-use files to `*.old` (swept on next start); CI tests it against a
running exe on NTFS. The manifest's `assets` maps `linux-x64` /
`windows-x64` to archive URLs; top-level `url` (Linux) is for builds <= 0.2.1. The version is
stamped into both binaries with `APP_VERSION` (`--dart-define` for the app,
`--define` for `dart compile exe`; dev runs report `0.0.0-dev` and the app
skips checks). What the app shows (`displayVersion`, `screens/home/ui.dart`;
About and the tooltip of the strip's Settings tab): a release's version,
a test build's with its commit (`GIT_COMMIT`, short hash, `-dirty` with
uncommitted changes, passed by `tool/package_linux.sh`), and for a dev
run the pubspec's version (`FLUTTER_BUILD_NAME`, which the Flutter tool
defines for every build and run) with "dev run". CLI: `starsync-server --upgrade` (no display needed;
the shipped `update.sh` / `update.bat` run it), `--check-update` prints only;
it ends with "restart the server to run <version>". `starsync --upgrade`
does the same from the app binary. In the app, `UpdateController`
(`apps/desktop/lib/src/update/`) runs the same code for the update bar
(`UpdateBar`, `screens/home/update_indicator.dart`): a band across the
window under the strip while an update is available: "Starsync X.Y.Z is
ready", the first three changes (each with its kind's icon; the notes
when the manifest has no `changes`), What's new, Later (hidden until the
next check or start) and "Update and restart" (download, apply, then the
app close above with Hive closed and the new binary started), its
progress in the band. A release
that is behind also says which version it runs; a copy that is not a
packaged install says to replace the folder by hand. The shell keeps the
band off the full player while a video is on (not finished); it shows on
the tabs, the mini player's views and once the video ends. A required
update has no Later. Nothing downloads before the click. The app checks at
start and every 4 hours while running (`updateCheckEvery`), always (D8:
nothing installs without asking); a re-check never touches an install
under way. Settings → Updates has Check now. The manifest is `updates/manifest.json` in
this repo, written by `tool/release.sh`.

**Update channel.** `UpdateChannel` stable or dev, the setting
`updateChannel` (Settings → Updates → More, "Update channel", which also says
the channel and version running). Dev also reads `devManifestUrl`, the
`manifest.json` of the `dev` prerelease (`tool/dev_release.sh`), and takes
the newer of the two by semver (`pickManifest`, `fetchLatestManifest`): a
release 1.4.0 is offered over 1.4.0-dev.3, and after it 1.4.1-dev.1 is,
the install staying on Dev. Stable reads only the stable manifest. Never
chosen, the channel is `defaultUpdateChannel`: dev for a test build
(`X.Y.Z-dev.N`, `isDevBuild`), else stable; a test build stores dev on its
first start, so the release that later updates it stays on Dev (stable by
default is not stored). A file `update-channel` next to the binary (`dev`
/ `stable`, written by the one-time command `tool/dev_release.sh` prints)
is taken as the channel at the next start and deleted. Switching the
setting re-checks at once. On stable in a test build, a release older than
the build (`isStableBehind`) is never offered by itself
(`UpdateController.stableBehind`, "Stable is at X, older than this test
build"); switching to Stable there asks "Go back to stable X?": going
back installs it (`goBackTo`), staying keeps the build until a newer
release. `--upgrade` uses the default channel of the binary's version.
`0.0.0-dev` (a dev run) checks nothing.

**What's new.** The manifest's `notes` is one line (all 1.2.x and 1.3.x
read; they ignore other keys) and `changes` (`{"added": [...], "changed":
[...], "fixed": [...]}`, `ReleaseChanges`, read leniently: anything
malformed is no `changes`) the version's lists; both come from
`CHANGELOG.md` ([Changelog](DEVELOPMENT.md#changelog)). The card
(`WhatsNewCard`, `widgets/whats_new_card.dart`) shows them as Added /
Changed / Fixed sections, each with its icon and colour, on `AppGlass` in
a popover, the rows easing in one after another, the list scrolling in a
short window; notes alone show as one paragraph. Three ways open it: the
band's What's new (the offered version, with Update and restart), the
first start of a new version, and Settings → Help & about ("What's new in X.Y.Z",
once this version's notes are known). The first start (`WhatsNew`,
`update/whats_new.dart`): before restarting, the update keeps the new
version's notes in settings (`UpdateController.beforeRestart`); an update
made otherwise (1.3.x's updater, `--upgrade`, by hand) gets them from the
first check whose manifest is this very version (`UpdateController.latest`).
The card shows once per version (`whatsNewSeen` in settings), never on a
fresh install (the settings box was empty), and not over the full player
while a video is on (it waits until the video ends or the player
leaves full).

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
  poster cap when larger; else the AniList entry `media.ref` names (a
  matched local file), else an AniList title search on the parsed
  release name) and sends `art`, so guests without Jellyfin get covers too.
  `coordinator.nowPlaying` derives title, episode line and art hashes from
  `state.media` (`now_playing_info.dart`); a non-Jellyfin media with a
  `media.ref` is named by it (its title, `S3 E13` / `E108`, an extra's
  own marker), see "Library". A web video
  (`NowPlaying.thumbnail`) shows the media name as is, no episode line, a
  16:9 cover in the controls (a neutral placeholder until the art is up)
  and none on the start card. Art up: poster and banner of one hash mark
  it. Before the art: `isWebVideo` tells it from the media itself (an
  http(s) `url` without a media file extension, or a relayed, non-Jellyfin
  media whose name has no file extension: a page's title), so the layout
  never switches when the thumbnail lands.
