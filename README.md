<p align="center">
  <img src="apps/desktop/assets/icon/icon_256.png" width="128" height="128" alt="Starsync icon">
</p>

<h1 align="center">Starsync</h1>

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
  `watch_together`. On start it adds itself to your app launcher (and its
  icon), so the window shows its own icon on Wayland. Needs mpv's library installed (`mpv` or `libmpv2`).
- Windows: `watch-together-<version>-windows-x64.zip`. Extract, run
  `watch_together.exe`. mpv is bundled. New and not yet tried on a real
  Windows desktop; reports welcome.

Update from the app: when a newer version exists, an update indicator
appears in the strip at the top of the window and opens the update card. "Update and restart" downloads,
verifies, applies in place and restarts; the install folder must be writable
by you. Settings has Check now and an auto-check toggle. From a terminal:
`./watch-together-server --upgrade` (no display needed, so it works on a
server box too), `watch_together --upgrade`, or the shipped `update.sh` /
`update.bat` (which run the first). Each updates the whole folder, app and
server; restart whichever is running to use the new version. A
release with a newer protocol is a required update: everyone on a server
must run the same protocol version, and a mismatch is refused with a message
telling you to update.

## Getting started

Three ways in, all at the top of the Library when you are not in a server.
None of them needs Jellyfin or an account.

