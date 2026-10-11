# Protocol (proto = 12)

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
{"t":"hello","proto":12,"secret":"","user":{"name":"","avatar":""},
 "media":{"name":"","size":0,"duration":0,"url":null},"hostKey":"...",
 "resume":"<token>"}
{"t":"ready","ready":true,"source":"manual"}      source: manual | auto
{"t":"force","target":"all"|"<memberId>","ready":true}
{"t":"seek","position":123.4,"seq":3}
{"t":"swap","media":{"name":"","size":0,"duration":0,"url":"..."}}
{"t":"swap","media":{"name":"","size":0,"duration":0,"jellyfin":{<ref>}}}
{"t":"swap","media":{"name":"","size":123,"duration":0,"url":"...","relay":{}}}
{"t":"swap","media":{...},"queueId":"q3"}         puts up an Up next item
{"t":"report","position":123.1,"buffered":6.2,"eventId":41,
 "duration":1440.5,"mediaId":2,"jf":{"<serverId>":true},"error":"Not allowed (403)"}
{"t":"ping","c":1767225600000}
{"t":"chat","text":"..."}
{"t":"out","target":"<memberId>","out":true}
{"t":"nudge","target":"<memberId>"}
{"t":"profile","name":"...","avatar":"<base64>"}
{"t":"art","mediaId":2,"poster":"<base64>","banner":"<base64>"}
{"t":"queue","op":"add"|"move"|"remove"|"play"|"skip",...}   see "Queue"
```

Field notes:
- `hello.secret`: the server password; a server with an empty secret is open.
  `hello.media` is carried but not used by the server today.
- `hello.hostKey` (optional, omitted when empty): the hosting app
  generates a random key per hosting, gives it to its server and sends it
  from its own client. The member whose key equals the server's is the host
  (`members[].host`). A server without a key (the dedicated server) has no
  host. Where the connection comes from does not matter.
- `hello.resume` (optional, omitted when empty): the token from this
  client's previous `welcome`, sent on reconnect. If the server still has
  that member, the connection takes it over: `welcome`
  returns the same `token` and `memberId`, the member keeps its flags, and
  there is no `join`/`leave` feed. Otherwise it is ignored and a new member
  joins.
- `seek.seq` (optional, default 0): increasing per client; echoed in
  `state.seekSeq` so the sender recognises its own seek.
- `report.duration` / `report.mediaId` (optional, omitted when 0): the open
  media's length in seconds and the `mediaId` it belongs to. The server takes
  the first one whose `mediaId` is current while its media duration is 0.
  `report.buffered` is the current media's: a client sends 0 while its
  player does not hold it yet, and the server counts a report whose
  `mediaId` names an earlier media as `buffered` 0.
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
  clears it, and so does a swap. An errored member is out of the ready
  gate: out of the set, a `ready` or `force` does not put it back; when
  the error clears it is in the set again like a join (unless `playing`,
  then from its `ready`). Optional on both sides: older servers ignore it,
  older clients ignore `members[].error`.
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
- `out`: `out:true` sits the member `target` out (anyone, the host
  included); `out:false` brings the sender back and only works with its own
  member id as `target`. An out member is never in the set and never
  ready: `ready` from it and `force` on it are ignored, a swap leaves it
  out, the `buffered` of its reports counts as 0 (it keeps sending
  `report`: that keeps it fresh). Coming back puts it in the set like a
  join (unless `playing`), unready; it sends `ready` itself. Unknown
  targets and no-op changes are ignored. Feed: `out` (`target` = the name
  of who was sat out, absent when the actor sat itself out) and `back`.
- `nudge`: the server sends `{"t":"nudge","from":<memberId>,"name":<name>}`
  to `target` only (no feed). At most 3 per second and 20 per minute per
  sender; the rest, nudges to oneself and to unknown targets are dropped
  silently.
- `swap.media.url` is the link; `name`, `size`, `duration` are informational.
  `swap.media.jellyfin` makes it Jellyfin media (see below); then `url` is
  dropped. `swap.media.relay` makes it relayed media (see "Relay").
  A swap keeps every member's `ready` and puts every fresh member in the
  set (`inSet`); clients that want to be unready for the new media send
  `ready` themselves (gate: ARCHITECTURE.md, "Ready gate").
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
   "host"?,"out"?,"error"?,"rate"?}],
 "seekBy":"m1","seekSeq":3,"relay":true,"queue":[<item>]?,"queuePlay":"q3"?}
{"t":"pong","c":1767225600000,"s":1767225600012}
{"t":"feed","actor":"","action":"","target":"","reason":"","at":"<ISO-8601>"}
{"t":"chat","text":"...","from":"<name>"}
{"t":"nudge","from":"m2","name":"Alice"}
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
  server's `hostKey` (see `hello.hostKey`). `members[].out` (omitted when
  false): the member sits out (see `out`). `members[].error` (omitted when
  empty): the member's player cannot open the current media (see
  `report.error`). `members[].rate` (omitted when 0): bytes per second
  the server sent this member over the last 5 s (`/m`, `/j` and `/r`
  together), two significant digits, under 10 kB/s counts as 0. Members
  that fetch the media themselves read nothing from the server.
- `pong.c` echoes the ping's `c`; `pong.s` is the server's clock in epoch ms
  (the clock `serverTime` uses). With `t3` the local receive time, the offset
  is `s - (c + t3) / 2`, accurate to half the round trip.
- `feed.action` values: `ready`, `unready`, `force-ready`, `force-unready`,
  `force-play`, `force-hold`, `out`, `back`, `join`, `leave`, `stale`, `swap`,
  `seek`, `pause`, `resume`, `finished`, `chat`, `rename`, `avatar`,
  `queue-add`, `queue-remove`, `queue-skip`, `fetch-fail` (proto 12: the
  server could not fetch the current media, `target` its name). `target`
  and `reason` are optional; `reason` carries `auto`/`manual` for ready and
  `silent too long` or `no signal` for leave/stale. `rename`: `actor` is the
  new name, `target` the old one. `avatar`: the actor changed only the
  picture. `queue-*`: `target` is the item's title, `reason` (skip) why it
  could not play (see "Queue").
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
- `GET /j/<sid>/<token>/<itemId>`: the server fetches
  `/Videos/<itemId>/stream?static=true&mediaSourceId=<id>` (the original
  file) with its own credential and streams it through. `Range` is forwarded
  as sent; status, `Content-Range`, `Content-Length`, `Content-Type` and
  `Accept-Ranges` come back as Jellyfin sent them. Errors: 401 bad token,
  403 not the current item, 404 no relay for the current media,
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
- `state.media.relay.rate` (omitted while unknown): bytes per second the
  source (with `fetch`, the server's own fetch) delivers while the buffer
  is waiting on it, smoothed over about 4 s of that time and present once
  2 s of it are measured; it holds while the buffer is full and the
  source idles. `need` (omitted while unknown): the media's average bytes
  per second, the tracks' sizes over `media.duration` (a pieces track:
  its segments in so far, after a minute of them). Both two significant
  digits, updated once a second. `rate` under `need` means the source
  cannot keep up; clients tell the source once per media.
- `welcome.mediaUrl` for relayed media without `jellyfin`: this member's
  `/r/` URL; absent for the source itself (it plays its own copy) and for
  a fetched link the server has not read yet (clients open it on `live`).
  Clients build it after a swap like the `/m` one:
  `http://<host>/r/default/<token>/<mediaId>/<name>` (name with `/` and
  `\` made `_`, then URL-encoded; the server ignores it). With `tracks`,
  each track's URL is `http://<host>/r/default/<token>/<mediaId>/<i>/<name>`
  (a pieces track: `<name>.m3u8`); one track is opened as is, several as
  an mpv EDL of them all, each framed by its byte length:
  `edl://!no_clip;%<len>%<track 0 url>;!new_stream;!no_clip;%<len>%<track 1 url>`.
