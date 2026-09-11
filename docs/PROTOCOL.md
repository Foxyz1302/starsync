# PROTOCOL — v4 (Phase 3: sync engine + readiness)

`proto = 4`. Bump history: v1 hello/state/event shapes; v2 `token` in
welcome; v3 `kicked`/`kick`; v4 readiness intents, room fan-out, feed,
public member ids (tokens never leave their owner — media URLs carry
only the requester's own token).

## Transport vs readiness (the core split)

Room transport is PLAYING or HELD. Seeks move transport position only:
while PLAYING anyone seeks freely, everyone follows, catch-up buffering
is tolerated with no flag changes. Readiness gates only the
HELD→PLAYING transition. Starvation pauses transport without touching
flags; recovery auto-resumes on buffers, no Space needed.

## Message catalog

Client→server intents (all post-hello text frames):

```
{"t":"ready","ready":true,"source":"manual|auto"}   Space flip / idle timer
{"t":"force","target":"all|<memberId>","ready":false}
{"t":"seek","position":123.4}                        doSeek event, room jumps
{"t":"swap","media":{"name":..,"size":..,"duration":..,"url":..}}
{"t":"report","position":123.1,"buffered":6.2,"eventId":41}
{"t":"chat","text":"…"}
{"t":"kick","target":"<memberId>","reason":"…"}      v3, now by member id
```

Server→client:

```
{"t":"room",{eventId,transport:"playing"|"held",position,serverTime,
  mediaId,media:{…}|null,
  members:[{id,name,avatar,ready,inSet,buffered,stale}]}}
{"t":"feed",{actor,action,target?,reason?,at}}       toasts + sheet log
{"t":"welcome",{token,memberId,mediaUrl?,state}}   v2+4, state now a room
{"t":"kicked",{reason}}  {"t":"err",{message}}
```

`room` broadcasts at 1 Hz and on every change. Clients diff by
`eventId`: position jump ⇒ seek, transport change ⇒ play/pause.
`feed` actions: ready, unready, force-ready, force-unready, force-play,
force-hold, kick, join, leave, stale, swap, seek, pause, resume, chat —
every one carries actor + server timestamp.
Force-play-all is `force` with `target:"all",ready:true`; anyone not
ready Spaces back. Sounds key off feed actions.

## Membership set (kills join-cascade + ghost-quorum)

- Join: `inSet=false, ready=false`. Catch up in background (open media,
  seek to room edge, buffer). Flipping ready joins the set.
- Unready while in set: stays in set, room re-evaluates → HELD.
- Disconnect: removed from set, never counts toward quorum.
- Swap: all sets cleared, all flags false.
- Gate to PLAYING: set non-empty AND every in-set member
  ready + buffered ≥ 4 s + fresh (not stale) AND quorum: in-set
  size ≥ 2, unless no more than one member is fresh. A lone
  watcher can play alone; the moment a second watcher is present,
  one Space waits for the other. Empty set ⇒ HELD.

## Clock rules (Syncplay port)

Server owns the advancing clock:
`positionAt(now) = position + (playing ? now-serverTime : 0)`.
Plain reports are informational and can never move it. Only seek, swap,
and gate transitions write position/serverTime/eventId. Reports tagged
with `eventId < current` have their position ignored (no ping-pong);
buffered is still accepted. Pause (HELD) freezes position immediately;
resume sets serverTime=now — laggards seek forward, never drag back.

Tiered client correction on room state: |drift| > 5 s ⇒ seek;
ahead > 1.5 s ⇒ 0.95× until level; inside deadzone ⇒ nothing.

## Join state machine

connect → hello → welcome → open media (server mediaUrl or shared
url) → seek to room edge → buffer → not-ready catch-up → Space →
in set → HELD→PLAYING when gate passes. Reconnect: re-hello (tokens
die with the socket), prior flag restored, buffer gate holds playback
until truly caught up.

## Swap state machine

anyone sends swap → HELD, mediaId++, clock reset (0/now), sets
cleared, flags false → all clients re-run Join → auto-resume when the
gate passes. No authority check in v1 (same trust basis as force).

## Join / auth (v2–v3, unchanged)

proto must equal server proto; secret is the room password; avatar
≤64 KiB; failures get `err` + close. `sid="default"`, map keyed for
later multi-session. mediaUrl only when the server holds bytes.

## Media endpoint (Phase 1, unchanged)

`GET /m/<sid>/<token>/<name>` Range table. 410/401/403/503 gates.

## Heartbeat (Phase 2 baseline, feeds the gate)

5 s WS pings; per-token lastSeen on every frame; silent >15 s ⇒ out
of the gate (`stale` feed); silent >30 s ⇒ socket closed, member
removed (`leave`), client reconnects via re-hello. No limbo sockets.
Closed sockets are swept every second (`isClosed` poll — transport
`onDone` is unreliable, so presence never depends on it).
Client-side reconnect loop (fixed polite interval + manual escape)
is app work.

## Playlist (deferred, space reserved)

Not v1. Shape when it lands: server-held `queue:[media…]` alongside
the current media; anyone appends links (`queue-add`), anyone skips
(`queue-skip`); reaching EOF auto-advances exactly like a swap
(HELD, mediaId++, sets cleared, Join rerun, gate resumes). No code
until then — `mediaId` + swap already carry it.