- **Join a friend** (most people): your friend sends you an address and,
  maybe, a password. See [Join](#join).
- **Host**: you have the video and friends watch it with you. See
  [Host from the app](#host-from-the-app).
- **Watch solo**: just play something from the Library. It plays for you
  alone, with everything a server has (Jellyfin progress, next episode,
  skip buttons); nothing is reachable from outside this computer. Invite
  friends in the strip turns it into a hosted server (the Host card's port
  and password) and the video carries on from where it was; Stop ends it.

## The window

One window. Along the top, the strip: your avatar (click it for your
profile: name, picture with a crop editor, colour, and links to the
settings), the Library / Schedule / Settings tabs, and the party. Offline
the party side has Join a friend and Host; watching solo it says Solo,
with Invite friends and Stop; in a server it shows everyone's avatar
with a ring for their state (green ready, amber buffering, grey not ready,
dimmed reconnecting, dimmed with a moon sitting out; a crown on whoever
hosts, a tower on whoever passes the video on). Click the avatars for the
member list (force ready, Nudge, Sit out, "Copy invite address"; when you host it lists this computer's
network addresses with the port, and friends outside your network need
that port forwarded or a server they can all reach, like a VPS). Beside them the server and "ready n/m", the chat button with unread
count, and Leave. Empty strip space drags the window.

The player fills the window under the strip. Pick a tab and it shrinks to
a mini player in a corner: drag it anywhere and it snaps to the nearest
corner; double-click or ⤢ makes it big again, × sits you out (below) and
× again closes it; the strip's screen button brings it back. F or
double-click on the picture goes fullscreen (the strip hides, the party
shows in a corner while paused, the window buttons sit in the player's top
bar while its controls are up), Esc leaves it. The controls show the
show's cover, title and episode top left (a web video: its thumbnail and
name; guests get the art too; right-click to copy the title, or the link
when you have it, or open it in the browser or Jellyfin); before
a video first plays, its banner fills the picture until playback starts.
One pill bottom centre, just above the controls, says what playback waits for ("Press Space
when you're ready", "Waiting for Bob and Mika · 2/3 ready", "Bob is
loading…") or what went wrong, with Retry or Cancel when it helps. Chat and activity open in a panel on the right (chat button or
Tab), ready to type; it shows messages (select text to copy it, or
right-click for Copy message and, with a link in it, Copy link / Open in
browser), and its "Activity" toggle adds
joins, ready, seeks and the like between them. Joins, leaves, chat and
other news also pop up bottom left with the person's avatar; click a message to open the chat
(Settings → Notifications → Chat messages: Only when paused by default,
or All, or Off; messages always reach the chat). Unread chat shows as a count on the chat
buttons and, in fullscreen with the controls hidden and the video paused,
as a small chip top right.

Your name and picture change for everyone in the server right away; the
colour is yours only.

**Sitting out.** Step away without leaving: Sit out (your profile, your
row in the member list, or × on the mini player) unloads the video on your
end, and nobody waits for you any more; you stay in chat. Anyone can sit
anyone out, the host too ("Alice sat you out" tells you who). The player
then shows the cover, title and where the others are; Join back (or Space)
loads the video there and readies you. Settings → Party & network → "When idle,
sit out instead of just unready" does it after 10 idle minutes.

**Nudge.** Nudge in the member list pokes someone, sitting out or not:
only they hear it (a sound, a pop-up, and the taskbar entry asks for
attention when the window is in the background).

## Host from the app

Host in the strip: set a port and an optional password (blank = anyone can
join), then Host. The app starts a server inside itself and joins it; you
are the host (the crown). Nothing is up yet: pick what to
watch in the Library tab (below) and put it up. Leaving or
closing the app stops the server. Friends need to reach your machine: open
the TCP port on your router (or use a LAN or VPN address). Friends open
nothing. Ports you hosted on before are one click away in the Host card.

If you put up a local file, the server streams it to everyone from your
disk. Nothing is uploaded or stored anywhere.

## Library

What to watch, from three sources (the switch at the top). Drop a video,
a folder or a link anywhere on the window, or press Ctrl+V outside a
text field, and a small card asks how to open it (put it up, add it to
Up next, add the folder to Files, or fill Link).

- **Jellyfin**: your linked servers (see below); with none linked it
  points to Files and Link and offers Jellyfin as optional. Library chips beside the
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
  Right-click a card or an episode to copy its title or open it in
  Jellyfin's web page (the details panel has that button too).
- **Link**: paste an http(s) link: a video file, or a web page with a
  video (YouTube, X, and whatever else yt-dlp knows). The preview shows
  what it is (a page's title, uploader, length and thumbnail, else the
  file name); in a server, pick how the
  others get it (everyone fetches it, the server fetches it, or through
  you). Your last 12 links are listed under it (right-click one to copy
  or open it). A link seen before shows its preview at once, without
  asking the site again. A link that does not
  open here (needs cookies, 403, 404, not a video) says why and goes up
  only with "Put it up anyway"; in the player, whoever cannot play it is
  named ("Bob can't play this: Not allowed (403)") and nobody waits for them.
- **Files**: video folders you add on this computer, grouped by series
  (click a series to list its episodes), or any file through Browse. The others stream it from you.

Put it up and the player opens. Not in a server, the buttons say Play
and it plays for you alone ([Watch solo](#getting-started)).

### Up next (the queue)

In a server (solo too), anything can wait its turn instead of going up
now: **Add to queue** on the Link page (in the way you picked), or
right-click a Jellyfin card or episode, a video in Files, a recent link
or an episode on the Schedule for **Add to queue** / **Play next**; the
Jellyfin details panel has a queue button (right-click it to play next),
and the card for a dropped or pasted video or link has both. A link is
checked first, like Put it up. Every app keeps the next item ready,
its first seconds already loaded, so skipping to it starts at once.
For a link passed on, a member's file or a link the server fetches,
the server starts getting the next item while the current one plays
(from the app of whoever added it, or by fetching the link itself), so
everyone has its start before it goes up; whoever added it keeps the
app open for that. Everyone shares one Up next and anyone can change it; what
you added stays when you leave.

In the player, Up next sits in the top bar next to the chat button: the
next item's picture and title (or the next episode's). Rest the mouse on
it for a larger preview (who added it, its length, whether it is ready
to start); ⏭ plays it now, a click opens the queue: drag rows to reorder, hover a
row to play it now (▶) or remove it (×), right-click it for more (copy its
title or link, open it in the browser or in Jellyfin). To add, press
Ctrl+V with the queue open (a copied link or video file goes in at once,
its title and picture showing while it is checked), type one after
**+ Add link**, or drop a link or a video on it. When a video ends, a card shows
what is up next with a 10 s countdown (Cancel stops it on your screen)
and it plays; `>` or Shift+N plays it at once. Under the queue,
**Continues with** shows the next episodes of the Jellyfin series
playing (greyed: they play only once Up next is empty); **+** adds one,
**Clear** drops them for this episode.

A link you pass on ("through me") or a file of yours can only be played
by your app: if you left when its turn comes, it is skipped ("Skipped …:
Foxyz left"). A Jellyfin item needs someone with an account on that
server. Up next is kept by the server while it runs; restarting the
server empties it.

## Schedule

The week's airing anime, one column per day (AniList), each episode
marked with what the Jellyfin server has of it when AnimeFlow is
connected (Settings, Jellyfin & integrations): **on Jellyfin** (Put it
up, right-click to queue), **downloading**, **waiting for release**
(aired in Japan, AnimeFlow downloads it by itself once a release
appears), **failed**, **not monitored** (Request asks AnimeFlow for it),
or the time left until it airs. A show AnimeFlow does not follow can be asked for with **Request
series**. Episodes you already watched on Jellyfin carry a check on the
cover; one you started shows how far you got.

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
| `--[no-]yt-dlp` | on | read web pages (YouTube, X, …) with yt-dlp when the server fetches a link |
| `--yt-dlp-dir` | next to the binary | writable folder for the server's yt-dlp (systemd: the unit's `StateDirectory`) |
| `--yt-dlp-cookies` | none | cookies.txt or cookie-extension JSON export for that yt-dlp (sites that refuse guests); copied into the yt-dlp folder at start, removed from it when not given. **An account login**: keep it private, use a throwaway account for YouTube |
| `--config` | none | YAML or JSON file with the same settings (`port`, `secret`, `name`, `mediaPath`, `advertiseHost`, `ytDlp`, `ytDlpDir`, `ytDlpCookies`); replaces the flags |
| `--upgrade` | | update the install folder to the latest release ([Install and update](#install-and-update)), then exit |
| `--check-update` | | print whether a newer release exists, then exit |

It prints `READY port=... name=...` once listening and stops cleanly on
Ctrl+C or SIGTERM. A dedicated server has no host.
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
volume and sound set, and every sound with a preview, its own set and a switch); Updates; Keyboard shortcuts (read-only); About
(the version; resting the mouse on the Settings tab shows it too).

Player settings live in the player: ⚙ at the right end of its controls
(both designs) opens them, and Settings → Player has the same ones (plus
the custom shader files). Player design: Standard or uosc (below);
progress line when hidden (on by default: a 2 px line at the bottom of
the video while the controls are hidden); upscaling shader (see below);
hardware decoding (auto, off or custom; the env var `SYNC_RELAY_HWDEC`
overrides it); in the player also the subtitle and audio track. Every
change applies right away.

Anywhere in a server (unless you are typing): Space = ready / unready,
Tab = chat & activity (Tab never moves between buttons). Keys while the
player fills the window: Left/Right = seek 10 s, Up/Down = volume, Shift+Right = skip 1:30,
PgUp/PgDn = previous / next chapter (as in mpv), F = fullscreen, Esc =
close the chat, then fullscreen, then shrink the player to mini; from the
mini it asks to leave, Ctrl+R = reload video,
`<` / `>` or Shift+P / Shift+N = previous / next Jellyfin episode,
Ctrl+1..6 = Anime4K mode A, B, C, A+A, B+B, C+A, Ctrl+0 = shaders off.
Every seek, skip and chapter jump moves everyone.

Controls: the seek bar marks chapter starts with a diamond; hovering it
shows the time and the chapter title. The chapters button lists them
(current one checked; click to jump). "1:30" skips ahead 1:30. Audio and
Subtitles buttons (with the track count) list tracks as "Japanese · E-AC3
2.0 · title"; subtitles have Off. Volume (scroll anywhere on the video,
hover the speaker, or Up/Down) goes to 150 % like mpv: past the tick at
100 % the bar turns amber and mpv amplifies; a scroll or key shows the
volume for a moment. Lists and menus under the mouse scroll as usual.

The uosc player design (⚙ → Player design, Standard by default,
switches right away): video controls modeled on mpv's uosc theme. A
translucent timeline across the bottom marks the position with a thin
line, hatches the part not downloaded yet, shows chapter starts as
diamonds (click one to jump), the elapsed time left, the time remaining
right and, while less than a minute is buffered, the buffered seconds
next to the position; hovering it shows the time there and the chapter
title. With the controls hidden it stays as a thin line (unless
"Progress line when hidden" is off). Above it flat buttons: ≡ menu, Subtitles and Audio (with the
track count), the shader badge (the active Anime4K mode, e.g. "A HQ"),
ready, chapters, 1:30, previous / next episode, change video, volume, ⚙
and fullscreen; the title top left, Up next, chat and back-to-library top right. Keys and skip buttons work
the same.

Skipping: during the opening a "Skip OP" button shows bottom right, just
above the controls (it
jumps to the end of the opening), during the ending "Skip ED" (to the end
of the ending only; what comes after is yours to skip). "Skip OP" and
"Skip 1:30" show for 5 seconds when they come up, then only while the
controls are up (move the mouse); "Skip ED" and "Next episode" show only
while the controls are up. The opening and
ending come from Jellyfin's intro / outro segments when your Jellyfin has
them (needs a segment plugin, e.g. Intro Skipper), else from chapter names
(OP, Opening, Intro / ED, Ending, Credits, Outro). Without an opening or
any chapters, on anything longer than 20 minutes, "Skip 1:30" floats there
during the first 6 minutes.

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
  change, and when it stops). Watched means you actually played most of
  it (or reached the ending after half), not where you stopped: opening
  a watched episode to check a moment keeps it watched, and a quick peek
  leaves no resume point.
- Friends without an account watch through the server: whoever put the
  item up passes it on automatically, with their own sign-in, which never
  leaves their computer (only the current item, only to people in the
  session). They show "via server" in the member list (click the avatars). When the app hosts,
  or a dedicated server has its own login (`--jellyfin <file>`, see
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), Jellyfin relay), the server
  fetches it itself instead.
