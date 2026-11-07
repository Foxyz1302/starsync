# Protocol (proto = 17)

Wire format only. Behavior (gate, clock, timeouts) is in
[ARCHITECTURE.md](ARCHITECTURE.md). Source of truth:
`packages/core/lib/src/protocol.dart` and `packages/server/lib/src/server_hub.dart`.

Any wire change bumps `RelayConstants.protoVersion` and edits this file in
the same commit. Versions are ranges: a server accepts
`[protoMin, protoMax]` (`RelayConstants.protoMin` / `protoMax`, both 17
today), a client sends its own range (`hello.protoMin` .. `hello.proto`),
and the connection uses the highest version both have (`welcome.proto`).
Later additions raise `protoMax` only, so they stay additive. Fields
marked **reserved** are parsed and documented but nothing produces them
yet; the restructure step named next to them does.

## Transport

- WebSocket at `/sync`, JSON text frames, each an object with a `t` field.
- The first client frame must be `hello` within 10 s. Server pings every 5 s.
- Match incoming frames by `t`, never by order: `welcome` can race `state`.
- A socket without any frame from its client for 15 s
  (`RelayConstants.silenceSecs`) is closed by the server (close code
  4015) and its member is `gone` (see "Presence"). Clients send a
  `report` every second and a `ping` every second anyway.
- Failures: `err` (see "Errors and close codes"); a refused `hello` is
  followed by a close.
- `GET /health` returns JSON (unauthenticated, no member names): `ok`,
  `name`, `proto` (= `protoMax`), `protoMin`, `protoMax`, `version` (the
  server's app version, e.g. `1.3.0`), `tls` (**reserved**: always false;
  a server with TLS would serve the same endpoints over `wss://` /
  `https://`), `viewers`, `bytesServed`, `uptimeSecs`. The app reads it
  before joining and does not dial a server whose range does not meet its
  own (the version gate, see ARCHITECTURE "Server lifecycle").
- `GET /m/<sid>/<token>/<name>` serves the host's file (Range table in
  ARCHITECTURE.md). `GET /j/<sid>/<token>/<itemId>` relays the current
  Jellyfin media and Up next's first one (see "Jellyfin media" below).
  `/r/<sid>/<token>/...` is the relay of a member's media (see "Relay"
  below). `GET /a/<sid>/<token>/<hash>` serves a member's picture (see
  "Avatars" below), `GET /i/<sid>/<token>/<hash>` the current media's art
  (see "Media art" below). `POST` and `GET /l/<sid>/<token>` send and read
  the session log (see "Diagnostics" below). A token works from the
  member's `welcome` until it leaves (through its grace, see "Presence").

## Errors and close codes

```
{"t":"err","code":"version","min":17,"max":17,"server":"1.5.0","for":"hello",
 "message":"proto mismatch: got 16, want 17..17"}
{"t":"err","code":"bad","for":"seek","message":"bad message: position must be finite"}
```

- `message` is plain text for people; a proto 15 app shows it as is (the
  version refusal starts with `proto mismatch:` for that reason). `code`
  is for programs; `for` names the `t` of the frame that failed, when
  there is one. With `code` `version`: `min`/`max` the server's range,
  `server` its app version. This shape is stable from proto 16 on.
- Codes: `version` (no common version), `secret` (`wrong secret`),
  A 1.4.x app (proto 16) gets this refusal and says "the host runs a newer
  Starsync — update the app" (its `/health` gate says the same first).
  `rejected` (understood but refused: `rejected: avatar too large`,
  `server fetch needs a server password`, `The server can't fetch this
  link: ...`), `bad` (malformed: `bad hello: ...`, `bad message: ...` for
  a frame with a non-finite number or a bad queue item, `bad swap media`,
  `swap needs a url or the hosted file`, `relay fetch needs an http(s)
  url`), `replaced` (another hello of the same client took the member
  over; the client stops, "opened in another window"), `stale` (this hello
  is older than the member's current one), `forbidden` (`presence` `in` or
  `afk` for someone else; an `auto` queue item from someone else than the
  swapper),
  `rate` (**reserved**; nudges over the cap are still dropped silently),
  `full` (`Up next is full (100 items)`).
- After `err` the socket stays open, except at `hello` and for
  `replaced`, which are followed by a close.