- `GET /r/<sid>/<token>/<mediaId>/<name>`: the media (one file), Range
  table as for `/m`. `GET /r/<sid>/<token>/<mediaId>/<i>/<name>`: track
  `i` (from 0) of a media with `tracks` (track 0 of a one-file media
  too); for a pieces track (any name), its media playlist
  (`application/vnd.apple.mpegurl`): `#EXT-X-PLAYLIST-TYPE:VOD`,
  `EXT-X-MEDIA-SEQUENCE`, `EXTINF` durations, `EXT-X-DISCONTINUITY`,
  `EXT-X-MAP` and `EXT-X-KEY:METHOD=AES-128` (with `IV` when given) as
  upstream, `EXT-X-ENDLIST`; every URI is `p/<j>`. `GET
  /r/<sid>/<token>/<mediaId>/<i>/p/<j>`: piece `j` of pieces track `i`,
  whole, once it is in (a Range inside the piece answers 206). Errors: 401
  bad token, 404 not the current relayed media (a player still on an
  older `mediaId` gets 404, never the new bytes), no such track (the
  one-file URL of a media with `tracks`) or piece (or `p/` of a byte
  track), 410 unknown session, 503 + `retry-after` the source never
  connected or the server could not read the link (60 s), or a piece did
  not arrive within 60 s. A byte request whose bytes do not arrive within
  60 s ends early. Bytes count toward `bytesServed`.
