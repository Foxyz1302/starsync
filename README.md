# watch-together

Watch a video with friends, in sync, with the quality of a real mpv player.
Paste a Jellyfin link, any direct video link, or pick a file on your own disk;
everyone's play, pause and seek stay together.

Why not Jellyfin SyncPlay: it runs in the browser and its sync is poor.
This is a desktop app that drives mpv.

Name: `watch-together` is a placeholder and the final name is undecided
(`sync-relay` is the working name). It appears in file names and the
update manifest until that is settled.

- Desktop only (Linux now, Windows planned), always mpv. No web clients.
- No transcoding. Everyone plays the original file.
- Friends trust model: no accounts, no roles. A blank password means an open server.

How it fits together: [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

## Install and update

Download the latest `watch-together-<version>-linux-x64.tar.gz` from the
Releases page of this repo, extract it, run `watch_together`.

Update from the app: when a newer version exists, an update indicator
appears in Home's top bar and opens the update card. "Update and restart" downloads,
verifies, applies in place and restarts; the install folder must be writable
by you. Settings has Check now and an auto-check toggle. From a terminal:
`watch_together --upgrade` or `update.sh` (shipped in the tarball). A
release with a newer protocol is a required update: everyone on a server
must run the same protocol version, and a mismatch is refused with a message
telling you to update.

## Host from the app

Home, Host tab. Pick what to watch (optional): Link (paste an http(s) URL;
Ctrl+V outside a field pastes it in) or File (path or Browse). Jellyfin is
coming. In the column beside it set a port and an optional password (blank =
anyone can join), then Host. Your name and avatar come from your profile
(the chip at the top left). The app starts a
server inside itself and joins it; you are the host and nobody can kick you.
Leaving or closing the app stops the server. Friends need to reach your machine: open
the TCP port on your router (or use a LAN or VPN address). Friends open nothing.

If you pick a local file, the server streams it to everyone from your disk.
Nothing is uploaded or stored anywhere.

## Dedicated server

For an always-on box (no display needed): the release tarball also contains
`watch-together-server`, a small standalone server without the app. Run it,
then everyone (you included) uses Join.

```
./watch-together-server --port 8080 --secret <password>
```

| Flag | Default | Meaning |
|---|---|---|
| `--port`, `-p` | 8080 | TCP port, all IPv4 interfaces |
| `--secret` | empty | password; empty = open server (a warning is printed) |
| `--name` | `server` | name reported by `/health` |
| `--media` | none | local file to serve as the starting video |
| `--advertise-host` | none | host put in file URLs instead of the one each viewer dialled |
| `--config` | none | YAML or JSON file with the same settings (`port`, `secret`, `name`, `mediaPath`, `advertiseHost`); replaces the flags |

It prints `READY port=... name=...` once listening and stops cleanly on
Ctrl+C or SIGTERM. A dedicated server has no host: anyone can kick anyone.
To run it as a service, unpack the tarball to `/opt/watch-together` and use
[deploy/watch-together.service](deploy/watch-together.service) (copy it to
`/etc/systemd/system/`, edit the flags, `systemctl enable --now watch-together`).

## Join

Home, Join tab. Enter the host's address, port, and the password if there
is one, then Enter or Join. Your name and avatar come from your profile (top
bar chip or Settings). Servers you got into appear as up to 6 Recent server
tiles with live status (online and how many are watching, or offline, plus
"needs update" when the server runs another protocol): click one to rejoin,
x to forget it. Ctrl+1 / Ctrl+2 switch between Join and Host.

## Settings

Profile, hardware decoding (auto, off or custom; the env var
`SYNC_RELAY_HWDEC` overrides it; applies on the next join or Reload video),
updates, video shaders (see below), and the keyboard shortcuts (read-only).
Integrations (Jellyfin) shows "coming soon". About shows the version.

Keys in a session: Space = ready / unready, Tab = side panel (people, log,
chat, change video), Left/Right = seek 10 s, F = fullscreen, Esc = close
panel or ask to leave, Ctrl+R = reload video, Ctrl+1..6 = Anime4K mode A, B,
C, A+A, B+B, C+A, Ctrl+0 = shaders off.

## Ports

| What | Default | Notes |
|---|---|---|
| Sync WebSocket and `/health` | TCP 8080 | plain `ws://`, no TLS |
| Local file streaming | same port | path `/m/...`, needs a session token |

Only the host needs the port reachable.

## Jellyfin

Pasting a Jellyfin direct-play link works today like any link. Proper
Jellyfin support (per-person login, watched status, library browsing) is
planned: see [docs/ROADMAP.md](docs/ROADMAP.md).

## Video quality and shaders

Each viewer can run mpv GLSL shaders on their own picture; nobody else is
affected. The app ships [Anime4K](https://github.com/bloc97/Anime4K) v4.0.1
(MIT) with the presets of its mpv guide: Mode A (1080p sources), B (720p),
C (480p), A+A, B+B, C+A, each as HQ (strong GPUs, GTX 1080 and up) or Fast
(the guide's low-end set). "Custom shaders" runs your own `.glsl` files.

Pick one with the ✨ button in the player's control bar (also in
fullscreen) or Ctrl+0..6; the change applies live and is saved, so the next
session starts with it. Settings → Video quality & shaders sets the default,
HQ or Fast (used by Ctrl+1..6) and the custom files. Shaders cost GPU time
every frame and need hardware video rendering: on media_kit's software
fallback they do nothing, and the app says so. A shader that is missing or
fails to load shows a toast and switches shaders off.

## Troubleshooting

- "host offline - check address and port": wrong address, or the port is not open.
- "wrong server password": password mismatch.
- "host runs a different version": update the app on both sides.
- Picture frozen but sound fine: Ctrl+R reloads the video; the app also does it automatically.
- Everyone waits at "waiting for X": X has not buffered 4 seconds yet or has not pressed Space.
- No Windows build yet.

For contributors: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md),
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/PROTOCOL.md](docs/PROTOCOL.md).
