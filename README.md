# watch-together

Watch a video with friends, in sync, with the quality of a real mpv player.
Pick from your Jellyfin library, paste any direct video link, or pick a file on your own disk;
everyone's play, pause and seek stay together.

Why not Jellyfin SyncPlay: it runs in the browser and its sync is poor.
This is a desktop app that drives mpv.

Name: `watch-together` is a placeholder and the final name is undecided
(`sync-relay` is the working name). It appears in file names and the
update manifest until that is settled.

- Desktop only (Linux and Windows), always mpv. No web clients.
- No transcoding. Everyone plays the original file.
- Friends trust model: no accounts, no roles. A blank password means an open server.

How it fits together: [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

## Install and update

From the Releases page of this repo:

- Linux: `watch-together-<version>-linux-x64.tar.gz`. Extract, run
  `watch_together`. Needs mpv's library installed (`mpv` or `libmpv2`).
- Windows: `watch-together-<version>-windows-x64.zip`. Extract, run
  `watch_together.exe`. mpv is bundled. New and not yet tried on a real
  Windows desktop; reports welcome.

Update from the app: when a newer version exists, an update indicator
appears in the strip at the top of the window and opens the update card. "Update and restart" downloads,
verifies, applies in place and restarts; the install folder must be writable
by you. Settings has Check now and an auto-check toggle. From a terminal:
`watch_together --upgrade`, or the shipped `update.sh` / `update.bat`. A
release with a newer protocol is a required update: everyone on a server
must run the same protocol version, and a mismatch is refused with a message
telling you to update.

## The window

One window. Along the top, the strip: your avatar (click it for your
profile: name, picture with a crop editor, colour, and links to the
settings), the Library / Schedule / Settings tabs, and the party. Offline
the party side has Join and Host; in a server it shows everyone's avatar
with a ring for their state (green ready, amber buffering, grey not ready,
dimmed reconnecting; a crown on whoever hosts, a tower on whoever
passes the video on). Click the avatars for the member list (force ready,
kick, "Copy invite address"; when you host it lists this computer's
network addresses with the port, and friends outside your network need
that port forwarded or a server they can all reach, like a VPS). Beside them the server and "ready n/m", the chat button with unread
count, and Leave. Empty strip space drags the window.

The player fills the window under the strip. Pick a tab and it shrinks to
a mini player in a corner: drag it anywhere and it snaps to the nearest
corner; double-click or ⤢ makes it big again, × stops watching (you stay in
the server, muted) and the strip's screen button brings it back. F or
double-click on the picture goes fullscreen (the strip hides, the party
shows in a corner while paused, the window buttons sit in the player's top
bar while its controls are up), Esc leaves it. The controls show the
show's cover, title and episode top left (guests get the cover too); before
a video first plays, its banner fills the picture until playback starts.
One pill above the controls says what playback waits for ("Press Space
when you're ready", "Waiting for Bob and Mika · 2/3 ready", "Bob is
loading…") or what went wrong, with Retry or Cancel when it helps. Chat and activity open in a panel on the right (chat button or
Tab); joins, leaves, chat and other news also pop up bottom left with the
person's avatar.

Your name and picture change for everyone in the server right away; the
colour is yours only.

## Host from the app

Host in the strip: set a port and an optional password (blank = anyone can
join), then Host. The app starts a server inside itself and joins it; you
are the host and nobody can kick you. Nothing is up yet: pick what to
watch in the Library tab (below) and put it up. Leaving or
closing the app stops the server. Friends need to reach your machine: open
the TCP port on your router (or use a LAN or VPN address). Friends open
nothing. Ports you hosted on before are one click away in the Host card.

If you put up a local file, the server streams it to everyone from your
disk. Nothing is uploaded or stored anywhere.

## Library

What to watch, from three sources (the switch at the top; Ctrl+V outside
a field pastes a link into Link):

- **Jellyfin**: your linked servers (see below). Library chips beside the
  switch, then one **Continue** row (what you were watching and what comes
  next, one card per series, the one you watched most recently first;
  series not touched for two months drop out) and **Latest in** each
  library (one card per series: "S1E1" or "3 new"; Show all opens the
  library newest first). Re-uploads (added long after they aired) are
  hidden from Latest; the row's ⋮ menu turns that off. Search (/), library
  grids (sort, unwatched, favourites) and series pages sit behind them.
  Click a card to select it: its
  details open on the right with "Put it up · S1E3", mark watched /
  unwatched, remove from Continue and the episode list (click an episode
  to choose it). Double-click a card or an episode to put it up at once.
- **Link**: paste an http(s) link. The preview shows what it is (title and
  thumbnail for YouTube, else the file name); in a server, pick how the
  others get it (everyone fetches it, the server fetches it, or through
  you). Your last 12 links are listed under it.
- **Files**: video folders you add on this computer, grouped by series,
  or any file through Browse. The others stream it from you.

Put it up and the player opens. Offline the library browses but nothing
goes up until you join or host ("Join or host to watch together").

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

Join in the strip. Servers you got into are listed first (up to 6), with
live status (online and how many are watching, or offline, plus "needs
update" when the server runs another protocol): click one to rejoin, x to
forget it. Or enter the host's address, port, and the password if there
is one, then Enter or Join. Your name and picture come from your profile
(your avatar at the top left).

## Settings

The Settings tab (Ctrl+,) has a page per topic, each setting with a line
of help: Profile; Party & network (the Host card's default port and
password, recent servers with remove); Player (below); Jellyfin &
integrations (linked Jellyfin servers, below, the AnimeFlow connection:
"connected as <name>" with what you may do, or why not, and playing the
next episode automatically); Notifications & sounds (what pops up; the sound
volume, and every sound with a preview and its own switch); Updates; Keyboard shortcuts (read-only); About
(the version).

Player settings live in the player: ⚙ at the right end of its controls
(both designs) opens them, and Settings → Player has the same ones (plus
the custom shader files). Player design: Standard or uosc (below);
progress line when hidden (on by default: a 2 px line at the bottom of
the video while the controls are hidden); upscaling shader (see below);
hardware decoding (auto, off or custom; the env var `SYNC_RELAY_HWDEC`
overrides it); in the player also the subtitle and audio track. Every
change applies right away.

Keys while the player fills the window: Space = ready / unready, Tab =
chat & activity, Left/Right = seek 10 s, Shift+Right = skip 1:30,
PgUp/PgDn = previous / next chapter (as in mpv), F = fullscreen, Esc =
close the chat or fullscreen, else ask to leave, Ctrl+R = reload video,
`<` / `>` or Shift+P / Shift+N = previous / next Jellyfin episode,
Ctrl+1..6 = Anime4K mode A, B, C, A+A, B+B, C+A, Ctrl+0 = shaders off.
Every seek, skip and chapter jump moves everyone.

Controls: the seek bar marks chapter starts with a diamond; hovering it
shows the time and the chapter title. The chapters button lists them
(current one checked; click to jump). "1:30" skips ahead 1:30. Audio and
Subtitles buttons (with the track count) list tracks as "Japanese · E-AC3
2.0 · title"; subtitles have Off.

The uosc player design (⚙ → Player design, Standard by default,
switches right away): video controls modeled on mpv's uosc theme. A thick
timeline across the bottom shows the played part, the cached part ahead
(hatched), chapter starts as diamonds and the time; hovering it shows the
chapter title and the time there. With the controls hidden it stays as a
thin line (unless "Progress line when hidden" is off). Above it flat buttons: ≡ menu, Subtitles and Audio (with the
track count), the shader badge (the active Anime4K mode, e.g. "A HQ"),
ready, chapters, 1:30, previous / next episode, change video, volume, ⚙
and fullscreen; the title top left, chat and back-to-library top right. Keys and skip buttons work
the same.

Skipping: during the opening a "Skip OP" button floats in the corner (it
jumps to the end of the opening), during the ending "Skip ED" (to the end
of the ending only; what comes after is yours to skip). The opening and
ending come from Jellyfin's intro / outro segments when your Jellyfin has
them (needs a segment plugin, e.g. Intro Skipper), else from chapter names
(OP, Opening, Intro / ED, Ending, Credits, Outro). Without an opening, on
anything longer than 20 minutes, "Skip 1:30" floats there during the first
6 minutes.

## Ports

| What | Default | Notes |
|---|---|---|
| Sync WebSocket and `/health` | TCP 8080 | plain `ws://`, no TLS |
| Local file streaming | same port | path `/m/...`, needs a session token |

Only the host needs the port reachable.

## Jellyfin

Settings > Jellyfin & integrations > Add server: type the address, then sign in with
Quick Connect (the app shows a code; approve it in Jellyfin under Profile >
Quick Connect) or your username and password. Several servers can be
linked; each shows its status, and a star picks the default. Sign out
revokes the app's sign-in on the server. If a sign-in expires the server
shows "Reconnect" instead of disappearing.

The Library's Jellyfin source is a library browser: Continue watching (with
time left), Next up and the latest per library on the start page; library
grids with sort (name, date added, release date, rating, random) and
Unwatched / Favorites filters; series pages with seasons, episode progress
and a "Next up" button; details with the file's tracks; search. Clicking a
movie or episode picks it. On wide windows a side pane shows details of
whatever is under the mouse.

Keys in the browser: arrows move, Enter picks or opens, I = details,
Esc / Backspace / Alt+Left = back (Esc first clears a search), / or Ctrl+F =
search.

Putting up a movie or episode sends only the item to the server (which
Jellyfin server and which item), never a link or your sign-in. Pasting a Jellyfin link (web page or stream link) does the
same when the app can reach that Jellyfin; otherwise it is shared as a
plain link.

Watching:
- Everyone with their own account on that Jellyfin server plays the file
  directly with their own sign-in. Jellyfin tracks progress per account:
  your watched state, Continue watching and resume point follow what you
  saw (reported on start, every 10 s, on pause, resume, seek and track
  change, and when it stops).
- Friends without an account watch through the server: whoever put the
  item up passes it on automatically, with their own sign-in, which never
  leaves their computer (only the current item, only to people in the
  session). They show "via host" in the member list (click the avatars). When the app hosts,
  or a dedicated server has its own login (`--jellyfin <file>`, see
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), Jellyfin relay), the server
  fetches it itself instead.
