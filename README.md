# watch-together

Watch a video with friends, in sync, with the quality of a real mpv player.
Pick from your Jellyfin library, paste any direct video link, or pick a file on your own disk;
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

Home, Host tab. Pick what to watch (optional): Jellyfin (browse your linked
servers, see below), Link (paste an http(s) URL; Ctrl+V outside a field
pastes it in) or File (path or Browse). In the column beside it set a port and an optional password (blank =
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
updates, playing the next Jellyfin episode automatically, video shaders
(see below), and the keyboard shortcuts (read-only).
Integrations links Jellyfin servers (below). About shows the version.

Keys in a session: Space = ready / unready, Tab = side panel (people, log,
chat, change video), Left/Right = seek 10 s, F = fullscreen, Esc = close
panel or ask to leave, Ctrl+R = reload video, `<` / `>` or Shift+P /
Shift+N = previous / next Jellyfin episode, Ctrl+1..6 = Anime4K mode A, B,
C, A+A, B+B, C+A, Ctrl+0 = shaders off.

## Ports

| What | Default | Notes |
|---|---|---|
| Sync WebSocket and `/health` | TCP 8080 | plain `ws://`, no TLS |
| Local file streaming | same port | path `/m/...`, needs a session token |

Only the host needs the port reachable.

## Jellyfin

Integrations > Jellyfin > Add server: type the address, then sign in with
Quick Connect (the app shows a code; approve it in Jellyfin under Profile >
Quick Connect) or your username and password. Several servers can be
linked; each shows its status, and a star picks the default. Sign out
revokes the app's sign-in on the server. If a sign-in expires the server
shows "Reconnect" instead of disappearing.

The Host tab's Jellyfin source is a library browser: Continue watching (with
time left), Next up and the latest per library on the start page; library
grids with sort (name, date added, release date, rating, random) and
Unwatched / Favorites filters; series pages with seasons, episode progress
and a "Next up" button; details with the file's tracks; search. Clicking a
movie or episode picks it; the button in the top right enlarges the browser
and moves port, password and Host into a bar below it. On wide windows a
side pane shows details of whatever is under the mouse.

Keys in the browser: arrows move, Enter picks or opens, I = details,
Esc / Backspace / Alt+Left = back (Esc first clears a search), / or Ctrl+F =
search.

Host from the library: pick a movie or episode and Host. Only the item
goes to the server (which Jellyfin server and which item), never a link or
your sign-in. Pasting a Jellyfin link (web page or stream link) does the
same when the app can reach that Jellyfin; otherwise it is shared as a
plain link.

Watching:
- Everyone with their own account on that Jellyfin server plays the file
  directly with their own sign-in. Jellyfin tracks progress per account:
  your watched state, Continue watching and resume point follow what you
  saw (reported on start, every 10 s, on pause, resume, seek and track
  change, and when it stops).
- Friends without an account watch through the host: the server fetches
  the file with the host's sign-in and passes it on (only the current item,
  only to people in the session). They show "via host" in the member list.
  A dedicated server relays when started with `--jellyfin <file>` (see
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), Jellyfin relay).
- Without either, the app says "This needs a Jellyfin account on ..." with
  a button to link one; it plays as soon as you are signed in.

Episodes: the ⏮ / ⏭ buttons next to the controls (or `<` / `>`,
Shift+P / Shift+N) put up the previous or next episode for everyone. In
the last two minutes a "Next episode" button floats in the corner. When an
episode ends, a card shows what is next with Play next; with "Play the
next episode automatically" (Settings, on by default) it counts down 10 s
first, and Cancel stops it on your screen (seeking back stops it for
everyone). Anyone with an account can put the next one up; friends
watching via the host cannot.

Audio and subtitles: the subtitles button in the controls picks tracks.
Your choice is remembered per series (and as a default) and the closest
match (language, then title, then codec and channels) is selected on the
next episode. This is per person; nobody else is affected.

"Change video" in the session panel (Tab) opens the same picker as the Host
tab: the library starts on the series you are watching with the current
season, else where you left it. File is offered to the host only.

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
