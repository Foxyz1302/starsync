<p align="center">
  <img src="apps/desktop/assets/icon/icon_256.png" width="128" height="128" alt="Starsync icon">
</p>

<h1 align="center">Starsync</h1>

Watch a video with friends, in sync, with the quality of a real mpv player.
Pick from your Jellyfin library, paste any direct video link, or pick a file on your own disk;
everyone's play, pause and seek stay together.

Why not Jellyfin SyncPlay: it runs in the browser and its sync is poor.
This is a desktop app that drives mpv.

- Desktop only (Linux and Windows), always mpv. No web clients.
- No transcoding. Everyone plays the original file.
- Friends trust model: no accounts, no roles. A blank password means an open server.

**Download**: the [latest release](https://github.com/Foxyz1302/starsync/releases/latest)
(Linux `.tar.gz`, Windows `.zip`), also on [foxyz.ru](https://foxyz.ru).
Unpack and run; see [Install and update](#install-and-update).

**Build it yourself**: the Flutter SDK (beta channel); on Linux also clang,
cmake, ninja, pkg-config, `libgtk-3-dev` and `libmpv-dev`; on Windows Visual
Studio with its C++ desktop workload.

```
git clone https://github.com/Foxyz1302/starsync && cd starsync/apps/desktop
flutter pub get && flutter run -d linux    # or: -d windows
```

Release builds, tests and the rest: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
How it fits together: [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

**License**: MIT, see [LICENSE](LICENSE). What Starsync is built on, with
its licenses: Settings → Help & about → Open-source licenses in the app,
and `THIRD_PARTY_LICENSES.txt` in each download.

Up to 1.2.x the app was called `watch_together` (its files
`watch-together-*`).

## Install and update

From the Releases page of this repo:

- Linux: `starsync-<version>-linux-x64.tar.gz`. Extract, run
  `starsync`. On start it adds itself to your app launcher (and its
  icon), so the window shows its own icon on Wayland. Needs mpv's library installed (`mpv` or `libmpv2`).
- Windows: `starsync-<version>-windows-x64.zip`. Extract, run
  `starsync.exe`. mpv is bundled. New and not yet tried on a real
  Windows desktop; reports welcome.

Your data (settings, sign-ins, folders, logs, yt-dlp and its cookies) lives
in `~/.local/share/dev.foxyz.starsync` on Linux and
`%APPDATA%\foxyz\Starsync` on Windows. The first start after 1.2.x copies
it over from the old places (`~/.local/share/moe.senkochan.watch_together`
or `%APPDATA%\com.example\watch_together`, and the app's files in your
Documents folder) and leaves the originals where they were.

Update from the app: the app looks for a new version at start and every
few hours, and when one exists a band across the top of the window says so
(never over a playing video), with its highlights. "What's new" shows
them, with every change behind "All changes" ([CHANGELOG.md](CHANGELOG.md));
the first start after an update shows it once, and Settings → Help & about
has it again. "Update and
restart" downloads, verifies, applies in place and restarts; "Later" hides
it until the next check; the install folder must be writable by you. The version you run is
at the bottom of every Settings page (and in the Settings tab's tooltip). Settings → Updates has Check now. From a terminal:
`./starsync-server --upgrade` (no display needed, so it works on a
server box too), `./starsync --upgrade`, or the shipped `update.sh` /
`update.bat` (which run the first). Each updates the whole folder, app and
server; restart whichever is running to use the new version. A
release with a newer protocol is a required update: everyone on a server
must run the same protocol version, and a mismatch is refused with a message
telling you to update. Updates are signed: Starsync installs only one
signed by its developer whose download matches its checksum, and says
in Settings → Updates when it refused one.

## Getting started

The app always runs its own server, quietly: your server. When it starts
you are on it, alone, and it is a plain player. Three ways in, at the top
of the Library the first time; none needs Jellyfin or an account.

- **Join a friend** (most people): your friend sends you an invite (a
  `starsync://` link) and, maybe, a password. Click the link, or just
  copy it: the app asks "Join <their server>?". See [Join](#join).
- **Invite friends**: you have the video and friends watch it with you.
  See [Your server and Invite](#your-server-and-invite).
- **Watch on your own**: just play something from the Library, with
  everything a server has (Jellyfin progress, next episode, skip buttons).
  Nobody else can reach your server until you invite them; inviting never
  interrupts what plays.

## The window

One window. Along the top, the strip: your avatar (click it for your
profile: name, picture with a crop editor, colour, and links to the
settings), the Library / Schedule / Settings tabs, and the party. Alone
on your server it has just Join a friend and Invite (and "Sharing" while
your server is open to friends); with others there it shows everyone's
picture, filling a rounded square (or a circle: Settings → Party → More →
Avatar shape), with a small badge for where they stand (a cup: BRB; "Zz":
AFK; an eye with a line: out, darkened) and a line running round the
edge while their video loads (white) or they reconnect (amber); a crown
on whoever hosts, a tower on whoever passes the video on. Click the
avatars for the member list (each member's app version, amber when it
differs from yours, and the server's at the top; Wait for / Don't wait
for, Nudge, Out; on your server where friends can reach it, Copy invite
link and Stop sharing, on a friend's "Copy invite link"). Beside them the
server and "3 watching · 1 BRB" (who reconnects does not count), the chat
button with unread
count, and Invite on your server or Leave on a friend's. Empty strip
space drags the window.

The player fills the window under the strip. Pick a tab and it shrinks to
a mini player in a corner: drag it anywhere and it snaps to the nearest
corner; double-click or ⤢ makes it big again, × closes it and sets you
out (below); the strip's screen button brings it back. F or
double-click on the picture goes fullscreen (the strip hides; the
party's avatars and the window buttons come up with the player's controls,
top right, and work as in the strip: names on hover, a click opens who is
in the server), Esc leaves it. The controls show the
show's cover, title and episode top left (a web video: its thumbnail and
name; guests get the art too; right-click to copy the title, or the link
when you have it, or open it in the browser or Jellyfin); before
a video first plays, its banner fills the picture until playback starts.
One pill bottom centre, just above the controls, says what playback waits for
("Waiting for Bob and Mika" with their pictures, "Paused · waiting for
Bob", "Paused by Bob") with the keys that act now (`[Space] BRB too
[Hold Space] continue without`), or what went wrong, with Retry or Cancel
when it helps; bottom subtitles move up out of its way. Chat and activity open in a panel on the right (chat button or
Tab), ready to type; it shows messages (select text to copy it, or
right-click for Copy message and, with a link in it, Copy link / Open in
browser), and its "Activity" toggle adds
joins, BRBs, seeks and the like between them. Joins, leaves, someone
losing connection and coming back, video changes, additions to Up next
(the title, its picture and who added it), chat and problems also pop up
bottom left with the person's avatar, above the player's controls (never
on them); BRBs, seeks and pauses stay in the activity. Click a message
to open the chat (Settings → Notifications & sounds → Chat pop-ups: All
by default, or Only when paused, or Off; messages always reach the chat,
with their sound). Watching alone, nothing pops up or sounds about the
party (there is nobody); the app's own notices still show.

**Quick chat.** Enter in the big player opens a small chat box at the
bottom centre without opening the chat panel, also while the video
plays: type (the player's keys wait meanwhile), Enter sends, Esc or an
empty Enter closes it, and it closes by itself after a few seconds
without typing. It is the same draft as the chat panel's field, so a
message started in one is there in the other. What you sent shows for a
moment where the box was (or flies as your own line with danmaku, below);
bottom subtitles move up out of its way and back, top signs stay. The
mouse pointer and the controls stay hidden: typing is not moving the
mouse.

**Danmaku.** Settings → Notifications & sounds → Over the video →
Notifications: Toasts (default) or Danmaku (also in the player panel).
With Danmaku, over the big player chat, joins, leaves, Up next and
"starting now" fly right to left across the top of the picture instead
of popping up (problems and errors still pop up, and everything does
while the player is small). The look is yours to tune under More there,
with a live preview (and in the player panel): crossing time, how many
at once, which lanes of the picture they use, opacity, size, boldness,
outline, avatars, and a frame round your own lines.

**While out or in the background.** Out or AFK, only chat,
nudges, "starting now" (the video starts for the others) and Up next
reach you; joins and leaves too if you turn on Settings → Notifications &
sounds → "Joins and leaves too". With the window in the background or
minimised, the same ones also come as desktop notifications (Linux's
notification center, Windows' toasts); clicking one brings the window
up, and a chat one opens the chat. Unread chat shows as a count on the chat
buttons and, in fullscreen with the controls hidden and the video paused,
as a small chip top right.

Your name and picture change for everyone in the server right away; the
colour is yours only.

**Play, pause and BRB.** Play and pause are everyone's: Space (or the
play button) plays or pauses for the whole group, and a new video waits
for one Play. Hold Space (about half a second; the pill fills and says
"Keep holding: BRB") to step away: everyone waits for you ("Waiting for
Bob"), and when you are back (Space again) it plays on if it was
playing. While someone is BRB, Space makes you BRB too or brings you
back, and holding it for 2 seconds goes on without them. Right-click
and hold on the video for the same and more, then let go on your pick:
↑ BRB / I'm back, → Skip OP, Skip 1:30 or Next episode (in the ending),
↓ Out / Join. A friend who ran off without pressing anything can be
waited for from their card ("Wait for Bob"), and anyone waited for can be
gone on without ("Don't wait for Bob").

**Out.** Step away without leaving: Out (your profile, your row in the
member list, the right-click menu, or × on the player) means nobody waits
for you any more; you stay in chat and your player stays where you were,
dimmed, with a small card saying where the others are and a Join button.
Anyone can set anyone out, the host too ("Alice set you out" tells you
who). Space or Join brings you in at the current moment, loading in the
background while the others play on. If your connection drops or the
app crashes, the others see "Bob is back (missed 1:42)" when you
return. No input for 10 minutes while nothing plays makes you AFK, which
is the same as out with its own badge; any key or the mouse brings you
back. The window minimised for 10 minutes while the video plays sets you
out. Nothing of this happens when you are alone.

**Reconnects.** A bad connection does not throw you out: the video keeps
playing, the pill says "Connection unstable…" and then "Reconnecting…",
and the app comes back on its own as the same member (BRB or out, your
Up next items and the video you pass on all kept) for up to 10
minutes; the others see you dimmed, "reconnecting…". Only a drop of a
few seconds or more makes the lost / back sounds. Leave and closing the
app tell the others at once; Update and restart keeps your place for the
restarted app. Opening Starsync a second time (another window with the
same profile) takes your place over, and the first one says so and stops.

**Nudge.** Nudge in the member list pokes someone, out or not:
only they hear it (a sound, a pop-up, and the taskbar entry asks for
attention when the window is in the background).

## Your server and Invite

Your server starts with the app and stops when it closes. Only this app
can reach it until you press **Invite** (in the strip, or in the member
list): that opens it on your network at the port from Settings → Party
(default 8080, with the password set there; blank = anyone can
join) and copies an invite link (`starsync://203.0.113.7:8080/?name=…`,
just the link) to send to friends. Nothing restarts: what plays and Up next carry on, and you are
the host (the crown).

The link carries your internet address when the app can find it (it asks
a "what is my IP" service such as ipify over HTTPS when you share), else
this computer's home-network address (not a proxy one, nor a Docker or VM
bridge). In the member list, **Copy invite link** copies it again;
**Other addresses** there lets you pick another: **Internet** for friends
elsewhere, **Home network** for friends on the same Wi-Fi or router,
**VPN** (Tailscale and the like). Behind a router, friends elsewhere get
in only when the TCP port is forwarded on your router to this computer
(the card says so); the app does not open ports itself. The link
includes the password when one is set, so friends just click it: share
it only with them. Friends open nothing. **Stop sharing** (in the member list)
closes it again:
everyone else leaves (their app goes back to their own server and says
why), you and Up next stay.

If you put up a local file, your server streams it to everyone from your
disk. Nothing is uploaded or stored anywhere.

Joining a friend leaves your server for theirs; it stays up meanwhile,
and leaving theirs brings you back to it as you left it.

## Library

What to watch, from three sources (the switch at the top). Drop a video,
a folder or a link anywhere on the window, or press Ctrl+V outside a
text field, and a small card asks how to open it: put it up (one click;
a link goes the way picked on the Link page), add it to Up next, add the
folder to Files, or open a link on the Link page first. While the others
are watching something, Add to queue comes first and putting up says
"Put it up now", since it replaces the video for everyone.

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
- **Files**: your own library from the video folders you add on this
  computer (the **Library** shows them all together, each folder on its
  own too), or any file through Browse. Files are sorted into shows and
  movies by their names and folders: one show split over several folders
  is one show, OP/ED and specials go under its **Extras**, a folder like
  "Show (Season 3 - Alicization)" gives the season and its name. Shows
  are looked up on AniList for their proper name, cover and banner. A
  show's page has its seasons and episodes and a button for the next one
  after what you last watched here; when episodes are missing on the way
  it says so ("66–107 aren't in your folders — skip to 108?"). An
  episode you put up continues with the next one at its end (see Up
  next). Matched
  the wrong show? **Wrong show?** searches AniList and pins the right one
  for the show everywhere or just one folder; **Episode numbers…** says
  which episode the first file is when the files count differently. Both
  stay through rescans. The others stream what you put up from you, and
  see its proper name too.

Put it up and the player opens. With nobody else in the server, the
buttons say Play and a link plays straight from the site.

### Up next (the queue)

Anything can wait its turn instead of going up
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

In the player, Up next sits in the top bar, right of the title: the
next item's picture and title (or what continues the episode). Rest the mouse on
it for a larger preview (who added it, its length, whether it is ready
to start); ⏭ plays it now, a click opens the queue: drag rows to reorder, hover a
row to play it now (▶) or remove it (×), right-click it for more (copy its
title or link, open it in the browser or in Jellyfin). To add, press
Ctrl+V with the queue open (a copied link or video file goes in at once,
its title and picture showing while it is checked), type one after
**+ Add link**, or drop a link or a video on it. When a video ends, a card shows
what is up next with a 10 s countdown everyone sees, and it plays;
Cancel stops it for everyone, and so does seeking back. `>` or Shift+N
plays it at once. Under the queue, **Continues with** shows what
continues the episode playing: its next episode (a Jellyfin episode's,
or a file's next one in your Files library, saying which numbers it
skips), added by whoever put the episode up, and greyed because it
plays only once Up next is empty; **Clear** drops it for everyone. The
further episodes of a Jellyfin series show under it; **+** adds one.

A link you pass on ("through me") or a file of yours can only be played
by your app: if you left when its turn comes, it is skipped ("Skipped …:
Foxyz left"). If you are only gone for a moment, the countdown waits for
you. A Jellyfin item needs someone with an account on that server. Up
next is kept by the server while it runs. If the server restarts, the
apps put back what was playing, where it was, and Up next with it (a
link the server fetched has to be added again).

## Schedule

The week's airing anime, one column per day (AniList), each episode
marked with what the Jellyfin server has of it when AnimeFlow is
connected (Settings → Library & accounts): **on Jellyfin** (Put it
up, right-click to queue), **downloading**, **waiting for release**
(aired in Japan, AnimeFlow downloads it by itself once a release
appears; with when AnimeFlow last searched, or **release rejected** when
it found releases it won't take, the reason on hover), **failed**, **not monitored** (Request asks AnimeFlow for it),
or the time left until it airs. A show AnimeFlow does not follow can be asked for with **Request
series**. Episodes you already watched on Jellyfin carry a check on the
cover; one you started shows how far you got.

## Dedicated server

For an always-on box (no display needed): the release tarball also contains
`starsync-server`, a small standalone server without the app. Run it,
then everyone (you included) uses Join.

```
./starsync-server --port 8080 --secret <password>
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
| `--log-dir` | `logs` next to `--config`, else next to the binary (systemd: the unit's `StateDirectory`) | folder for the log files (`server-YYYY-MM-DD.log` and the session log `session-YYYY-MM-DD.log`, kept 7 days; passwords, tokens and cookies left out) |
| `--config` | none | YAML or JSON file with the same settings (`port`, `secret`, `name`, `mediaPath`, `advertiseHost`, `ytDlp`, `ytDlpDir`, `ytDlpCookies`); replaces the flags |
| `--upgrade` | | update the install folder to the latest release ([Install and update](#install-and-update)), then exit |
| `--check-update` | | print whether a newer release exists, then exit |

It prints `READY port=... name=...` once listening and stops cleanly on
Ctrl+C or SIGTERM. A dedicated server has no host.
To run it as a service, unpack the tarball to `/opt/starsync` and use
[deploy/starsync.service](deploy/starsync.service) (copy it to
`/etc/systemd/system/`, edit the flags, `systemctl enable --now starsync`).
A service set up before the rename (`/opt/watch-together`) must run
`starsync-server` in its `ExecStart`: updates remove the old name
`watch-together-server`.

Something not playing? Settings → Help & about → **Copy diagnostics** puts the
app's recent log (passwords, tokens and cookies left out) on the
clipboard: paste it to whoever helps you, from both sides if you can.

While you are in a server, the app also sends its log to that server, which
merges everyone's lines and its own into one session log
(`session-YYYY-MM-DD.log` next to the server's logs; your own server
keeps it in the app's logs folder), so a problem can be read afterwards from every
side. Chat is never logged anywhere, nor passwords, tokens and cookies.
When something goes wrong, press **Mark a problem** (Ctrl+Shift+B, also in
the player's ⋯ and Settings → Help & about) and add a few words if you like: a
marker with your name goes in the session log at that moment. In a server,
Copy diagnostics can add the session log of the last 6 hours (any member
may read it). Don't want to share? Settings → Help & about → **Share diagnostics
with the server** off: your log stays on your machine (the server only
notes that you don't share; a problem you mark still goes in).

## Join

Join a friend in the strip. Servers you got into are listed first (up
to 6), with live status (online and how many are watching, or offline,
plus "needs update" when its version and yours do not match): click one
to rejoin, x to forget it. Or paste the invite (or the address and port)
and the password if there is one, then Enter or Join.

Faster: click a friend's `starsync://` link, or copy their invite and
switch to Starsync. The app asks "Join Bob's server (203.0.113.7:8080)?"
with the server's version and who is watching; Join joins (and adds it
to your recent servers), Not now leaves it (a copied invite is then not
offered again). The clipboard is only looked at for an invite when the
window comes to the front, and never saved or logged. The app runs once:
a link clicked while it runs goes to the open window. Before connecting
the app checks the server's version: when they do not match it says who
has to update ("Bob's server runs Starsync 1.2.1 — they need to
update"), and offers the update when it is you. Your name and picture
come from your profile (your avatar at the top left); with no name yet,
the first join asks "Wait, what do we call you?" (your computer's user
name to start with, plus picture and colour), and OK goes on with that
join. Leave goes back to your own server.

## Settings

The Settings tab (Ctrl+, opens the page you last had, Player at first)
has six pages, each setting with a line of help, the common ones first
and the rest folded under More:

- **Player**: Sound (the video's volume), Subtitles (size, above the
  controls), Picture (upscaling shader; under More your own shader
  files, sharp video, hardware decoding), Controls (player design,
  controls size, progress line; under More which buttons sit in the
  bar) and Playback (play the next episode automatically).
- **Party**: you (picture, name and colour, edited right there; under
  More the avatar shape: rounded square or circle), Your server (port and
  password for Invite) and Recent servers (forget the ones you no longer
  use).
- **Notifications & sounds**: Over the video (toasts or danmaku, chat
  pop-ups, joins and leaves while out or in the background;
  under More the danmaku look and what pops up when) and Sounds (App
  sounds, the sound set; each sound with a preview, its own set and a
  switch folded below).
- **Library & accounts**: linked Jellyfin servers (below), the AnimeFlow
  connection ("connected as <name>" with what you may do, or why not)
  and Web links (yt-dlp and its cookies, below).
- **Updates**: where updates stand and Check now; the update channel
  and a config address (a mirror of where updates are found; leave it
  empty) under More.
- **Help & about**: Something wrong? (copy diagnostics, mark a problem,
  the logs folder, sharing diagnostics with the server), every keyboard
  shortcut, and About (the version, also at the bottom of every
  Settings page and in the Settings tab's tooltip; the credits, e.g.
  that the Minimal player design is inspired by uosc; and Open-source
  licenses, everything Starsync is built on with its license).

Player settings live in the player too: ⚙ in the player's bar opens a
narrow panel at the right edge of the player that stays open while you
watch (the controls hide and show as usual) until its × or Esc. Its
sections fold: Sound first (the video's Volume, and App sounds: how loud
the app's own cues are), Subtitles & audio (the tracks, subtitle size,
subtitles above the controls), Picture (upscaling shader with HQ or
Fast; under Troubleshooting sharp video and hardware decoding with its
custom value), Over the video (toasts or danmaku, chat pop-ups, the
danmaku look) and Controls (player design, controls size, progress
line). They are Settings' own rows with the same names, only smaller.
Its All settings button opens the Settings page of the section you last
used there (the player goes to the mini). Player design: Standard or
Minimal (below); controls size (normal or large); progress line when
hidden (on by default: a thin line at the bottom of the video while the
controls are hidden); upscaling shader (see below); hardware decoding
(auto, off or custom; auto is mpv's `auto-copy` on Windows, `auto`
elsewhere; the env var `SYNC_RELAY_HWDEC` overrides it); subtitle size;
subtitles above the controls (off by default: bottom lines move up while
the control bar shows; the quick chat box always moves them); the
optional bar buttons (chapter buttons, subtitles, audio, chat; hidden
ones are in ⋯). The controls hide 3 s after the mouse last moved, and a
click on the time switches between elapsed and remaining. Every change
applies right away.

Anywhere in a server (unless you are typing): Space = play / pause for
everyone, hold Space = BRB (while someone is BRB: Space = BRB too or I'm
back, hold 2 s = continue without them), Tab = chat & activity (Tab never
moves between buttons). On the video: right button = the menu (BRB,
skip ahead, Out). Anywhere:
Ctrl+Shift+B = mark a problem in the session log. Keys while the
player fills the window: Left/Right = seek 10 s, Up/Down = volume, M = mute, Shift+Right = skip 1:30,
PgDn/PgUp = previous / next chapter (as in mpv), F = fullscreen, Enter =
quick chat, Esc = close the player panel, then
the chat, then fullscreen, then shrink the player to mini; from the
mini it asks to leave, Ctrl+R = reload video,
`<` / `>` or Shift+P / Shift+N = previous / next Jellyfin episode,
Ctrl+1..6 = Anime4K mode A, B, C, A+A, B+B, C+A, Ctrl+0 = shaders off.
Every seek, skip and chapter jump moves everyone.

Controls: both designs have the same buttons in the same places, only
the look differs. Bottom left: play / pause first (everyone's, like
Space), previous / next
episode (when there is one; next plays Up next first), previous / next
chapter (when the video has chapters), volume and the time (click it to
switch between elapsed / total and the time left). Bottom right:
Subtitles and Audio (with the track count; tracks listed as "Japanese ·
E-AC3 2.0 · title", subtitles with Off), ⚙ (player settings: opens and
closes the panel), chat and fullscreen last. The top bar has the title,
Up next, ⋯ (video and session) and back to the library (in fullscreen:
exit fullscreen and the window buttons). ⋯ holds change video, copy
link, reload video, Skip 1:30, chapters (current one checked; click to
jump), mark a problem and leave server, plus any
bar button you hid. Volume: its slider sits next to
the speaker (in a narrow window it slides out while you hover the
speaker); a click on the speaker or M mutes, scrolling anywhere on the
video or Up/Down steps it. It goes to 150 % like mpv: past the tick at
100 % the bar turns amber and mpv amplifies; a scroll or key shows the
volume for a moment. The next start begins at the volume you left it
at. Lists and menus under the mouse scroll as usual.

Standard (the default): a seek bar that marks chapter starts with a
diamond (hovering it shows the time and the chapter title) over a row
of round buttons. Minimal (⚙ → Player design, switches
right away): a translucent timeline across the bottom tints what has
played, stripes the parts not downloaded, marks chapter starts with
dots (click one to jump), shows the elapsed time left and the total or
the time left right (click it to switch) and, while less than a minute
is buffered, the buffered seconds next to the position; hovering it shows
the time there and the chapter title. With the controls hidden it stays
as a thin line (unless "Progress line when hidden" is off). Its buttons
sit in two glass capsules above it. Minimal's timeline and controls are
inspired by [uosc](https://github.com/tomasklaen/uosc) by tomasklaen
(LGPL-2.1).

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

Only the one who invites needs the port reachable; until Invite your
server listens on 127.0.0.1 and a free port only.

## Jellyfin

Settings → Library & accounts → Add server: type the address, then sign in with
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
  change, and when it stops). Watched means you were there while most
  of it played (or while half of it played and it reached the ending),
  not where it stopped: time you were out does not count, skipping around
  does not count, opening a watched episode to check a moment keeps it
  watched, and a quick peek leaves no resume point. Files and links you
  watch are remembered the same way on your computer (a show's next
  episode in Files follows them).
- Friends without an account watch through the server: whoever put the
  item up passes it on automatically, with their own sign-in, which never
  leaves their computer (only the current item, only to people in the
  session). They show "via server" in the member list (click the avatars). On your
  own server (with your sign-in on that item's Jellyfin, whichever of
  your linked servers it is), or a dedicated server with its own login (`--jellyfin <file>`, see
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), Jellyfin relay), the server
  fetches it itself instead.
- If nobody can pass it on (the person who put it up left), the app says
  "No Jellyfin account here for ..." with a button to link one; it plays as
  soon as you are signed in.

Episodes: the ⏮ / ⏭ buttons next to play (or `<` / `>`,
Shift+P / Shift+N) put up the previous or next episode for everyone. From
the ending (when it is known, see Skipping above; else in the last two
minutes) a "Next episode" button floats in the corner while the controls
are up. With "Play the next episode automatically" (Settings → Player, on by
default), the episode you put up continues with the next one: when it
ends, everyone sees a 10 s countdown, and anyone can cancel it (see Up
next). Anyone with an account can put the next one up; friends watching
via the host cannot.

Audio and subtitles: the Audio and Subtitles buttons in the controls pick tracks.
Your choice is remembered per series (and as a default) and the closest
match (language, then title, then codec and channels) is selected on the
next episode. This is per person; nobody else is affected.

⋯ → Change video in the player opens the Library tab (the player
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
against the release's checksums, updated once a day; Settings → Library
& accounts → Web links shows its version and has "Update now"), so there
is nothing to install.
Sites that refuse guests (Bilibili answers "HTTP Error 412", YouTube may
ask to sign in) need cookies: Settings → Library & accounts → Web links → Cookies reads
them from a browser, or from a cookies.txt or a cookie extension's JSON
export (picked or dropped; every site in it is kept). They stay on this
computer and are used by its yt-dlp only (your own playback, "through
me", and a server you host). Cookies log yt-dlp in as you on those
sites: keep the file private, and for YouTube consider a throwaway
account (Google may flag accounts used with yt-dlp). When a page shows
no video, the message says which cookies were used: none, your file
(and whether it has any for that site), or your browser's (and how many
it has for that site), so you know whether to sign in there or add
cookies.
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
source is too slow or its connection dropped ("Bob's connection dropped —
playing what the server has (2 min)"), red when it left (the others play
out what the server already has; the player's pill says the same and a
pop-up tells you once), and whoever passes it on is told once when their
upload is too slow. Each member's line says how they get it
("via server" with their speed, or "direct") after a dot for their
buffer: green enough to play on, amber low, red empty. A red dot on one
member while the source keeps up is their own connection.

## Video quality and shaders

Each viewer can run mpv GLSL shaders on their own picture; nobody else is
affected. The app ships [Anime4K](https://github.com/bloc97/Anime4K) v4.0.1
(MIT) with the presets of its mpv guide: Mode A (1080p sources), B (720p),
C (480p), A+A, B+B, C+A, each as HQ (strong GPUs, GTX 1080 and up) or Fast
(the guide's low-end set). "Custom shaders" runs your own `.glsl` files.

Pick one in the player with ⚙ → Upscaling shader (also in fullscreen) or
Ctrl+0..6; the change applies live and is saved, so the next session
starts with it. Settings → Player sets it too, with HQ or Fast (used by
Ctrl+1..6), and holds the custom files. Shaders cost GPU time
every frame and need hardware video rendering: on media_kit's software
fallback they do nothing, and the app says so. A shader that is missing or
fails to load shows a toast and switches shaders off.

## Troubleshooting

- "host offline - check address and port": wrong address, or the port is not open.
- "wrong server password": password mismatch.
- "host runs a different version": update the app on both sides.
- Picture frozen but sound fine: Ctrl+R reloads the video.
- Everyone waits at "Waiting for X": X is BRB, or X has not buffered 4 seconds yet (their card has "Don't wait for X").
- Windows: the build is new; if something is off there, say so.

For contributors: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md),
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/PROTOCOL.md](docs/PROTOCOL.md).