- If nobody can pass it on (the person who put it up left), the app says
  "No Jellyfin account here for ..." with a button to link one; it plays as
  soon as you are signed in.

Episodes: the ⏮ / ⏭ buttons next to the controls (or `<` / `>`,
Shift+P / Shift+N) put up the previous or next episode for everyone. From
the ending (when it is known, see Skipping above; else in the last two
minutes) a "Next episode" button floats in the corner. When an
episode ends, a card shows what is next with Play next; with "Play the
next episode automatically" (Settings, on by default) it counts down 10 s
first, and Cancel stops it on your screen (seeking back stops it for
everyone). Anyone with an account can put the next one up; friends
watching via the host cannot.

Audio and subtitles: the Audio and Subtitles buttons in the controls pick tracks.
Your choice is remembered per series (and as a default) and the closest
match (language, then title, then codec and channels) is selected on the
next episode. This is per person; nobody else is affected.

"Change video" in the player's controls opens the Library tab (the player
goes mini): the library starts on the series you are watching with the
current season, else where you left it.

Anyone can put up a file from their own computer, also on a dedicated
server: it streams from your computer through the server to everyone (the
server keeps a few minutes in memory, so seeks and skipping the opening
are quick). Keep the app open while it plays. For a link you choose how
the others get it:
- Everyone fetches it (default): each app plays the link itself.
- Server fetches it: the server downloads it once for everyone, for links
  that are slow or blocked for some. The server must be able to reach it,
  and it must have a password (an open server refuses: anyone could make
  it fetch addresses only it can reach).