- Close codes (the server's; constants: `CloseCodes` in core):

| Code | Socket | Meaning |
|---|---|---|
| 1000 | `/sync` | the member left (`bye`, or its grace ran out) |
| 4001 | relay channel | not (or no longer) the source of this relay; the source stops |
| 4002 | relay channel | the source is back with another media than the relay's first `info`; the relay ends, the source stops |
| 4003 | relay channel | a newer channel of the same source replaced this one; this one stops |
| 4010 | `/sync` | refused: `err` `version` |
| 4011 | `/sync` | refused: `err` `secret` |
| 4012 | `/sync` | refused: `err` `bad` or `rejected` at `hello` |
| 4013 | `/sync` | `err` `replaced`: another connection of the same client holds the member |
| 4014 | `/sync` | refused: `err` `stale` |
| 4015 | `/sync` | silent for 15 s: the member is `gone` |
| 4016 | `/sync` | the hosting app stopped sharing its server: the member has left (`leave`, reason `closed`); the client does not reconnect |

## Client to server

```
{"t":"hello","protoMin":17,"proto":17,"secret":"","user":{"name":"","avatar":"","color":"#7e57c2"},
 "media":{},"hostKey":"...","client":"<install id>","seq":7,"app":"1.3.0",
 "platform":"linux","caps":{"source":true,"resolve":true,"jellyfin":true},
 "feedAfter":41}
{"t":"play"}
{"t":"pause"}
{"t":"presence","target":"<memberId>","state":"in"|"brb"|"afk"|"out","reason":"minimised","resume":true}
{"t":"continue","target":"<memberId>"}
{"t":"seek","position":123.4,"seq":3}
{"t":"swap","media":{"name":"","size":0,"duration":0,"url":"..."}}
{"t":"swap","media":{"name":"","size":0,"duration":0,"jellyfin":{<ref>}}}
{"t":"swap","media":{"name":"","size":123,"duration":0,"url":"...","relay":{}}}
{"t":"swap","media":{...},"queueId":"q3"}         puts up an Up next item
{"t":"swap","media":{...},"restore":{"position":512.3,"transport":"playing"}}   puts back what played (see below)
{"t":"report","position":123.1,"buffered":6.2,"eventId":41,
 "duration":1440.5,"mediaId":2,"jf":{"<serverId>":true},"error":"Not allowed (403)"}
{"t":"ping","c":1767225600000}
{"t":"chat","text":"..."}
{"t":"bye"}
{"t":"nudge","target":"<memberId>"}
{"t":"profile","name":"...","avatar":"<base64>","color":"#7e57c2"}
{"t":"art","mediaId":2,"poster":"<base64>","banner":"<base64>"}
{"t":"queue","op":"add"|"move"|"remove"|"play"|"skip"|"cancel",...}   see "Queue"
```

Field notes:
- `hello.proto` / `hello.protoMin`: the client's version range
  (`protoMin` absent: `proto` only). The server reads them before
  anything else in the hello (a hello of another version may not parse)
  and refuses with `err` `version` when the ranges do not meet.
  `hello.media` is ignored; a client still sends `{}` so a proto 15
  server, which requires it, answers with its own `proto mismatch`.
- `hello.secret`: the server password; a server with an empty secret is
  open. The password may change while members are in (the hosting app
  sets it when it opens its server to friends).
- `hello.hostKey` (optional, omitted when empty): the hosting app
  generates a random key per run, gives it to its server and sends it
  from its own client. The member whose key equals the server's is the host
  (`members[].host`), and its hello needs no `secret`. A server without a
  key (the dedicated server) has no host. Where the connection comes from
  does not matter.
- `hello.client` (optional): a random id per install, 16 to 64
  characters of `[A-Za-z0-9_-]` (the app uses 22 characters of
  base64url), else `err` `bad`. Private: never broadcast, never logged.
  It names the member across connections (see "Presence"); without it
  every hello is a new member. **Reserved**: deriving it per server (an
  HMAC of an install secret and the dialled host:port).
- `hello.seq` (default 0): increases with every connection this install
  makes. A hello whose `seq` is lower than the one holding the member
  gets `err` `stale` and is closed; equal or higher takes the member over.
- `hello.app` (the app version, cut to 32 characters): shown as
  `members[].app`. `hello.platform` (`linux`, `windows`, `macos`,
  `android`): logged only. `hello.caps`: what the app can do (`source`:
  serve a relay; `resolve`: run yt-dlp; `jellyfin`: play with its own
  account), shown as `members[].caps`; unknown entries are ignored.
- `hello.feedAfter` (optional): the last `feed.seq` the client saw from
  this server; `welcome.feed` replays the lines after it. A client should
  send it only for the same `welcome.instance` (a restarted server counts
  from 1 again).
- `seek.seq` (optional, default 0): increasing per client; echoed in
  `state.seekSeq` so the sender recognises its own seek.
- `report.duration` / `report.mediaId` (optional, omitted when 0): the open
  media's length in seconds and the `mediaId` it belongs to. The server takes
  the first one whose `mediaId` is current while its media duration is 0.
  `report.buffered` is the current media's: a client sends 0 while its
  player does not hold it yet, and the server counts a report whose
  `mediaId` names an earlier media as `buffered` 0. A `loading` member's
  report ends its loading once it holds the current media at the server
  position (within 5 s) with the buffer the group needs (see "Presence");
  its position is where its player is (an `out` member's spot).
- `report.jf` (optional): Jellyfin access per `ServerId`, `true` = this
  client plays the item with its own account, `false` = through the relay.
  Sticky: a report without `jf` keeps the last one. At most 8 entries, keys
  up to 64 characters; others are dropped. The reference client lists
  every server it has a working account on as `true`, then the current
  item's server as it plays it (so a queued Jellyfin item finds someone
  to put it up while other media plays).
- `report.error` (optional, omitted when empty): short plain text saying
  why this client's player cannot open the media `report.mediaId` (e.g.
  `Not allowed (403)`). The client sends it in every report while that
  lasts and drops it once the media opens (a reload included). The server
  keeps it per member (one line, cut to 120 characters) only for the
  current `mediaId`: a report without it, or for another `mediaId`,
  clears it, and so does a swap. The group never waits for an errored
  member's video; once the error clears it does again. It also ends a
  `loading`.
- `ping.c`: the client's clock in epoch ms; answered with `pong`.
- `user.avatar`: base64 PNG, at most 256 KiB of characters (else
  `rejected: ...`). `name` is trimmed, empty becomes `?`, cut to 32
  characters. `user.color` (optional): the colour picked in the profile,
  `#` and six hex digits; the server keeps it in lower case, and anything
  else (absent, malformed) counts as none. A takeover applies the hello's
  name, picture and colour like a `profile`.
- `profile`: changes this member's name, picture and/or colour
  mid-session. A field that is absent (or null) stays as it is;
  `avatar: ""` removes the picture, `color: ""` (or a malformed colour)
  the colour. Same rules as `hello.user`; a too large avatar gets `err`
  `rejected: avatar too large` (the socket stays open, nothing changes).
  A colour change shows in `state` only (no feed line).
- `art`: pictures of the current media (see "Media art").
- `chat.text` is cut to 500 characters.
- `play` / `pause`: the group's wish (`state.wish`), anyone's. A pause
  holds at once where it is, and during the countdown to Up next stops it
  at the end; a play starts once nobody is waited for (see "Presence").
- `presence`: `target` a member id (absent or empty: oneself), `state` its
  new standing (see "Presence"). `brb` and `out` on anyone ("Wait for
  Bob", "Don't wait for Bob" is `continue`); `in` (back from BRB, or in
  from AFK or out at the current moment) and `afk` only on oneself, else
  `err` `forbidden`. `afk` is ignored while playing and on a BRB member.
  `resume` (with `brb`, from oneself, the first BRB only): the group was
  playing when this press began (the client paused on key-down first),
  so it wants to play again once the last one is back. `reason`
  (`manual` default, `minimised`, `closed`) goes into the feed line.
  Unknown targets and no-op changes are ignored.
- `continue`: continue without `target` (a member id), or, without one,
  without everyone the group waits for, and then the group plays (its
  wish becomes play). A BRB member becomes `out` (feed reason
  `continue`); someone whose video holds the group stays `in` and
  catches up (it is not waited for until its `loading` ends). Without a
  target it also brings the sender back from its own BRB.
- `bye`: the member leaves now (the Leave button, the app closing): feed
  `leave` (reason `bye`), its token stops working, the socket closes
  (1000). Anything else that ends a socket keeps the member (`gone`),
  except the hosting app closing its server to friends: everyone but the
  host leaves at once (feed `leave`, reason `closed`) and the socket
  closes with 4016.
- `nudge`: the server sends `{"t":"nudge","from":<memberId>,"name":<name>}`
  to `target` only (no feed). At most 3 per second and 20 per minute per
  sender; the rest, nudges to oneself and to unknown targets are dropped
  silently.
