# Protocol (proto = 9)

Wire format only. Behavior (gate, clock, timeouts) is in
[ARCHITECTURE.md](ARCHITECTURE.md). Source of truth:
`packages/core/lib/src/protocol.dart` and `packages/server/lib/src/server_hub.dart`.

Any wire change bumps `RelayConstants.protoVersion` and edits this file in
the same commit. Changes are additive where possible; a client and server
with different `proto` refuse each other at `hello` (`proto mismatch`).

## Transport

- WebSocket at `/sync`, JSON text frames, each an object with a `t` field.
- The first client frame must be `hello` within 10 s. Server pings every 5 s.
- Match incoming frames by `t`, never by order: `welcome` can race `state`.
- Failures: server sends `{"t":"err","message":...}` and closes.
  Messages: `bad hello: ...`, `proto mismatch: got X, want Y`, `wrong secret`,
  `rejected: <reason>` (e.g. avatar too large), `bad message: ...` (a frame
  with a non-finite number, e.g. NaN position), `bad swap media`,
  `swap needs a url or the hosted file` (empty swap).
- `GET /health` returns JSON (`ok`, `name`, `proto`, `viewers`, `bytesServed`,
  `uptimeSecs`; unauthenticated). `GET /m/<sid>/<token>/<name>`
  serves the host's file (Range table in ARCHITECTURE.md).
  `GET /j/<sid>/<token>/<itemId>` relays the current Jellyfin media (see
  "Jellyfin media" below). `/r/<sid>/<token>/...` is the relay of a
  member's media (see "Relay" below). `GET /a/<sid>/<token>/<hash>` serves
  a member's picture (see "Avatars" below), `GET /i/<sid>/<token>/<hash>`
  the current media's art (see "Media art" below).

## Client to server

```
{"t":"hello","proto":9,"secret":"","user":{"name":"","avatar":""},
 "media":{"name":"","size":0,"duration":0,"url":null},"hostKey":"...",
 "resume":"<token>"}
{"t":"ready","ready":true,"source":"manual"}      source: manual | auto
{"t":"force","target":"all"|"<memberId>","ready":true}
{"t":"seek","position":123.4,"seq":3}
{"t":"swap","media":{"name":"","size":0,"duration":0,"url":"..."}}
{"t":"swap","media":{"name":"","size":0,"duration":0,"jellyfin":{<ref>}}}
{"t":"swap","media":{"name":"","size":123,"duration":0,"url":"...","relay":{}}}
{"t":"report","position":123.1,"buffered":6.2,"eventId":41,
 "duration":1440.5,"mediaId":2,"jf":{"<serverId>":true}}
{"t":"ping","c":1767225600000}
{"t":"chat","text":"..."}
{"t":"kick","target":"<memberId>","reason":""}
{"t":"profile","name":"...","avatar":"<base64>"}
{"t":"art","mediaId":2,"poster":"<base64>","banner":"<base64>"}
```

Field notes:
- `hello.secret`: the server password; a server with an empty secret is open.
  `hello.media` is carried but not used by the server today.
- `hello.hostKey` (optional, omitted when empty): the hosting app
  generates a random key per hosting, gives it to its server and sends it
  from its own client. The member whose key equals the server's is the host
  and cannot be kicked. A server without a key (the dedicated server) has no
  host. Where the connection comes from does not matter.
- `hello.resume` (optional, omitted when empty): the token from this
  client's previous `welcome`, sent on reconnect. If the server still has
  that member and it is not kicked, the connection takes it over: `welcome`
  returns the same `token` and `memberId`, the member keeps its flags, and
  there is no `join`/`leave` feed. Otherwise it is ignored and a new member
  joins.
- `seek.seq` (optional, default 0): increasing per client; echoed in
  `state.seekSeq` so the sender recognises its own seek.
- `report.duration` / `report.mediaId` (optional, omitted when 0): the open
  media's length in seconds and the `mediaId` it belongs to. The server takes
  the first one whose `mediaId` is current while its media duration is 0.
- `report.jf` (optional): Jellyfin access per `ServerId`, `true` = this
  client plays the item with its own account, `false` = through the relay.
  Sticky: a report without `jf` keeps the last one. At most 8 entries, keys
  up to 64 characters; others are dropped.