- If nobody can pass it on (the person who put it up left), the app says
  "No Jellyfin account here for ..." with a button to link one; it plays as
  soon as you are signed in.

Episodes: the ⏮ / ⏭ buttons next to the controls (or `<` / `>`,
Shift+P / Shift+N) put up the previous or next episode for everyone. From
the ending (when it is known, see Skipping above; else in the last two
minutes) a "Next episode" button floats in the corner while the controls
are up. When an
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
are quick). Keep the app open while it plays. A link goes up "Through
me": your computer opens it and passes it on, so it plays for everyone
whenever it plays for you (you can't tell ahead which sites want cookies,
and YouTube may start asking any day). Under "Other ways" there are two more:
- Everyone fetches it: each app plays the link itself.
- Server fetches it: the server downloads it once for everyone, for links
  that are slow or blocked for some. The server must be able to reach it,
  and it must have a password (an open server refuses: anyone could make
  it fetch addresses only it can reach).

Web pages work in all three: the app and the dedicated server each
download [yt-dlp](https://github.com/yt-dlp/yt-dlp) by themselves (checked
against the release's checksums, updated once a day; Settings → Player
shows its version and has "Update now"), so there is nothing to install.
Sites that refuse guests (Bilibili answers "HTTP Error 412", YouTube may
ask to sign in) need cookies: Settings → Player → yt-dlp → Cookies reads
them from a browser, or from a cookies.txt or a cookie extension's JSON
export (picked or dropped; every site in it is kept). They stay on this
computer and are used by its yt-dlp only (your own playback, "through
me", and a server you host). Cookies log yt-dlp in as you on those
sites: keep the file private, and for YouTube consider a throwaway
account (Google may flag accounts used with yt-dlp).
YouTube works in all three too, and so do pages and links that only
offer streaming playlists (HLS `.m3u8`, DASH `.mpd`, the HLS of X videos).
Through me and Server fetches it never show the link to anyone; they can't pass on live
streams or DRM-protected video (use "Everyone fetches it" for live).
Your upload has to beat the video's bitrate: a 25-minute 2 GB episode is
about 11 Mbit/s.

The member list (click the avatars) shows where the video comes from on
top: who passes it on, or that the server fetches it, everyone plays the
link, or everyone streams it from Jellyfin, with how many watch through
the server and, for a relay, how fast it arrives against what the video
needs (the bar's mark; past it is keeping up). It turns amber when the
source is too slow or reconnecting, red when it left (the others play
out what the server already has), and whoever passes it on is told once
when their upload is too slow. Each member's line says how they get it
("via server" with their speed, or "direct") after a dot for their
buffer: green enough to play on, amber low, red empty. A red dot on one
member while the source keeps up is their own connection.

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
- Picture frozen but sound fine: Ctrl+R reloads the video.
- Everyone waits at "waiting for X": X has not buffered 4 seconds yet or has not pressed Space.
- Windows: the build is new; if something is off there, say so.

For contributors: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md),
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/PROTOCOL.md](docs/PROTOCOL.md).