- `swap.media.url` is the link; `name`, `size`, `duration` are informational.
  `swap.media.jellyfin` makes it Jellyfin media (see below); then `url` is
  dropped. `swap.media.relay` makes it relayed media (see "Relay").
  `swap.media.ref` says what it is (see "Media identity"). A swap keeps
  the group's wish and everyone's standing (BRB, AFK and out stay): the
  new media plays once every watched video has it if the group wanted to
  play.
- `swap.restore`: what played before the server restarted, offered back
  by a member that still holds it (`position` seconds, `transport`
  `playing`, `held` or `finished` as it was). The server takes it only
  while it has no media; any later one is ignored, so the first offer
  wins. It is a swap otherwise (relays, art), held at `position`
  (`finished`: at the end; `playing`: the group's wish becomes play), its
  feed `swap` line with `reason` `restore`.
- Frames before `welcome` (other than `hello`) are ignored; unparsable or
  unknown frames are ignored silently. Frames
  from a socket another hello took over are ignored.

## Server to client

```
{"t":"welcome","proto":17,"token":"...","memberId":"m1","resumed":false,
 "instance":"<random per boot>","grace":600,"mediaUrl":"...","relayUrl":"...",
 "state":{<state>},"feed":[<feed with "replayed":true>,...],
 "animeFlow":"https://anime.example.org/api/app/v1"?}
{"t":"state","eventId":7,"transport":"playing"|"held"|"finished","position":12.3,
 "serverTime":"<ISO-8601 UTC>","mediaId":1,
 "media":{name,size,duration,url?,jellyfin?,relay?,ref?,swapBy?,art?}|absent,
 "members":[{"id","name","avatarHash"?,"color"?,"buffered","presence","since"?,"loading"?,
   "goneSince"?,"jf"?,"host"?,"error"?,"rate"?,"app"?,"caps"?}],
 "seekBy":"m1","seekSeq":3,"relay":true,"relayNext":true,"queue":[<item>]?,
 "queuePlay":"q3"?,"queuePass":["m2"]?,"wish":"play"|"pause",
 "hold":{"brb":["m2"],"video":["m3"],"source":true}?,
 "advance":{"id":"q3","at":"<ISO>","secs":10}?}
{"t":"pong","c":1767225600000,"s":1767225600012}
{"t":"feed","seq":12,"actor":"","actorId":"m2","action":"","target":"","targetId":"m3",
 "reason":"","at":"<ISO-8601>","missed":102?}
{"t":"chat","text":"...","from":"<name>","fromId":"m2"}
{"t":"nudge","from":"m2","name":"Alice"}
{"t":"err","code":"...","message":"...","for":"..."}
```

- `welcome.token` is private to its owner and appears only in that member's
  media URL. `mediaUrl` is omitted when there is no media; it is a built
  `/m/...` URL for a host file (host part = what the client dialled), otherwise
  the shared link.
  `welcome.state` has the same shape as `state`. `relayUrl` is present only
  when `state.relay` is: this member's `/j/...` URL for the current
  Jellyfin media (private like `token`). `welcome.proto`: the version of
  this connection. `welcome.resumed`: the hello took over this client's
  member (same `memberId` and `token`, everything it had kept); false for
  a new member, also after a server restart. `welcome.instance`: random
  per server boot (a client that held a member of another instance knows
  the server restarted, not that its grace ran out). `welcome.grace`:
  seconds a `gone` member is kept. `welcome.feed` (omitted when empty):
  the feed lines after `hello.feedAfter`, at most the last 50, oldest
  first, each with `replayed: true` (log them, do not toast them).
  `welcome.animeFlow` (omitted when the server has none): the AnimeFlow
  app API address of the server's config (`animeFlow`), for the
  Schedule's statuses and requests (see ARCHITECTURE "Desktop UI",
  Schedule).
- `state` is sent every second and on every change. `position` is the value at
  `serverTime` (server clock); clients extrapolate while `transport` is
  `playing`, on the server's clock (see `pong`). `finished`: the media
  reached its end (`position` = duration); it stays until a seek or swap.
  `eventId` increases on seek, swap and transport changes.
  `mediaId` increases on swap. `media.relay` is present for relayed media
  (see "Relay"). `media.duration` is 0 until a client reports
  it. `media.swapBy`: member id of who swapped it in (omitted once that
  member left, and for the media the server started with). `media.art`:
  see "Media art". `media.ref`: see "Media identity". `seekBy` (member id)
  and `seekSeq` are present only while the current
  `eventId` came from a seek. `relay` (omitted when false): the server can
  relay the current Jellyfin media. `relayNext` (omitted when false, proto
  13): it can relay Up next's first item too (a Jellyfin ref on the same
  login), so viewers without access preload it from `/j`. `members[].jf` is the member's last
  `report.jf`, omitted when it never sent one. `members[].avatarHash`
  (omitted when the member has no picture) names the picture's bytes (see
  "Avatars"). `members[].color` (omitted when none): the member's
  `user.color`, `#rrggbb` in lower case; a client shows the member in it,
  and picks one from the name when it is absent. `members[].host`
  (omitted when false): the member sent the server's `hostKey` (see
  `hello.hostKey`). `members[].presence`, `since` (ISO, when it began;
  omitted for `in`), `loading` (omitted when false) and `goneSince` (ISO,
  only while disconnected): see "Presence".
  `members[].error` (omitted when
  empty): the member's player cannot open the current media (see
  `report.error`). `members[].rate` (omitted when 0): bytes per second
  the server sent this member over the last 5 s (`/m`, `/j` and `/r`
  together), two significant digits, under 10 kB/s counts as 0. Members
  that fetch the media themselves read nothing from the server.
  `members[].app` / `caps` (omitted when empty): its `hello.app` /
  `hello.caps`.