- `ping.c`: the client's clock in epoch ms; answered with `pong`.
- `user.avatar`: base64 PNG, at most 256 KiB of characters (else
  `rejected: ...`). `name` is trimmed, empty becomes `?`, cut to 32
  characters.
- `profile`: changes this member's name and/or picture mid-session. A field
  that is absent (or null) stays as it is; `avatar: ""` removes the picture.
  Same rules as `hello.user`; a too large avatar gets `err`
  `rejected: avatar too large` (the socket stays open, nothing changes).
- `art`: pictures of the current media (see "Media art").
- `chat.text` is cut to 500 characters.
- `swap.media.url` is the link; `name`, `size`, `duration` are informational.
  `swap.media.jellyfin` makes it Jellyfin media (see below); then `url` is
  dropped. `swap.media.relay` makes it relayed media (see "Relay").
- Frames before `welcome` (other than `hello`) are ignored; unparsable or
  unknown frames are ignored silently.

## Server to client

```
{"t":"welcome","token":"...","memberId":"m1","mediaUrl":"...","relayUrl":"...",
 "state":{<state>}}
{"t":"state","eventId":7,"transport":"playing"|"held"|"finished","position":12.3,
 "serverTime":"<ISO-8601 UTC>","mediaId":1,
 "media":{name,size,duration,url?,jellyfin?,relay?,swapBy?,art?}|absent,
 "members":[{"id","name","avatarHash"?,"ready","inSet","buffered","stale","jf"?,
   "host"?}],
 "seekBy":"m1","seekSeq":3,"relay":true}
{"t":"pong","c":1767225600000,"s":1767225600012}
{"t":"feed","actor":"","action":"","target":"","reason":"","at":"<ISO-8601>"}
{"t":"chat","text":"...","from":"<name>"}
{"t":"kicked","reason":""}
{"t":"err","message":""}
```

- `welcome.token` is private to its owner and appears only in that member's
  media URL. `mediaUrl` is omitted when there is no media; it is a built
  `/m/...` URL for a host file (host part = what the client dialled), otherwise
  the shared link.
  `welcome.state` has the same shape as `state`. `relayUrl` is present only
  when `state.relay` is: this member's `/j/...` URL for the current
  Jellyfin media (private like `token`).
- `state` is sent every second and on every change. `position` is the value at
  `serverTime` (server clock); clients extrapolate while `transport` is
  `playing`, on the server's clock (see `pong`). `finished`: the media
  reached its end (`position` = duration); it stays until a seek or swap.
  `eventId` increases on seek, swap and transport changes.
  `mediaId` increases on swap. `media.relay` is present for relayed media
  (see "Relay"). `media.duration` is 0 until a client reports
  it. `media.swapBy`: member id of who swapped it in (omitted once that
  member left, and for the media the server started with). `media.art`:
  see "Media art". `seekBy` (member id) and `seekSeq` are present only while the current
  `eventId` came from a seek. `relay` (omitted when false): the server can
  relay the current Jellyfin media. `members[].jf` is the member's last
  `report.jf`, omitted when it never sent one. `members[].avatarHash`
  (omitted when the member has no picture) names the picture's bytes (see
  "Avatars"). `members[].host` (omitted when false): the member sent the
  server's `hostKey` (see `hello.hostKey`).
- `pong.c` echoes the ping's `c`; `pong.s` is the server's clock in epoch ms
  (the clock `serverTime` uses). With `t3` the local receive time, the offset
  is `s - (c + t3) / 2`, accurate to half the round trip.
- `feed.action` values: `ready`, `unready`, `force-ready`, `force-unready`,
  `force-play`, `force-hold`, `kick`, `join`, `leave`, `stale`, `swap`,
  `seek`, `pause`, `resume`, `finished`, `chat`, `rename`, `avatar`. `target`
  and `reason` are optional; `reason` carries `auto`/`manual` for ready and
  `silent too long` or `no signal` for leave/stale. `rename`: `actor` is the
  new name, `target` the old one. `avatar`: the actor changed only the
  picture.
