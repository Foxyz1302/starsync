# sync_relay_project

Watch-together desktop app (working title). One binary, three modes:

- **Client** — GUI Join, sync WS + mpv. No server code runs.
- **Server+Client (Host)** — GUI Host starts `packages/server` in-process,
  listens on a port, self-connects via loopback. Host must open ports.
  Clients never open ports.
- **Headless** — `watch.exe --headless`, same server package, no window.

v1 order: links support (shared http(s) media URL, Syncplay-style sync)
first, file relay (server-proxied bytes, whitelist case) after.
Jellyfin native + auto-update are deferred as their own undertakings.

Layout:

```
/packages/core      protocol, sync engine, messages (pure Dart, no Flutter)
/packages/server    room + media HTTP endpoint (pure Dart, no Flutter)
/apps/desktop       Flutter app embedding packages/server (the ONE binary)
/tool               spikes + harnesses (range_logger, shaper, fake_viewer, e2e_check)
/deploy             systemd unit, notes
/docs               PROTOCOL.md, ARCHITECTURE.md, mpv-http-contract.md, ROADMAP.md
```

Phases + status: `docs/ROADMAP.md`. Session handoff: `HANDOFF.md` (root).

Enforcement: `core` and `server` must have zero Flutter imports (tested).