- `state.wish`: the group's wish, `play` or `pause` (see "Presence").
- `state.hold` (present while `held` with media up and someone is waited
  for): `brb` the BRB members (whatever the wish: "Paused · waiting for
  Bob" when it is `pause`), `video` the members whose video holds the group
  (only while the wish is `play`: still `loading`, or a buffer short of
  `bufferNeed`), `source` (true: a relayed media's source is `gone`, the
  short buffers are its doing). Each list is omitted when empty.
- `state.advance` (omitted when none runs): the shared countdown to Up
  next's first item over the media's last 10 s (see "Queue").
- `pong.c` echoes the ping's `c`; `pong.s` is the server's clock in epoch ms
  (the clock `serverTime` uses). With `t3` the local receive time, the offset
  is `s - (c + t3) / 2`, accurate to half the round trip.
- `feed`: `seq` increases by one per line for the server's life (a
  restart counts from 1 again); `actor` / `target` are display names as
  they were then, `actorId` / `targetId` the member ids (`server` for the
  server's own lines; omitted when none): match people by id, not by
  name. `action` values: `play`, `pause` (`server` as actor when the group
  waits for a video that ran dry), `resume` (by `server`: the wait is over
  and it plays), `brb` (`target` the member set BRB, absent when the actor
  set itself), `back` (back from BRB), `afk`, `out` (`target` as for
  `brb`; `reason` `minimised`, `closed` or `continue`), `in` (back from AFK
  or out), `continue` (`target` the one member, absent for everyone),
  `join` (a new member only), `leave` (for
  good: `reason` `bye`, `grace` or `closed`), `gone` (10 s after the member went
  `gone`; a quicker return says nothing), `return` (back within the grace
  after a `gone` line; `missed`, omitted when under 10 s: the seconds of
  the video that played since it dropped while it was in, none after a
  seek meanwhile), `swap`, `seek`, `finished`, `chat`, `rename`,
  `avatar`, `queue-add`, `queue-remove`,
  `queue-skip` (actor `server` when the server skipped it), `advance-cancel`
  (`target` the dropped continuation's title, if any), `fetch-fail` (the server could not fetch the current
  media, `target` its name). `reason` carries `restore` for a swap that
  put back what played (`swap.restore`).
  `rename`: `actor` is the new name, `target` the old one. `avatar`: the
  actor changed only the picture. `queue-*`: `target` is the item's
  title, `reason` (skip) why it could not play (see "Queue").
- Chat is delivered twice: a `chat` frame with the text (`fromId` the
  sender's member id) and a textless `feed` with `action:"chat"`. Render
  the `chat` frame only; the reference client drops the textless feed
  entry.

## Presence

The member is lasting: one per client, kept across reconnects. The
behavior in full: ARCHITECTURE.md, "Sync model".

- The server maps `hello.client` to one member. A hello with a known
  client id (and a `seq` not older than the member's) takes that member
  over: `memberId` and `token` stay, so `/m` `/r` `/j` URLs keep working;
  its standing, queue items, relay, picture all stay; an older socket
  still open gets `err` `replaced` and closes (4013). `welcome.resumed`
  is true.
- A socket close (or 15 s of silence) is not a leave: the member is
  disconnected (`goneSince`) and kept for the grace, 10 min
  (`welcome.grace`), with everything it had; a relay it serves goes on
  (see "Relay"). After the grace it leaves (feed `leave`, reason `grace`),
  its token stops working; a hello with its client id after that is a new
  member. `bye` leaves at once.
- `members[].presence`, one each:
  - `in`: watching. The group waits only for its video.
  - `brb`: set on purpose (by itself, or by someone else: "Wait for
    Bob"); the group waits until it is back (`presence` `in`) or someone
    continues without it (`continue`: it becomes `out`). Never runs out;
    kept while disconnected (still waited for), across a takeover and a
    swap; a client reports it again after a non-resumed welcome. A BRB
    member who leaves for good leaves a plain pause: when it was the last
    one, the wish becomes `pause`.
  - `afk`: out, set by the member's own app (no input for a while with
    nothing playing); counts exactly like `out`.
  - `out`: not waited for, not counted as watched; its player stays at
    its spot (its reports say where). Back `in` it loads at the current
    moment. It never stops the member passing the video on.
- `members[].loading` (a label): with media up, a new member, one back
  from a drop, one back `in` from `afk` or `out`, and one someone
  continued without, until its report holds the current media at the
  server position (within 5 s) with `bufferNeed` buffered, or reports an
  error. While the group plays a loading member is never waited for (it
  comes in already in sync); while it is held and wants to play, its
  video is, without a time limit (`continue` goes on without it).
- The group plays when its wish is `play`, nobody is `brb`, and every
  watched video (`in`, connected, no player error, not continued
  without, and not loading while playing) has `bufferNeed` buffered.
  While playing, a watched video short of it holds the group (feed
  `pause` by `server`) until it has it again (`resume`). Nothing starts
  because time passed: a fresh server's wish is `pause`.
- What a standing counts for besides the group's waiting is one table,
  `PresencePolicy` in core (`presence.dart`), used by the server and the
  app: watched tracking counts `in` (not loading) and `brb`; preloads and
  full social notifications count `in` and `brb`; `afk`, `out` and a
  disconnected member count for none.

## Media identity

```
media.ref = {"kind":"episode","title":"Show","anilistId":1,"anilistEp":6,
             "tvdbId":2,"season":1,"ep":6,"absolute":30}
```

- In `swap.media`, `state.media` and `queue[].media`; passed through as
  is (the server drops non-integer ids and cuts `title` to 200
  characters). `kind` `episode`, `movie` or `extra` (else no ref); every
  other field optional; `season` absent for absolute numbering. At most
  2 KiB of JSON, else `err` `bad`. Apps send it with swaps and Up next
  adds of files (the sender's library match), Jellyfin items (their
  provider ids) and links (kind and title only); receivers name the
  media by it (ARCHITECTURE.md "Library").

## Avatars

- The picture is sent as base64 in `hello.user.avatar` or `profile.avatar`;
  `state` carries only its hash: the first 16 hex characters of the sha256
  of the decoded bytes. An avatar that is not valid base64, or whose bytes
  are not a PNG, JPEG, WebP or GIF (by magic bytes), counts as none.
- `GET /a/<sid>/<token>/<hash>`: the bytes with their image content type,
  `cache-control: private, max-age=31536000, immutable` (a hash names fixed
  bytes; clients fetch each hash once, from the host they dialled).
  Errors: 401 bad token, 404 no current member has that
  picture, 410 unknown session. Pictures go with their member (leave,
  change, removal).

## Media art

```
client  {"t":"art","mediaId":2,"poster":"<base64>","banner":"<base64>"}
state   media.art = {"poster":"<hash>","banner":"<hash>"}
```

- A portrait poster and a wide banner for the current media, so every
  member (guests without Jellyfin included) can show them. Sent by the
  member who made the current swap (`media.swapBy`) or the host, for the
  current `mediaId`; from anyone else, or for another `mediaId`, it is
  ignored. Each field is optional; one that is not a picture (same check
  as avatars) or larger than its cap (poster 256 KiB, banner 768 KiB of
  decoded bytes) counts as none. A later `art` replaces the earlier one
  whole; any swap clears it.
- `media.art` carries hashes like `avatarHash`; a key is omitted when that
  picture is absent, `art` when both are. The same picture as poster and
  banner (one hash) is a web video's thumbnail.
- `GET /i/<sid>/<token>/<hash>`: as `/a/` (see "Avatars"); also the
  pictures of queued items (`queue[].thumb`). 404 when neither the current
  media nor a queued item has it.

## Jellyfin media

```
<ref> = {"serverId":"<Jellyfin ServerId>","itemId":"<32 hex>",
         "mediaSourceId":"...","title":"Pilot","subtitle":"Show - S01E01",
         "runtimeSecs":1440.5}
```

- `serverId`, `itemId` required; `mediaSourceId`, `subtitle`, `runtimeSecs`
  optional (omitted when absent); `title` always sent (may be empty).
  `runtimeSecs` is informational: the sync clock still uses the duration a
  client reports.
- The server keeps only the ref: for Jellyfin media no URL or token is stored
  or broadcast (a `url` sent along is dropped). `serverId`, `itemId` and
  `mediaSourceId` must match `[A-Za-z0-9-]{1,64}`, otherwise `bad swap media`.
  `media.name` is the swap's name, else the ref's `title`; names are
  sanitized like link names.
- Each client resolves the ref with its own account on that server. A client
  without one plays the relay URL when `state.relay` is true: `welcome.relayUrl`,
  or after a swap built like the `/m` one from the host it dialled:
  `http://<host>/j/default/<token>/<itemId>`.
- `GET /j/<sid>/<token>/<itemId>`: for the current item or, when
  `state.relayNext`, Up next's first one, the server fetches
  `/Videos/<itemId>/stream?static=true&mediaSourceId=<id>` (the original
  file) with its own credential and streams it through. `Range` is forwarded
  as sent; status, `Content-Range`, `Content-Length`, `Content-Type` and
  `Accept-Ranges` come back as Jellyfin sent them. Errors: 401 bad token,
  403 neither of those items, 404 no relay for either,
  410 unknown session, 502 Jellyfin unreachable or rejecting the server's
  credential. Bytes count toward `bytesServed`.
- Pasted Jellyfin links sent as plain `url` stay plain links.

## Relay

Media whose bytes go through the server's buffer: a file on a member's
computer, a link passed on by a member, a link the server fetches itself,
or a Jellyfin item for viewers without an account. Behavior (buffer,
flow control, cases) is in [ARCHITECTURE.md](ARCHITECTURE.md), "Relay".

```
swap  media.relay = {}               the swapper's machine serves the bytes
      media.relay = {"tracks":[{"kind":"video"},{"kind":"audio"}]}
                                     the same, as two tracks played together
      media.relay = {"tracks":[{"kind":"video","as":"pieces"}]}
                                     the same, as one segmented playlist
      media.relay = {"fetch":true}   the server reads media.url itself
state media.relay = {"source":"m2","live":true}   or {"fetch":true,"live":true}
      media.relay = {"fetch":true,"live":true,"tracks":[{"kind":"video"},{"kind":"audio"}]}
      media.relay = {"source":"m2","live":true,"rate":4100000,"need":2300000}
      media.relay = {"source":"m2","live":true,"queueId":"q3"}   started in Up next (proto 14)
      media.relay = {"source":"m2","live":true,"sourceGone":true,"sourceGoneSince":"<ISO>"}
                                     its source is gone, in its grace
      queue[0].media.relay = {"source":"m2","live":true,"tracks":[...]}   its warm relay
      queue[0].media.relay = {"fetch":true,"live":true}
```

Tracks: a relayed media is one file, or tracks that viewers play as one
(a page's separate video and audio). `tracks` lists them in order, up to
4 entries of `kind` `video` or `audio`, each a Range-readable byte stream,
or with `"as":"pieces"` a segmented stream (an HLS media playlist or DASH
fragments) relayed piece by piece and served as a VOD media playlist. A
piece is one segment, init section (`EXT-X-MAP`) or AES-128 key, fetched
upstream whole with one GET. At least 2 entries, or 1 pieces entry (a
muxed playlist, `kind` `video`); absent, an unknown `kind` or `as`, or
anything else means one file.

- `swap`: `relay` with `jellyfin` keeps the ref (the swapper serves it to
  viewers without an account; `fetch` is ignored there). `relay` without
  `jellyfin`: no URL is stored or broadcast; `fetch` needs an http(s)
  `url` (else `relay fetch needs an http(s) url`), which the server keeps
  to itself, and a server with a password (else `server fetch needs a
  server password`: an open server would fetch any address it can reach
  for anyone). A web page `url` is read through the server's yt-dlp; when
  the server cannot read the link, the swapper later gets `The server
  can't fetch this link: <reason>`; when yt-dlp failed and the server has
  no cookies, the reason is `it has no cookies (...)` instead. Any later swap ends the relay.
  `tracks` on a member's swap names the tracks its source will serve; the
  server ignores it with `fetch` and with `jellyfin`.
- `state.media.relay.source`: member id of the source (absent with
  `fetch`). `live` (omitted when false): bytes can flow (the source's
  channel is connected, or the server could read the link). `tracks`: as
  the swap named them, or, with `fetch`, set once the server has read the
  link (together with `live`).
- `sourceGone` (omitted when false) and `sourceGoneSince` (ISO): the
  source member is `gone` (see "Presence"). The relay and its buffer stay
  through the source's grace; viewers play what is buffered. A source's
  leave (grace over, `bye`) ends the relay: `live` goes, `sourceGone`
  stays, its URLs answer 404. A swap ends it as before. The warm relay's
  `queue[0].media.relay` carries the same fields.
- `state.media.relay.rate` (omitted while unknown): bytes per second the
  source (with `fetch`, the server's own fetch) delivers while the buffer
  is waiting on it, smoothed over about 4 s of that time and present once
  2 s of it are measured; it holds while the buffer is full and the
  source idles. `need` (omitted while unknown): the media's average bytes
  per second, the tracks' sizes over `media.duration` (a pieces track:
  its segments in so far, after a minute of them). Both two significant
  digits, updated once a second. `rate` under `need` means the source
  cannot keep up; clients tell the source once per media.
- Warm relay (proto 14): while Up next's first item is relayed (`how`
  `server`, `through` or `file`, or `jellyfin` when someone present has
  no access to that server and `state.relayNext` is false), the server
  holds a small relay for it and shows it as that item's
  `media.relay`: `source` (the adder; for `jellyfin` empty until the
  first member with `jf` true for that server dials in), or `fetch`, and
  `live` with `tracks` once bytes can flow. Its URLs use the item's
  queue id where a media id would be. Not for the host's own file, nor
  for an adder alone in the server. A swap with `queueId` of that item,
  from its source (or, `fetch`, from anyone) with the same `tracks`,
  makes it the media's relay: `media.relay.queueId` is the item's id,
  `media.name` the item's `media.name`, the buffer and source carry on
  and the queue-id URLs keep working. Any other swap of the item, or the
  item no longer first, drops it (its URLs 404, its source is closed
  with 4001).
- `welcome.mediaUrl` for relayed media without `jellyfin`: this member's
  `/r/` URL; absent for the source itself (it plays its own copy) and for
  a fetched link the server has not read yet (clients open it on `live`).
  Clients build it after a swap like the `/m` one:
  `http://<host>/r/default/<token>/<key>/<name>` (`<key>` the
  `mediaId`, or `media.relay.queueId` when set; name with `/` and `\`
  made `_`, then URL-encoded; the server ignores it). With `tracks`,
  each track's URL is `http://<host>/r/default/<token>/<key>/<i>/<name>`
  (a pieces track: `<name>.m3u8`); one track is opened as is, several as
  an mpv EDL of them all, each framed by its byte length:
  `edl://!no_clip;%<len>%<track 0 url>;!new_stream;!no_clip;%<len>%<track 1 url>`.
- `GET /r/<sid>/<token>/<key>/<name>`: the media (one file), Range
  table as for `/m`; `<key>` a `mediaId`, or a queue id (the warm relay,
  or the media's relay started from it). `GET /r/<sid>/<token>/<key>/<i>/<name>`: track
  `i` (from 0) of a media with `tracks` (track 0 of a one-file media
  too); for a pieces track (any name), its media playlist
  (`application/vnd.apple.mpegurl`): `#EXT-X-PLAYLIST-TYPE:VOD`,
  `EXT-X-MEDIA-SEQUENCE`, `EXTINF` durations, `EXT-X-DISCONTINUITY`,
  `EXT-X-MAP` and `EXT-X-KEY:METHOD=AES-128` (with `IV` when given) as
  upstream, `EXT-X-ENDLIST`; every URI is `p/<j>`. `GET
  /r/<sid>/<token>/<key>/<i>/p/<j>`: piece `j` of pieces track `i`,
  whole, once it is in (a Range inside the piece answers 206). Errors: 401
  bad token, 404 not the current relayed media nor the warm one (a player
  still on an older `mediaId` gets 404, never the new bytes), no such track (the
  one-file URL of a media with `tracks`) or piece (or `p/` of a byte
  track), 410 unknown session, 503 + `retry-after` the source never
  connected or the server could not read the link (60 s), or a piece did
  not arrive within 60 s. A byte request's headers come with its first
  bytes, or after 4 s without them (under mpv's 5 s timeout); its body
  then waits for missing bytes, up to 60 s for each, else the connection
  is reset. Every byte answer says `connection: close` and closes after
  its body; a swap that ends the relay closes it early without a reset.
  Bytes count toward `bytesServed`.
- `GET /r/<sid>/<token>/source` (WebSocket): the source's relay channel,
  dialled by the source (works behind NAT); `?q=<queueId>` for the warm
  relay of that item (or the media's relay started from it). Only that
  relay's source token is accepted; anyone else, or the source once its
  relay is dropped, is closed with code 4001 (the source stops instead
  of reconnecting). A warm relay's tracks are those of its source's
  first `info`. The source's token works through its grace, so a source
  back from a drop dials the channel again (before or after its own
  `hello`) and sends its `info` again: the same as its first (track
  kinds, byte sizes, piece shapes, and `name` / `duration` where both
  give them) continues the relay: the buffer stays and the server pulls
  what it still lacks with new pull ids, from the first byte or piece not
  buffered (the `pull` frames below are that exchange; nothing else is
  needed). Another `info` closes the channel with 4002 and ends the
  relay. A second channel for the same relay replaces the first, which is
  closed with 4003. The source stops on 4001, 4002 and 4003 and
  reconnects (with backoff) on anything else.
  Frames:

```
source -> server  {"t":"info","size":<bytes>,"name":"Ep 06.mkv","duration":1440.5}
                                                         first frame, one file
                                                         (name, duration optional)
                  {"t":"info","tracks":[{"kind":"video","size":<bytes>},
                                        {"kind":"audio","size":<bytes>}]}
                                                         first frame, tracks
                  {"t":"info","tracks":[{"kind":"video","as":"pieces","seq":5,
                     "pieces":[{"init":true},{"key":true},
                               {"d":6.0,"map":0,"key":1,"iv":"0x..."},
                               {"d":4.5,"map":0,"disc":true}]}]}
                                                         a pieces track
                  binary: [u32 big-endian pull id][bytes]  in order per pull
                  {"t":"end","id":1}  {"t":"fail","id":1,"reason":"..."}
server -> source  {"t":"pull","id":1,"track":0,"start":0,"end":1048575}
                                                         inclusive; no track: 0
                  {"t":"pull","id":2,"track":1,"piece":17} piece 17, whole
                  {"t":"ack","id":1,"n":65536}             bytes arrived
                  {"t":"cancel","id":1}                    stop that pull
```

  Pull ids are unique across the tracks of a connection; `track` is sent
  only for a media with `tracks`. A pieces track's `pieces` are its
  pieces in order: `{"init":true}` an init section, `{"key":true}` an
  AES-128 key, else a segment of `d` seconds whose `map` / `key` name the
  init and key pieces it uses, `iv` an explicit IV (`0x` + hex), `disc` a
  discontinuity before it; `seq` (default 0) the media sequence of the
  first segment. A piece pull's bytes end with `end` like a range pull.
  A first `info` whose tracks differ from the swap's `tracks` (count,
  bytes or pieces), or a malformed piece list, closes the channel with
  4001. A later `info` unlike the first closes it with 4002 (see above).

## Join and reconnect

`hello` then `welcome`, then the app opens `mediaUrl`, seeks to the server
position and buffers. A new member is `in` and, with media up, `loading`
(see "Presence"). A reconnect is a `hello` with the same `client` and a
higher `seq` (and `feedAfter`): within the grace it is the same member
(`welcome.resumed`), its token and media URL unchanged, its standing
kept; after a non-resumed `welcome` (grace over, server restarted) the
client reports its standing again (`presence` `brb`, `afk` or `out`).

## Invite link

Not a WebSocket message: what one app hands another (clipboard, chat,
a clicked link), so every version reads the same format.

```
starsync://203.0.113.7:8080/?name=Bob%27s+server&pw=hunter2
starsync://192.168.1.20:8080
starsync://[fe80::1]:8080
```

- Scheme `starsync`, the server's host (IPv6 in brackets) and port; no
  port means 8080. The path is `/` or empty.
- `name` (optional): the server's name for the prompt before its
  `/health` answers (at most 64 characters are shown, control characters
  dropped).
- `pw` (optional): the server password, always there when the server has
  one: the link is the key, a friend just clicks it. Logs never show it (`redactLog` cuts a `starsync://` query to its
  names).
- Unknown query keys are ignored; anything else (no host, a port outside
  1–65535) is no link.
- Invite copies the bare link, nothing around it. An app also takes a
  1.3.x plain invite ("Join me on Starsync: 192.168.1.20:8080 …"), and a
  1.3.x app reads the `host:port` out of a link.

## Queue (proto 12)

Up next: what plays after the current media, held by the server for
everyone, in memory (a restart loses it). Any member edits it; items stay
when their adder leaves. `by` is the adder's lasting member id: it
survives reconnects, and while the adder is `gone` its `through`/`file`
items wait for it (it is still in `members`) instead of being skipped;
after it left for good they cannot play. Behavior (who puts an item up, the countdown,
skipping) is in [ARCHITECTURE.md](ARCHITECTURE.md), "Up next".

```
client {"t":"queue","op":"add","at":"end"|"next","item":{<item>},"thumb":"<base64>"}
       {"t":"queue","op":"move","id":"q3","to":0}
       {"t":"queue","op":"remove","id":"q3","why":"Bob left"}
       {"t":"queue","op":"play","id":"q3"}
       {"t":"queue","op":"skip"}
       {"t":"queue","op":"cancel"}
       {"t":"queue","op":"add","item":{<item>,"auto":true,"for":2}}
       {"t":"swap","media":{...},"queueId":"q3"}
state  "queue":[<item>,...], "queuePlay":"q3"
<item> = {"id":"q3","media":{<swap media>},"how":"direct"|"server"|"through"|"file"|"jellyfin",
          "title":"...","sub":"...","duration":213,"thumb":"<hash>",
          "by":"m2","byName":"Bob","key":"<adder's handle>","auto":true?,"for":2?}
state  "advance":{"id":"q3","at":"<server time>","secs":10}
```

- `add`: `item` without `id`, `by`, `byName`, `thumb` (the server sets
  them: `id` `q<n>`, unique for the server's life; who sent it and their
  name then). `at` `next` puts it first, else last. `thumb` (optional):
  base64 picture, checked and capped like a poster (256 KiB decoded);
  `item.thumb` is its hash, served at `/i/` (see "Media art") while the
  item is queued. `title` and `sub` are cleaned like media names and cut
  to 200 characters (an empty title becomes the media's name); `duration`
  (seconds, omitted when unknown) is informational. At most 100 items;
  over that the sender gets `err` `Up next is full (100 items)`. With
  nothing up, the first item is asked for at once (`queuePlay`).
- `how` and what `media` must carry:
  - `direct`: an http(s) `url`; everyone opens the link.
  - `server`: an http(s) `url` and `relay` `{"fetch":true}`, on a server
    with a password (as for a fetch swap). The server keeps the URL to
    itself: the broadcast `media` has none.
  - `through` (a link the adder passes on) / `file` (the adder's file):
    `name` and `size` only, and `key` (8 to 64 of `[A-Za-z0-9_-]`): the
    adder's own handle for the link or path, which never leave its app.
    A `url` sent along is dropped.
  - `jellyfin`: a `jellyfin` ref, checked like a swap's (any `media` with
    a ref is `jellyfin`).
  Anything else: `err` `bad message: ...`.
- `move`: `id` to index `to` (clamped). `remove`: drops `id`; with `why`
  (cut to 120 characters) it is a skip (feed `queue-skip` with the
  reason; clients show it), else feed `queue-remove`. `add` gives feed
  `queue-add`. Unknown ids are ignored.
- `play`: moves `id` first and sets `state.queuePlay` to it: a request for
  the member who can put it up to do so now. `skip` is `play` of the
  first item. `queuePlay` ends with any swap or when the item is removed.
  A request nobody acted on within 30 s is asked again: of the next member
  who can put it up when there is one (the one who did not goes into
  `state.queuePass`, which `queuePerformer` skips; it belongs to that
  request only), else of the same member once more, then the item is
  skipped (feed `queue-skip`, actor `server`, reason "Bob didn't put it
  up"); while nobody is around it keeps waiting. An item asked for that
  nobody here can put up (its
  adder left for good, nobody has its Jellyfin server; the rule is
  core's `queuePerformer`, ARCHITECTURE "What's next") is taken off by the
  server: feed `queue-skip`, actor `server`, `reason` why.
- `auto` (with `for`, the `mediaId` it continues): the continuation (the
  next episode). Only for the current media (else `err` `bad`), and only
  from the member who put it up (`media.swapBy`) or, when that member is
  present (connected, `in` or `brb`), from the first member who is (else
  `err` `forbidden`). At most
  one: a newer one replaces it; it stays after the other items (an `add`
  goes before it, `next` puts an item first, `move` never passes it, it
  does not move itself); any swap that does not put it up drops it.
  Adding it gives no feed line.
- `cancel`: drops the `auto` item and the countdown for everyone (feed
  `advance-cancel`); nothing to drop, nothing happens.
- `state.advance`: the shared countdown over the media's last 10 s while
  the group wants to play, with an item first; `secs` is 10, `at` its
  start (server clock), so `at` + `secs` is the media's end (while the
  group waits for a video, `at` moves on with it). The moment the media
  finishes the server sets `queuePlay` to `id` and the countdown is over.
  An item coming first once the media finished starts a countdown of its
  own (`at` then, ending 10 s later). A new first item takes it over with
  the same end. While the member who puts the item up is not around (its
  adder `gone`, nobody present) or the item's warm relay waits for a
  `gone` source, it holds, and asks once they are back. A seek, an empty
  queue, `cancel`, a `pause` during it and any swap clear it; after
  `cancel` or that pause it does not start again for that media (it
  stops at the end), nor again for the item it already asked for.
- `swap.queueId`: the swap puts that item up and takes it off the queue
  in the same step. A swap naming an item that is no longer queued is
  ignored (someone put it up first). For a `server` item the swap may
  leave out `url`: the server uses the one it kept. A swap without
  `queueId` leaves the queue as it is.
- `state.queue` (omitted when empty) and `state.queuePlay` (omitted when
  none) ride in every state, `welcome.state` included. The first item's
  `media.relay` shows its warm relay (see "Relay").

## Diagnostics (proto 15)

Each app sends its log lines to the server, which merges them with its
own into the session log (behavior, file and format: ARCHITECTURE.md,
"Logging").

```
POST /l/<sid>/<token>   content-type application/gzip, body = gzip of:
  {"v":"Starsync 1.4.0 on linux","share":false,
   "lines":[{"t":1767225600123,"l":"WARNING","n":"mpv","m":"..."}],
   "dropped":12,"marks":[{"t":1767225600500,"note":"..."}]}
GET  /l/<sid>/<token>?hours=6
```

- `POST`: one batch. Every field is optional. `v`: the app and version,
  noted once per member (and when it changes). `share:false` (omitted
  when true): the member does not share; the server notes it once and
  drops any `lines`. `lines[]`: `t` epoch ms on the server's clock (the
  client converts with its `pong` offset), `l` level name, `n` logger
  (`[A-Za-z0-9_.-]`, up to 40, else `app`), `m` the message, already
  redacted, an error and stack trace on the lines below (cut to 8192
  characters). `dropped`: lines the client dropped since its last batch
  (its buffer was full). `marks[]`: "Mark a problem" at `t` with an
  optional `note` (one line, cut to 200 characters); it goes in even
  with `share:false`.
- Limits: a body of at most 256 KiB, unpacking to at most 1 MiB (else
  413); not gzip of a JSON object: 400. Per member and minute at most 30
  posts and 4 MiB of lines, else 429 with `retry-after`: the client keeps
  the batch and sends it later. Unknown token: 401. Success: 204, also
  on a server that keeps no session log (the batch is dropped).
- `GET`: the session log of the last `hours` (1 to 168, default 6; at
  most 8 MiB, the newest kept), lines the server still holds for
  ordering included, as gzip of UTF-8 text (`application/gzip`). Any
  member may read it (it is redacted and holds no chat). 401 for an
  unknown token, 404 on a server that keeps no session log.
- Clients send every 10 s and when they leave; each batch carries at
  most 256 KiB of lines.

## Live (proto 17)

A live stream (Twitch, YouTube Live, an HLS playlist without an end):
no length; play and pause are the group's; seeking only back within
what every member can rewind to, and only then does anyone wait for
anyone. Behavior: ARCHITECTURE.md "Live streams".

```
swap    media = {"name":"…","size":0,"duration":0,"url":"https://…","live":true}
state   media.live = true, position = the group's live point (stream time)
client  {"t":"report","position":43051.2,"buffered":12.0,"eventId":9,"mediaId":3,"edge":43063.1}
client  {"t":"report","position":43120.0,"buffered":0,"eventId":9,"mediaId":3,"duration":43120.0}   reached the end
client  {"t":"report","position":43051.2,"buffered":12.0,"eventId":9,"mediaId":3,"edge":43063.1,"from":42169.1}
client  {"t":"seek","position":42900.0}
state   position = 42900.0 (running), liveFrom = 42172.0, behind = 151.2
client  {"t":"pause"}
state   transport = held, position = 42930.0, behind = 151.2 (at serverTime; it grows while held)
```

- `media.live` (omitted when false): a live stream, set by the putter in
  `swap.media` (its probe said so) and passed through in `state.media`
  for a plain link (a relay or a Jellyfin item is never live). A report
  with `edge` for the current media makes it live too (a player found
  its length growing): the server sets `media.live`, drops a reported
  `duration` and starts again from `held`.
- Units: for live media `state.position` and a report's `position`,
  `edge` and `duration` are in the stream's own time (mpv's `time-pos`
  plus `demuxer-start-time`: the stream's timestamps, the same for every
  viewer and every rendition).
- `report.edge` (optional, omitted when 0): the end of what the player
  has of the stream; with it `position` is where the player is. A live
  report's `duration` says the player reached the end of the stream
  there (then without `edge`); a live player never sends its growing
  length.
- `report.from` (optional, omitted when 0): the oldest moment of the
  stream this player can rewind to (its playlist's window back from the
  stream's edge), stream time; 0 or absent: it cannot.
- `state.transport`: `held` (position 0) until the first live report
  sets the live point, then `playing`: halfway from that player's
  position to its edge, 3 s further back (`RelayConstants.liveMarginSecs`);
  from a player more than 60 s behind its edge (a stitched ad) its edge
  minus 10 s, then the 3 s. The wish becomes `play`. From then on the
  live point runs at 1x whatever the group does. While `playing` the
  point is set again (`eventId` up, `behind` back to 0) when it runs 3 s
  past every connected member's last edge (the stream stalled or started
  over) or the live point falls 120 s behind it (its clock jumped
  ahead); neither for 15 s after a seek
  (`RelayConstants.liveSeekSettleSecs`).
- `state.liveFrom` (omitted when 0): the oldest moment every member
  watching can rewind to: the latest `report.from` of the connected
  members who are in and have reported the stream, when each of them
  sent one and it is 60 s or more behind the live point
  (`RelayConstants.liveMinWindowSecs`); else 0 (no rewinding). Sent
  while `held` too (the window moves on with the stream).
- `state.behind` (omitted when 0; under 50 ms counts as 0): seconds the
  group's point is behind its live point at `serverTime` (a rewind, a
  pause). While `held` the live point runs on, so it is `behind` plus
  the time since `serverTime` (`StateBroadcast.liveBehindAt`); the live
  point is the group's position now plus that.
- `seek`: at or past the live point minus 1 s, the group goes back to
  live (`behind` 0, feed `seek` with reason `live`; also without
  `liveFrom`) and the wish becomes `play` (Go live from a pause plays);
  else, with `liveFrom`, the point moves to the position (no earlier
  than `liveFrom`): `playing`, it runs on at 1x, `behind` the
  difference; `held`, it stays held there (feed `seek`); else it is
  ignored. `eventId` goes up, `seekBy`/`seekSeq` as for any seek; a seek
  while `held` counts everyone's buffer from 0 again.
- `play` and `pause` are the group's, as for any media (feed `play` /
  `pause`): a pause holds the point (`held`, the live point runs on).
  Play with `liveFrom`: from the held point once nobody is BRB and no
  watched member runs short (below); when the held point is earlier
  than `liveFrom` (paused longer than the window keeps), the point first
  moves to `liveFrom` plus 10 s (`RelayConstants.liveResumeMarginSecs`;
  `eventId` up, everyone's buffer from 0) and waits for the buffers
  there. Play without `liveFrom`: `playing` at once at the live point
  (`behind` 0).
- Waiting, only with `liveFrom`: BRB holds at once and `state.hold` is
  as for any media; a watched member runs short with under 1 s ahead
  (`RelayConstants.liveMinBufferSecs`, `bufferNeed` of live media) while
  the stream has more (another member's edge 1 s or more past the
  group's point; never one that reached the end), which holds a
  `playing` group (feed `pause` by the server) and keeps a `held` one.
  A report sent before the group's point last moved (an older
  `eventId`) counts as no buffer. Without `liveFrom`: no `state.hold`,
  BRB and buffers hold nothing. `members[].loading` ends with the
  member's first live report.
- End: `finished` (feed `finished`, position the end) once a member
  reported the end and no connected member reports an edge more than 3 s
  past it. Up next's first item is asked to play at once (`advance` set
  as already run out); no countdown runs over live media.
