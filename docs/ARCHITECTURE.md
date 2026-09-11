# ARCHITECTURE

One binary, three modes. `packages/server` (Relic) is embedded, not a separate product.

- **Client**: GUI Join, sync WS client (`web_socket_channel` in `packages/core`) + mpv. No server code runs.
- **Server+Client (Host)**: GUI Host starts `packages/server` in-process, binds port, self-connects via loopback. Host opens ports, runs traffic. Clients open nothing outbound-only.
- **Headless**: `--headless`, same server package, no window/player init.

Server side: **Relic** (HTTP + built-in WS). Client side WS: **`web_socket_channel`**
(Relic has no client; server WS handling stays in Relic).

Media order (locked): links first (shared http(s) URL, Syncplay-style sync),
file relay after (server-proxied bytes for the whitelist case).

## Media paths (links vs file relay)

Two ways to watch, same sync engine, same Range endpoint:

1. **Links (primary, shipped):** host shares an http(s) media URL
   (e.g. a Jellyfin Download URL). Viewers stream it directly; the
   server is sync-authority only (`media.url`, no `mediaUrl`). This
   covers most sessions — proxying is usually unnecessary.
2. **File relay (secondary, local-file half shipped):** host serves
   bytes from their own machine through the server's token-gated
   Range endpoint `GET /m/<sid>/<token>/<name>`. Viewers (and the
   host via loopback) play the server URL. This is the fallback for
   the whitelist case: viewers cannot reach the source, but the
   server/host can (e.g. Jellyfin allowlists the host, not the
   viewers). No server storage — bytes stream file→socket, config +
   logs only, never to disk.

Backends behind `MediaSource` (`packages/core/lib/src/media_source.dart`):
`FileMediaSource` (local file — SHIPPED, wired into
`mountSessionMediaRoute`); `HttpSource` (server fetches a remote URL
and re-serves it — DEFERRED, Phase 8). `resolveMediaRequest` stays
framework-agnostic so both ride the same tested Range table.

## Deferred: remote-host upload tunnel (NOT active protocol)

If a VPS tier ever needs a *remote* host to push bytes to a server
it cannot serve from disk, the reserved design is the brief's WSS
tunnel: host dials out, JSON control frames
(`hello`/`welcome`+mediaUrl, `open`{id,start,end}, `ack`, `cancel`,
`eof`/`err`) plus binary `[u32 BE reqId][payload]` chunks —
chunk 256 KiB, credit window 8 (≈2 MiB in flight), max 16 concurrent
`open`, relay acks only after socket flush (real backpressure).
`RelayConstants.chunkBytes/creditWindowChunks/maxConcurrentOpen`
are reserved for this. No code exists; direct-serve covers v1
(host IS the server, opens ports itself).

Host playback goes through loopback like everyone else's
(`http://127.0.0.1:<port>/…`) — same code path as remote viewers, so
server bugs surface on the host screen first. Deployment ladder,
cheapest first: host's own PC (LAN, or internet with port-forward) →
same binary `--headless` on a friend's always-on box → cheap VPS
(CGNAT escape; TLS/Caddy deferred with this tier).

Sync: heavily Syncplay-inspired + original readiness design, NOT 1:1
(audit done; deviations: clock never moves from reports, no
pause-on-leave, force-for-all, quorum gate — see HANDOFF §2).
Additive namespaced extensions only, `proto` bump + `PROTOCOL.md` same-commit.

No server storage: config + logs only. Media never touches disk.

## Health reporting (standing rule)

Every failure must display. Nothing stalls silently.

- Server `/health` returns machine-readable status: ok, room, viewer
  count, uptime, media, bytes served, version. The app reads it.
- App surfaces all failure states in UI with cause + what-to-do:
  connecting/reconnecting, wrong secret (401), kicked (403), session
  gone (410), host offline / buffering (503), starvation
  ("waiting for X — N.N s buffered"). Backed by a structured status
  signal (severity + message), not bare strings.
- Errors log via `debugPrint` + stack trace at the boundary, then
  convert to a displayable state. No swallowed exceptions.