- Through me: your computer downloads it and passes it on, for links only
  you can open.

The last two need a link to a video file (not a page like YouTube) and
never show the link to anyone. Your upload has to beat the video's
bitrate: a 25-minute 2 GB episode is about 11 Mbit/s.

## Video quality and shaders

Each viewer can run mpv GLSL shaders on their own picture; nobody else is
affected. The app ships [Anime4K](https://github.com/bloc97/Anime4K) v4.0.1
(MIT) with the presets of its mpv guide: Mode A (1080p sources), B (720p),
C (480p), A+A, B+B, C+A, each as HQ (strong GPUs, GTX 1080 and up) or Fast
(the guide's low-end set). "Custom shaders" runs your own `.glsl` files.

Pick one with the ✨ button in the player's control bar (also in
fullscreen) or Ctrl+0..6; the change applies live and is saved, so the next
session starts with it. The player's ⚙ and Settings → Player set it too,
with HQ or Fast (used by Ctrl+1..6); Settings → Player holds the custom
files. Shaders cost GPU time
every frame and need hardware video rendering: on media_kit's software
fallback they do nothing, and the app says so. A shader that is missing or
fails to load shows a toast and switches shaders off.

## Troubleshooting

- "host offline - check address and port": wrong address, or the port is not open.
- "wrong server password": password mismatch.
- "host runs a different version": update the app on both sides.
- Picture frozen but sound fine: Ctrl+R reloads the video; the app also does it automatically.
- Everyone waits at "waiting for X": X has not buffered 4 seconds yet or has not pressed Space.
- Windows: the build is new; if something is off there, say so.

For contributors: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md),
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/PROTOCOL.md](docs/PROTOCOL.md).