- `GET /r/<sid>/<token>/source` (WebSocket): the source's relay channel,
  dialled by the source (works behind NAT). Only the current source's
  token is accepted; anyone else, or the source after the next swap, is
  closed with code 4001 (the source stops instead of reconnecting).
  Frames:

```
source -> server  {"t":"info","size":<bytes>}            first frame, one file
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
  An `info` whose tracks differ from the swap's `tracks` (count, bytes or
  pieces), or a malformed piece list, closes the channel with 4001. A
  track `size` or piece count/roles different from the one before (a
  reconnect) drops that track's buffer.

## Join and reconnect

`hello` then `welcome`, then the app opens `mediaUrl`, seeks to the server
position and buffers. A joining member is `ready=false`; it is `inSet`
at once unless the server is `playing`, then from its first `ready`
(members present at a swap are put in the set by it). A socket the server sees close loses its token; reconnect
is a fresh `hello` (with `resume` = the old token), after which the client
re-sends its prior ready flag. If the old member was still there (unclean
drop), `resume` takes it over and the token and media URL stay the same.

## Queue (proto 12)

Up next: what plays after the current media, held by the server for
everyone, in memory (a restart loses it). Any member edits it; items stay
when their adder leaves. Behavior (who puts an item up, the countdown,
skipping) is in [ARCHITECTURE.md](ARCHITECTURE.md), "Up next".

```
client {"t":"queue","op":"add","at":"end"|"next","item":{<item>},"thumb":"<base64>"}
       {"t":"queue","op":"move","id":"q3","to":0}
       {"t":"queue","op":"remove","id":"q3","why":"Bob left"}
       {"t":"queue","op":"play","id":"q3"}
       {"t":"queue","op":"skip"}
       {"t":"swap","media":{...},"queueId":"q3"}
state  "queue":[<item>,...], "queuePlay":"q3"
<item> = {"id":"q3","media":{<swap media>},"how":"direct"|"server"|"through"|"file"|"jellyfin",
          "title":"...","sub":"...","duration":213,"thumb":"<hash>",
          "by":"m2","byName":"Bob","key":"<adder's handle>"}
```

- `add`: `item` without `id`, `by`, `byName`, `thumb` (the server sets
  them: `id` `q<n>`, unique for the server's life; who sent it and their
  name then). `at` `next` puts it first, else last. `thumb` (optional):
  base64 picture, checked and capped like a poster (256 KiB decoded);
  `item.thumb` is its hash, served at `/i/` (see "Media art") while the
  item is queued. `title` and `sub` are cleaned like media names and cut
  to 200 characters (an empty title becomes the media's name); `duration`
  (seconds, omitted when unknown) is informational. At most 100 items;
  over that the sender gets `err` `Up next is full (100 items)`.
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
  first item. `queuePlay` ends with any swap, when the item is removed,
  or after 30 s.
- `swap.queueId`: the swap puts that item up and takes it off the queue
  in the same step. A swap naming an item that is no longer queued is
  ignored (someone put it up first). For a `server` item the swap may
  leave out `url`: the server uses the one it kept. A swap without
  `queueId` leaves the queue as it is.
- `state.queue` (omitted when empty) and `state.queuePlay` (omitted when
  none) ride in every state, `welcome.state` included.