- Chat is delivered twice: a `chat` frame with the text and a textless
  `feed` with `action:"chat"`. Render the `chat` frame only; the reference
  client drops the textless feed entry.

## Avatars

- The picture is sent as base64 in `hello.user.avatar` or `profile.avatar`;
  `state` carries only its hash: the first 16 hex characters of the sha256
  of the decoded bytes. An avatar that is not valid base64, or whose bytes
  are not a PNG, JPEG, WebP or GIF (by magic bytes), counts as none.
- `GET /a/<sid>/<token>/<hash>`: the bytes with their image content type,
  `cache-control: private, max-age=31536000, immutable` (a hash names fixed
  bytes; clients fetch each hash once, from the host they dialled).
  Errors: 401 bad token, 403 kicked, 404 no current member has that
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
  picture is absent, `art` when both are.
- `GET /i/<sid>/<token>/<hash>`: as `/a/` (see "Avatars"); 404 when the
  current media has no such art.

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
- `GET /j/<sid>/<token>/<itemId>`: the server fetches
  `/Videos/<itemId>/stream?static=true&mediaSourceId=<id>` (the original
  file) with its own credential and streams it through. `Range` is forwarded
  as sent; status, `Content-Range`, `Content-Length`, `Content-Type` and
  `Accept-Ranges` come back as Jellyfin sent them. Errors: 401 bad token,
  403 kicked or not the current item, 404 no relay for the current media,
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
      media.relay = {"fetch":true}   the server reads media.url itself
state media.relay = {"source":"m2","live":true}   or {"fetch":true,"live":true}
```

- `swap`: `relay` with `jellyfin` keeps the ref (the swapper serves it to
  viewers without an account; `fetch` is ignored there). `relay` without
  `jellyfin`: no URL is stored or broadcast; `fetch` needs an http(s)
  `url` (else `relay fetch needs an http(s) url`), which the server keeps
  to itself, and a server with a password (else `server fetch needs a
  server password`: an open server would fetch any address it can reach
  for anyone). Any later swap ends the relay.
- `state.media.relay.source`: member id of the source (absent with
  `fetch`). `live` (omitted when false): bytes can flow (the source's
  channel is connected, or the server could read the link).
- `welcome.mediaUrl` for relayed media without `jellyfin`: this member's
  `/r/` URL; absent for the source itself (it plays its own copy). Clients build it after a swap like the `/m` one:
  `http://<host>/r/default/<token>/<mediaId>/<name>` (name URL-encoded).
- `GET /r/<sid>/<token>/<mediaId>/<name>`: the media, Range table as for
  `/m`. Errors: 401 bad token, 403 kicked, 404 not the current relayed
  media (a player still on an older `mediaId` gets 404, never the new
  bytes), 410 unknown session, 503 + `retry-after` the source never
  connected (60 s). A request whose bytes do not arrive within 60 s ends
  early. Bytes count toward `bytesServed`.
- `GET /r/<sid>/<token>/source` (WebSocket): the source's relay channel,
  dialled by the source (works behind NAT). Only the current source's
  token is accepted; anyone else, or the source after the next swap, is
  closed with code 4001 (the source stops instead of reconnecting).
  Frames:

```
source -> server  {"t":"info","size":<bytes>}            first frame
                  binary: [u32 big-endian pull id][bytes]  in order per pull
                  {"t":"end","id":1}  {"t":"fail","id":1,"reason":"..."}
server -> source  {"t":"pull","id":1,"start":0,"end":1048575}  inclusive
                  {"t":"ack","id":1,"n":65536}             bytes arrived
                  {"t":"cancel","id":1}                    stop that pull
```

  A `size` different from the one before (a reconnect) drops the buffer.

## Join and reconnect

`hello` then `welcome`, then the app opens `mediaUrl`, seeks to the server
position and buffers. A joining member is `ready=false, inSet=false` until
the first `ready`. A socket the server sees close loses its token; reconnect
is a fresh `hello` (with `resume` = the old token), after which the client
re-sends its prior ready flag. If the old member was still there (unclean
drop), `resume` takes it over and the token and media URL stay the same.

## Reserved, not implemented

Server-held queue (`queue-add`, `queue-skip`) would auto-advance like a swap.
