# Protocol (proto = 5)

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

## Client to server

```
{"t":"hello","proto":5,"secret":"","user":{"name":"","avatar":""},
 "media":{"name":"","size":0,"duration":0,"url":null},"hostKey":"..."}
{"t":"ready","ready":true,"source":"manual"}      source: manual | auto
{"t":"force","target":"all"|"<memberId>","ready":true}
{"t":"seek","position":123.4}
{"t":"swap","media":{"name":"","size":0,"duration":0,"url":"..."}}
{"t":"report","position":123.1,"buffered":6.2,"eventId":41}
{"t":"chat","text":"..."}
{"t":"kick","target":"<memberId>","reason":""}
```

Field notes:
- `hello.secret`: the server password; a server with an empty secret is open.
  `hello.media` is carried but not used by the server today.
- `hello.hostKey` (optional, omitted when empty): the hosting app
  generates a random key per hosting, gives it to its server and sends it
  from its own client. The member whose key equals the server's is the host
  and cannot be kicked. A server without a key (the dedicated server) has no
  host. Where the connection comes from does not matter.
- `user.avatar`: base64 image, at most 256 KiB of characters. `name` is
  trimmed, empty becomes `?`, cut to 32 characters.
- `chat.text` is cut to 500 characters.
- `swap.media.url` is the link; `name`, `size`, `duration` are informational.
- Frames before `welcome` (other than `hello`) are ignored; unparsable or
  unknown frames are ignored silently.

## Server to client

```
{"t":"welcome","token":"...","memberId":"m1","mediaUrl":"...","state":{<state>}}
{"t":"state","eventId":7,"transport":"playing"|"held","position":12.3,
 "serverTime":"<ISO-8601 UTC>","mediaId":1,
 "media":{name,size,duration,url?}|absent,
 "members":[{"id","name","avatar","ready","inSet","buffered","stale"}]}
{"t":"feed","actor":"","action":"","target":"","reason":"","at":"<ISO-8601>"}
{"t":"chat","text":"...","from":"<name>"}
{"t":"kicked","reason":""}
{"t":"err","message":""}
```

- `welcome.token` is private to its owner and appears only in that member's
  media URL. `mediaUrl` is omitted when there is no media; it is a built
  `/m/...` URL for a host file (host part = what the client dialled), otherwise
  the shared link.
  `welcome.state` has the same shape as `state`.
- `state` is sent every second and on every change. `position` is the value at
  `serverTime`; clients extrapolate while `transport` is `playing`.
  `eventId` increases on seek, swap and transport changes.
  `mediaId` increases on swap.
- `feed.action` values: `ready`, `unready`, `force-ready`, `force-unready`,
  `force-play`, `force-hold`, `kick`, `join`, `leave`, `stale`, `swap`,
  `seek`, `pause`, `resume`, `chat`. `target` and `reason` are optional;
  `reason` carries `auto`/`manual` for ready and `silent too long` or
  `no signal` for leave/stale.
- Chat is delivered twice: a `chat` frame with the text and a textless
  `feed` with `action:"chat"`. Render the `chat` frame only; the reference
  client drops the textless feed entry.

## Join and reconnect

`hello` then `welcome`, then the app opens `mediaUrl`, seeks to the server
position and buffers. A joining member is `ready=false, inSet=false` until
the first `ready`. A socket that dies loses its token; reconnect is a fresh
`hello`, after which the client re-sends its prior ready flag.

## Reserved, not implemented

Server-held queue (`queue-add`, `queue-skip`) would auto-advance like a swap.
`RelayConstants.chunkBytes`, `creditWindowChunks`, `maxConcurrentOpen` and the
`open`, `ack`, `cancel`, `eof`, `buffered`, `state`, `event` kinds in
`MessageKind` are unused leftovers (the `state` frame does not use the enum).
