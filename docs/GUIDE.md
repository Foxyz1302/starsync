# Starsync guide

Everything Starsync does, for people who use it and people who run a
server. The short version is the [README](../README.md); how it works
inside: [HOW-IT-WORKS.md](HOW-IT-WORKS.md) and
[ARCHITECTURE.md](ARCHITECTURE.md).

- [Install and update](#install-and-update)
- [Your server, Invite and Join](#your-server-invite-and-join)
- [The window](#the-window)
- [Watching together](#watching-together)
- [What to watch](#what-to-watch): [Jellyfin](#jellyfin), [Links and yt-dlp](#links-and-yt-dlp), [Live streams](#live-streams), [Files](#files), [Up next](#up-next), [Schedule](#schedule)
- [The player](#the-player)
- [Screenshots](#screenshots)
- [Picture quality and shaders](#picture-quality-and-shaders)
- [Settings](#settings)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Dedicated server](#dedicated-server)
- [Diagnostics and troubleshooting](#diagnostics-and-troubleshooting)

## Install and update

Downloads are on the [releases page](https://github.com/Foxyz1302/starsync/releases/latest)
and [foxyz.ru](https://foxyz.ru). Each archive has one folder,
`starsync-<version>/`, with the app, the [dedicated server](#dedicated-server),
an update script, `LICENSE` and `THIRD_PARTY_LICENSES.txt`.

- **Linux**: `starsync-<version>-linux-x64.tar.gz`. Extract it and run
  `starsync`. It needs mpv's library from your distribution (the `mpv` or
  `libmpv2` package). On start it adds itself and its icon to your app
  launcher, so the window shows its own icon on Wayland.
- **Windows**: `starsync-<version>-windows-x64.zip`. Extract it and run
  `starsync.exe`. mpv is included.

Keep the folder somewhere you can write to: updates replace the files in
place.

### Updates

The app looks for a new version when it opens and every few hours. When
there is one, a band across the top of the window says so (never over a
playing video), with its highlights:

- **What's new** shows them, with every change behind **All changes**
  (the [changelog](../CHANGELOG.md)). The first start after an update
  shows it once; Settings → Help & about has it again.
- **Update and restart** downloads, verifies, replaces the folder's files
  and restarts. **Later** hides the band until the next check.
- Settings → Updates shows where updates stand and has **Check now**.

Updates are signed: Starsync installs only an update signed by its
developer whose download matches its checksum, and Settings → Updates
says when it refused one.

From a terminal, each of these updates the whole folder (app and server),
also on a machine without a display:

```sh
./starsync-server --upgrade        # or: ./starsync --upgrade
./starsync-server --check-update   # only say whether a newer release exists
```

The shipped `update.sh` (Linux) and `update.bat` (Windows) run the first.
Restart whatever was running to use the new version.

**Required updates.** Everyone on a server must run the same protocol
version. A release with a newer protocol is refused by older servers and
apps, with a message that says who has to update; when it is you, the app
offers the update.

**Update channel.** Settings → Updates → More: **Stable** (releases) or
**Dev** (test builds). Leave **Config address** empty: it is only a mirror
of where updates are found.

### Your data folder

Settings, Jellyfin sign-ins, your library folders, logs, and yt-dlp with
its cookies live in:

- Linux: `~/.local/share/dev.foxyz.starsync`
- Windows: `%APPDATA%\foxyz\Starsync`

Settings → Help & about → **Open logs folder** opens the logs. Screenshots
go to your Pictures folder, under `Starsync`.

Up to 1.2.x the app was called `watch_together`. Its first start after
that copies your data from the old places
(`~/.local/share/moe.senkochan.watch_together`, or
`%APPDATA%\com.example\watch_together` and the app's files in Documents)
and leaves the originals where they were.

## Your server, Invite and Join

The app always runs its own server, quietly, from start to close. When
it starts you are on it, alone, and it is a plain player with everything
a server has (Jellyfin progress, next episode, skip buttons). Nobody else
can reach it until you invite them.

### Invite

**Invite** (in the strip, or in the member list) opens your server on
your network at the port from Settings → Party → Your server (default
8080, with the password set there; blank means anyone with the link can
join) and copies an invite link:

```
starsync://203.0.113.7:8080/?name=Alice
```

Nothing restarts: what plays and Up next carry on, and you are the host
(the crown). The link includes the password when one is set, so friends
only click it: share it only with them.

The link carries your internet address when the app can find it (it
asks a "what is my IP" service such as ipify over HTTPS), else this
computer's home-network address. In the member list, **Copy invite link**
copies it again, and **Other addresses** lets you pick another:

- **Internet**: friends elsewhere. Behind a router they get in only when
  the TCP port is forwarded on the router to this computer; Starsync does
  not open ports itself.
- **Home network**: friends on the same Wi-Fi or router.
- **VPN**: Tailscale and the like.

**Stop sharing** (in the member list) closes your server to friends
again: everyone else goes back to their own server, with a note saying
why; you and Up next stay.

Your server listens only on 127.0.0.1, on a free port, until you invite.
Sync, file streaming and the rest share the one TCP port; the connection
is plain `ws://`, without TLS.

### Join

Click a friend's `starsync://` link, or copy it and switch to Starsync.
The app asks "Join Bob's server (203.0.113.7:8080)?" with the server's
version and who is watching. **Join** joins and adds it to your recent
servers; **Not now** leaves it (a copied invite is then not offered
again). The clipboard is looked at only when the window comes to the
front, and is never saved or logged. A link clicked while Starsync runs
goes to the open window.

Or press **Join a friend** in the strip: servers you got into are listed
first (up to 6), each online with how many are watching, or offline, or
"needs update". Click one to rejoin, × to forget it. Or paste an invite
(or an address and port) and the password, then Join.

Before connecting the app checks the server's version. When they do not
match it says who has to update ("Bob's server runs Starsync 1.2.1 — they
need to update") and offers the update when it is you. The first time,
with no name yet, it asks "Wait, what do we call you?" (your computer's
user name to start with, plus a picture and a colour).

Joining a friend leaves your server for theirs. Yours stays up meanwhile,
and **Leave** brings you back to it as you left it. A copied invite link
from a friend's server carries the password you joined with.

If you put up a file from your disk, your server streams it to everyone
from there. Nothing is uploaded or stored anywhere else.

## The window

One window. Along the top, the strip:

- **Your avatar**: your own card, the same card others see, with
  everything yours to change right on it: click the picture (a crop
  editor), click the name to rename, pick a colour or make any colour
  with **Custom…** (drag over the colours, or type a code like
  `#9b4dca`). Links to the settings follow. Your name, picture and colour
  change for everyone right away. A very dark or very light colour stays
  readable: names in chat and danmaku are lightened where they need it,
  and the letter on your avatar turns dark on a light colour.
- **The tabs**: Library, Schedule, Settings.
- **The party**: alone on your server, Join a friend and Invite (and
  "Sharing" while friends can reach it). With others there, everyone's
  picture, with a small badge for where they stand (a cup: BRB; "Zz":
  AFK; an eye with a line: out, darkened) and a line running round the
  edge while their video loads (white) or they reconnect (amber). A crown
  marks whoever hosts, a tower whoever passes the video on.
- **The server's name** and "3 watching · 1 BRB": click it (or the
  avatars) for the member list. Then the chat button with its unread
  count, and Invite on your server or Leave on a friend's.

Empty strip space drags the window.

**People cards.** Rest the mouse on someone (their avatar, a member's
row, a chat line, a pop-up, or click a danmaku line's name) for a card:
a bigger picture, whether they are watching, BRB, AFK, out or
reconnecting, their Starsync version, what they pass on, and Wait for /
Don't wait for, Nudge and Out. A click keeps it open. Each card is
tinted with that person's colour.

**The member list** shows the server and its version at the top, where
the video comes from (see [Where the video comes from](#where-the-video-comes-from)),
then one row per person: picture, standing, how the video reaches them
and a ⋮ menu. A version in amber differs from yours.

**The player** fills the window under the strip. Pick a tab and it
shrinks to a mini player in a corner: drag it anywhere and it snaps to
the nearest corner; double-click or ⤢ makes it big again; × closes it
and sets you out. F or a double-click on the picture goes fullscreen
(the party's avatars and the window buttons come up with the player's
controls, top right); Esc leaves it.

**The pill** at the bottom centre, just above the controls, says what
playback waits for ("Waiting for Bob and Mika" with their pictures,
"Paused · waiting for Bob", "Paused by Bob") with the keys that act now,
or what went wrong, with Retry or Cancel when it helps. While the video
is paused it shows everyone who is in. Bottom subtitles move up out of
its way. Waiting for someone can show as this pill, as a card in the
middle of the picture, or as a card that fades with the controls
(Settings → Player → Waiting display).

**Chat and activity** open in a panel on the right (the chat button or
Tab), ready to type. Select text to copy it, or right-click a message for
Copy message and, with a link in it, Copy link / Open in browser. Its
**Activity** toggle adds joins, BRBs, seeks and the like between the
messages.

**Quick chat.** Enter in the big player opens a small chat box at the
bottom centre, also while the video plays. Enter sends, Esc or an empty
Enter closes it, and it closes by itself after a few seconds without
typing. It shares its draft with the chat panel.

**Pop-ups.** Joins, leaves, lost connections, video changes, additions to
Up next, chat and problems pop up bottom left with the person's picture,
above the player's controls; BRBs, seeks and pauses stay in the activity.
Click a chat pop-up to open the chat. Watching alone, nothing pops up or
sounds about the party.

**Danmaku.** Settings → Notifications & sounds → Notifications: Toasts
(the default) or Danmaku. With Danmaku, chat, joins, leaves, Up next and
"starting now" fly right to left across the top of the big player
instead (problems still pop up). Its look (speed, how many at once,
lanes, opacity, size, outline, avatars) is under More there, with a live
preview, and in the player panel.

**Out or in the background.** While you are out or AFK, only chat,
nudges, "starting now" and Up next reach you (joins and leaves too with
"Joins and leaves too" on). With the window in the background or
minimised, the same ones also come as desktop notifications; clicking one
brings the window up, and a chat one opens the chat.

## Watching together

There are no roles: anyone can play, pause, seek, change the video, wait
for someone or go on without them, nudge anyone and set anyone out (the
host too).

### Play, pause and BRB

- **Space** (or the play button) plays or pauses for everyone. A new
  video waits for one Play. Nothing starts by itself: the group waits for
  a video that is still loading until it is there or someone goes on
  without it.
- **Hold Space** (about half a second; the pill fills and says "Keep
  holding: BRB") to step away: everyone waits for you ("Waiting for Bob").
  Space again brings you back, and it plays on if it was playing.
- **While someone is BRB**, Space makes you BRB too or brings you back,
  and holding it for 2 seconds goes on without them. Both hold times can
  be changed in Settings → Player → More (BRB hold 0.4–0.8 s,
  Continue-without hold 1.5–3 s).
- **Right-click and hold** on the video for a round menu, then let go on
  your pick: ↑ BRB / I'm back, → Skip OP, Skip 1:30 or Next episode, ↓
  Out / Join. Letting go anywhere else closes it.
- **Wait for / Don't wait for**: a friend who ran off without pressing
  anything can be waited for from their card ("Wait for Bob"), and anyone
  waited for can be gone on without ("Don't wait for Bob").
- **Seeks, skips and chapter jumps** move everyone.

### Out and AFK

**Out** means nobody waits for you, without leaving: your profile, your
row in the member list, the round menu or × on the mini player. You stay
in the chat, and your player stays where you were, dimmed, with a card
saying what the others watch and where they are, and a **Join** button.
Anyone can set anyone out ("Alice set you out" says who). Space or Join
brings you in at the current moment, loading in the background while the
others play on.

**AFK** is the same with its own badge: 10 minutes without input while
nothing plays. Any key or the mouse brings you back. The window minimised
for 10 minutes while the video plays sets you out. None of this happens
when you are alone.

### Reconnects

A bad connection does not throw you out. The video keeps playing, the
pill says "Connection unstable…" and then "Reconnecting…", and the app
comes back on its own as the same member (BRB or out, your Up next items
and the video you pass on all kept) for up to 10 minutes; the others see
you dimmed, "reconnecting…". Back from a drop or a crash, the others see
"Bob is back (missed 1:42)". Leave and closing the app tell the others at
once; Update and restart keeps your place.

**Nudge** (on someone's card or row) pokes them, out or not: only they
hear it, with a pop-up, and the taskbar entry asks for attention when the
window is in the background.

## What to watch

The Library tab has three sources, switched at the top: **Jellyfin**,
**Link** and **Files**. Drop a video, a folder or a link anywhere on the
window, or press Ctrl+V outside a text field, and a small card asks what
to do with it: put it up, add it to Up next, add the folder to Files, or
open a link on the Link page first. While the others watch something,
Add to queue comes first and putting it up says "Put it up now", since it
replaces the video for everyone.

Put something up and the player opens. With nobody else in the server
the buttons say Play, and a link plays straight from the site.

### Jellyfin

Settings → Library & accounts → Add server: type the address, then sign
in with Quick Connect (the app shows a code; approve it in Jellyfin under
Profile → Quick Connect) or your user name and password. Several servers
can be linked; each shows its status, and a star picks the default. Sign
out revokes the app's sign-in on the server; an expired sign-in shows
"Reconnect".

**Browsing.** Library chips beside the source switch, then one
**Continue** row (what you were watching and what comes next, one card per
series, the most recent first; series untouched for two months drop out)
and **Latest in** each library (one card per series: "S1E1" or "3 new";
Show all opens the library newest first). Re-uploads, added long after
they aired, are hidden from Latest; the row's ⋮ turns that off. Behind
them: search, library grids (sort by name, date added, release date,
rating or random; Unwatched and Favorites filters) and series pages with
seasons and episode progress.

Click a card to select it: its details open on the right with "Put it
up · S1E3", mark watched / unwatched, remove from Continue, and the
episode list. Double-click a card or an episode to put it up at once.
Right-click for everything else: copy the title, open it in Jellyfin's
web page, Add to queue / Play next, and mark a whole show or season
watched or unwatched (a whole show asks first).

**What is shared.** Putting up an item sends only which Jellyfin server
and which item, never a link or your sign-in. Pasting a Jellyfin link
(web page or stream link) does the same when the app can reach that
Jellyfin; otherwise it goes up as a plain link.

**Watching.**

- Everyone with their own account on that Jellyfin plays the file with
  their own sign-in, and Jellyfin keeps their progress. Watched means you
  were there while most of it played (or half of it and it reached the
  ending): time you were out, skipping around and a quick peek do not
  count, and opening a watched episode to check a moment keeps it
  watched.
- Friends without an account watch through the server: whoever put the
  item up passes it on with their own sign-in, which never leaves their
  computer. They show "via server" in the member list. On your own
  server with your sign-in on that Jellyfin, or a dedicated server with
  its own login (`--jellyfin`, see [Dedicated server](#dedicated-server)),
  the server fetches it itself.
- If nobody can pass it on, the app says "No Jellyfin account here
  for …" with a button to link one; it plays as soon as you are signed
  in.

**Episodes.** ⏮ / ⏭ next to play (or `<` / `>`, Shift+P / Shift+N) put up
the previous or next episode for everyone. From the ending (or the last
90 seconds when the ending is not known) a **Next episode** button
floats in the corner while the controls are up. With "Play the next
episode automatically" (Settings → Player, on by default), an episode you
put up continues with the next one after a 10-second countdown anyone can
cancel. Anyone with an account can put the next one up; friends watching
through the server cannot.

**Audio and subtitles.** Your track choice is remembered per series (and
as a default), and the closest match (language, then title, then codec
and channels) is picked on the next episode. It is yours only.

### Links and yt-dlp

On the Link page, paste an http(s) link: a video file, or a web page with
a video (YouTube, X, and whatever else yt-dlp knows). The preview shows
what it is (the page's title, uploader, length and thumbnail, else the
file name). Your last 12 links are listed under it.

A link that does not open here (needs cookies, 403, 404, not a video)
says why and goes up only with **Put it up anyway**. In the player,
whoever cannot play it is named ("Bob can't play this: Not allowed
(403)") and nobody waits for them.

**How the others get it**, picked on the Link page:

- **Through me** (the default): your computer opens it and passes it on
  through the server, so it plays for everyone whenever it plays for you.
- Under **Other ways**:
  - **Everyone fetches it**: each app plays the link itself.
  - **Server fetches it**: the server downloads it once for everyone,
    for links that are slow or blocked for some. The server must reach
    it and must have a password (an open server refuses).

Through me and Server fetches it never show the link to anyone. YouTube
and pages that only offer streaming playlists (HLS `.m3u8`, DASH `.mpd`)
work in all three. Passing a video on needs an upload faster than its
bitrate: a 25-minute 2 GB episode is about 11 Mbit/s.

**yt-dlp.** The app and the dedicated server each download
[yt-dlp](https://github.com/yt-dlp/yt-dlp) by themselves (checked against
the release's checksums, updated once a day); there is nothing to
install. Settings → Library & accounts → Web links shows its version and
has **Update now**.

**Cookies.** Sites that refuse guests (Bilibili answers "HTTP Error 412",
YouTube may ask to sign in) need cookies: Web links → Cookies reads them
**From a browser…** or **From a file…** (a cookies.txt or a cookie
extension's JSON export; every site in it is kept). They stay on this
computer and are used by its yt-dlp only (your own playback, Through me,
and a server you host). Cookies log yt-dlp in as you on those sites:
keep the file private, and for YouTube consider a throwaway account
(Google may flag accounts used with yt-dlp). When a page shows no video,
the message says which cookies were used, so you know whether to sign in
or add some.

### Live streams

A live stream (Twitch, YouTube Live, Kick, any HLS playlist without an
end) plays for everyone at the same moment of the stream, wherever and
whenever each person joined.

- It always goes up as a link everyone opens themselves, whichever way
  you picked; each app needs to be able to open it (cookies and so on).
- The player shows **LIVE** where the time would be, and no chapters or
  skips. When the stream lets everyone go back (YouTube Live keeps 15
  minutes, Twitch nothing), the usual timeline covers what can be
  rewound, live at its right end: click or drag it, or use the arrow
  keys, and everyone goes there. The time then says how far behind live
  everyone is ("−2:30"), and **Go live** brings everyone back.
- Pause is everyone's, as for any video: the stream goes on meanwhile,
  so play goes on from the paused moment, behind live. Paused for longer
  than the stream keeps, it goes on from the oldest moment everyone
  still has. A stream that can't be rewound (Twitch) goes back to live
  when you play again ("This stream can't rewind: back at live").
- BRB, waiting for someone's video and going on without them work as
  for any video on a stream that can be rewound; on one that can't,
  nobody waits for anyone and Space just pauses and plays.
- When the stream ends, Up next's first item goes up at once.
- Live streams are not tracked as watched.

### Files

Your own library from the video folders you add on this computer (the
**Library** view shows them all together, each folder on its own too),
or any file through Browse.

Files are sorted into shows and movies by their names and folders: one
show split over several folders is one show, OP/ED and specials go under
its **Extras**, and a folder like "Show (Season 3 - Alicization)" gives
the season and its name. Shows are looked up on AniList for their proper
name, cover and banner. A show's page has its seasons and episodes and a
button for the next one after what you last watched here; when episodes
are missing on the way it says so ("66–107 aren't in your folders — skip
to 108?"). An episode you put up continues with the next one at its end.

Matched the wrong show? **Wrong show?** searches AniList and pins the
right one, for the show everywhere or one folder only. **Episode
numbers…** says which episode the first file is when the files count
differently. Both survive rescans.

The others stream what you put up from your computer, through the server
(which keeps a few minutes in memory, so seeks are quick). Keep the app
open while it plays. What you watch is remembered on your computer the
same way Jellyfin remembers it.

### Up next

Anything can wait its turn instead of going up now: **Add to queue** on
the Link page, or right-click a Jellyfin card or episode, a video in
Files, a recent link or an episode on the Schedule for **Add to queue** /
**Play next**. Everyone shares one Up next and anyone can change it; what
you added stays when you leave.

In the player, Up next sits in the top bar, right of the title. Rest the
mouse on it for a preview (who added it, its length, whether it is ready
to start); ⏭ plays it now; a click opens the queue:

- drag rows to reorder; hover a row to play it now (▶) or remove it (×);
  right-click it for more;
- add with Ctrl+V while it is open, **+ Add link**, or by dropping a link
  or a video on it.

Over the last 10 seconds of a video a countdown shows on every screen,
and the next item starts the moment the video ends. Cancel, a pause or a
seek back stops it for everyone. `>` or Shift+N plays it at once. Under
the queue, **Continues with** shows the next episode of what plays,
greyed because it plays only once Up next is empty; **Clear** drops it.

Every app keeps the next item ready, its first seconds loaded, so it
starts at once. A link passed on or a file of yours can only be played by
your app: if you left when its turn comes, it is skipped ("Skipped …:
Bob left"); if you are only gone for a moment, it waits for you. A
Jellyfin item needs someone with an account on that server. If the
server restarts, the apps put back what was playing, where it was, and
Up next with it (a link the server fetched has to be added again).

### Where the video comes from

The top of the member list says where the video comes from: who passes it
on, the server fetching it, everyone playing the link, or everyone
streaming from Jellyfin. For a video passed on it shows how fast it
arrives against what the video needs. It turns amber when the source is
too slow or dropped ("Bob's connection dropped — playing what the server
has (2 min)") and red when it left; whoever passes it on is told once
when their upload is too slow. Each member's row has a dot for their
buffer (green enough to play on, amber low, red empty): a red dot on one
member while the source keeps up is their own connection.

### Schedule

The week's airing anime from AniList, one column per day. With a
Jellyfin linked (Settings → Library & accounts), Starsync finds the shows
that are on it by itself and marks their episodes: **on Jellyfin** (Put
it up, right-click to queue) or **aired · not on Jellyfin yet**. Episodes
you watched on Jellyfin carry a check; one you started shows how far you
got. **On Jellyfin** lists just those shows (and the ones AnimeFlow
follows, below; the tab starts there when there are any), **All airing**
everything popular, and **Niche too** the rest.

When the server you joined offers AnimeFlow (a companion service that
downloads new episodes into Jellyfin), Starsync keeps it from then on
(Settings → Library & accounts shows it) and adds what AnimeFlow knows:
**downloading**, **waiting for release** (with when AnimeFlow last
searched), **release rejected** (the reason on hover), **failed**, **not
monitored** (**Request** asks for it), or the time left until it airs.
**Request series** asks for a show AnimeFlow does not follow, and
**Requests** lists yours.

## The player

Both player designs have the same buttons in the same places; only the
look differs.

- **Bottom left**: play / pause (everyone's), previous / next episode
  (when there is one; next plays Up next first), previous / next chapter
  (when the video has chapters), volume, and the time (click it to switch
  between elapsed / total and the time left).
- **Bottom right**: Subtitles and Audio (tracks listed as "Japanese ·
  E-AC3 2.0 · title"), ⚙ (the player panel), chat, fullscreen.
- **Top bar**: the show's cover, title and episode (right-click to copy
  the title or link, or open it in the browser or Jellyfin), Up next, ⋯
  and back to the library. ⋯ holds Change video, copy link, screenshot,
  Reload video, Skip 1:30, chapters, Mark a problem and leave server, plus
  any bar button you hid.

**Volume** goes to 150 % like mpv: past the tick at 100 % the bar turns
amber and mpv amplifies. Scroll anywhere on the video or press Up/Down to
step it; M or a click on the speaker mutes. The next start begins at the
volume you left.

**Standard** (the default) has a seek bar with a diamond at each chapter
start over a row of round buttons. **Minimal** has a translucent
timeline across the bottom that tints what has played, stripes what is
not downloaded yet and marks chapters with dots (click one to jump), with
its buttons in two glass capsules above; with the controls hidden it
stays as a thin line. Minimal is inspired by
[uosc](https://github.com/tomasklaen/uosc).

The controls hide 3 seconds after the mouse last moved.

**Skipping.** During the opening a **Skip OP** button shows bottom right
(to the end of the opening); during the ending **Skip ED** (to the end of
the ending only). The opening and ending come from Jellyfin's intro /
outro segments when your Jellyfin has them (it needs a segment plugin
such as Intro Skipper), else from chapter names (OP, Opening, Intro / ED,
Ending, Credits, Outro). Without either, on anything longer than 20
minutes, **Skip 1:30** floats there during the first 6 minutes. Skip OP
and Skip 1:30 show for 5 seconds when they come up, then only with the
controls; Skip ED and Next episode show only with the controls.

**Change video** (⋯) opens the Library tab with the player in the mini;
the library starts on the series you are watching.

## Screenshots

- **S** freezes the picture for you alone (the video keeps playing for
  everyone): drag over the part you want, or click for all of it. **T**
  switches subtitles on or off in the shot; Esc gives it up.
- **Shift+S** takes the whole picture at once.

Each one is saved in your Pictures folder under `Starsync`, named after
the show, episode and moment, and copied to paste anywhere. Click the
little preview to crop it again.

## Picture quality and shaders

Each viewer can run mpv GLSL shaders on their own picture; nobody else is
affected. Starsync ships [Anime4K](https://github.com/bloc97/Anime4K)
v4.0.1 with the presets of its mpv guide: Mode A (1080p sources), B
(720p), C (480p), A+A, B+B and C+A, each as **HQ** (strong GPUs, GTX 1080
and up) or **Fast**. **Custom shaders** runs your own `.glsl` files
(Settings → Player → Picture → More → Custom shader files).

Pick one in the player with ⚙ → Upscaling shader, or Ctrl+1…6 (Ctrl+0
turns them off); the choice is kept for the next session. Shaders cost
GPU time every frame and need hardware video rendering: on the software
fallback they do nothing, and the app says so. A shader that is missing
or fails to load shows a pop-up and switches shaders off.

## Settings

The Settings tab (Ctrl+, opens the page you last had) has six pages.
Each setting has a line of help; the common ones come first and the rest
are folded under **More**. Every change applies right away.

| Page | What is there |
|---|---|
| **Player** | Sound (Volume); Subtitles (Subtitle size, Subtitles above the controls); Picture (Upscaling shader; More: Custom shader files, Sharp video and subtitles, Hardware decoding); Controls (Player design, Controls size, Progress line when hidden; More: which buttons sit in the bar); Playback (Play the next episode automatically; More: BRB hold, Continue-without hold) |
| **Party** | You (picture, name, colour); How people look (Avatar shape, rounded square or circle; Badges, icons or words; Avatars in the top bar, overlapping or side by side); Your server (Port and Password for Invite); Recent servers |
| **Notifications & sounds** | Over the video (Notifications: Toasts or Danmaku; Chat pop-ups: All, Only when paused or Off; Joins and leaves too; More: the danmaku look and what pops up when); Sounds (App sounds, Sound set; More: each sound with a preview, its own set and a switch) |
| **Library & accounts** | Jellyfin servers; AnimeFlow, once a server offered it; Web links (yt-dlp and its cookies) |
| **Updates** | Where updates stand, Check now; More: Update channel, Config address |
| **Help & about** | Something wrong? (Copy diagnostics, Open logs folder, Mark a problem, Share diagnostics with the server); Keyboard shortcuts; About (version, credits, Open-source licenses) |

Some defaults worth knowing:

- **Hardware decoding**: Auto (mpv's `auto-copy` on Windows, `auto`
  elsewhere), Off or Custom. Turn it off if the picture glitches or stays
  black. The environment variable `SYNC_RELAY_HWDEC` overrides it.
- **Subtitles above the controls**: off; bottom lines then move up only
  for the pill and the quick chat box.
- **Progress line when hidden**: on; a thin line at the bottom of the
  video while the controls are hidden.

**The player panel.** ⚙ in the player's bar opens a narrow panel at the
right edge that stays open while you watch, until its × or Esc. Its
sections fold: Sound (Volume and App sounds), Subtitles & audio (the
tracks, subtitle size, subtitles above the controls), Picture (Upscaling
shader; Troubleshooting: sharp video and hardware decoding), Over the
video (notifications, chat pop-ups, danmaku look) and Controls (player
design, controls size, progress line). They are the same settings as the
Settings tab. **All settings** opens the matching Settings page.

## Keyboard shortcuts

Also in the app: Settings → Help & about → Keyboard shortcuts. Keys never
act while you type in a text field.

**While the player fills the window:**

| Key | Action |
|---|---|
| Space | Play / pause for everyone; hold: BRB (anywhere in a server) |
| Hold Space | While someone is BRB: continue without them (a tap: BRB too, or back) |
| Right button | On the video: the menu (BRB, skip ahead, Out); Esc closes it |
| ← / → | Seek back / forward 10 s |
| ↑ / ↓, wheel | Volume up / down (up to 150 %) |
| M | Mute / unmute |
| Shift+→ | Skip 1:30 (for everyone) |
| PgDn / PgUp | Previous / next chapter |
| F | Toggle fullscreen |
| Enter | Quick chat box (Enter sends, Esc closes) |
| Tab | Open / close chat & activity (anywhere in a server) |
| Ctrl+R | Reload the video |
| S | Screenshot of an area: drag over the frozen frame, click for all of it (T: subtitles, Esc: cancel) |
| Shift+S | Screenshot of the whole frame at once (saved to Pictures/Starsync and copied) |
| > or Shift+N | Play what is next: Up next, else the next episode |
| < or Shift+P | Put up the previous episode |
| Ctrl+1…6 | Shaders: Anime4K mode A, B, C, A+A, B+B, C+A |
| Ctrl+0 | Shaders off |
| Esc | Close a menu, the player settings panel, the chat or fullscreen, shrink the player, then ask to leave |

**Anywhere:**

| Key | Action |
|---|---|
| Ctrl+, | Settings |
| Ctrl+V | Open a pasted link, file or invite (outside a text field) |
| Ctrl+Shift+B | Mark a problem in the session log |

**Jellyfin library:**

| Key | Action |
|---|---|
| / or Ctrl+F | Search |
| Esc | Clear the search, then go back |
| Backspace, Alt+← | Back |

## Dedicated server

`starsync-server` (`starsync-server.exe` on Windows) is in every download:
a small standalone server without the app, for an always-on box with no
display. Run it, then everyone, you included, uses Join a friend.

```sh
./starsync-server --port 8080 --secret <password>
```

It prints `READY port=… name=…` once listening and stops cleanly on
Ctrl+C or SIGTERM. A dedicated server has no host. `--help` lists the
flags.

| Flag | Default | Meaning |
|---|---|---|
| `--port`, `-p` | `8080` | TCP port, on all IPv4 interfaces |
| `--secret` | empty | the password; empty means an open server (a warning is printed) |
| `--name` | `server` | the server's name, reported by `/health` |
| `--media` | none | a local file to serve as the starting video |
| `--advertise-host` | none | the host put in file links instead of the one each viewer dialled |
| `--jellyfin` | none | a YAML or JSON file with a Jellyfin login, to pass Jellyfin videos on to viewers without an account (below) |
| `--[no-]yt-dlp` | on | read web pages (YouTube, X, …) with yt-dlp when the server fetches a link |
| `--yt-dlp-dir` | `yt-dlp` next to the binary | writable folder for the server's yt-dlp |
| `--yt-dlp-cookies` | none | a cookies.txt or cookie extension's JSON export for that yt-dlp; copied into its folder at start, removed from there when not given. It is an account login: keep it private, and use a throwaway account for YouTube |
| `--animeflow` | none | an AnimeFlow app API address (`https://anime.example.org/api/app/v1`) offered to everyone who joins, for the Schedule |
| `--config` | none | a YAML or JSON config file (below); replaces the flags above except `--jellyfin` |
| `--log-dir` | `logs` next to `--config`, else next to the binary | folder for the log files (below) |
| `--upgrade` | | update the install folder to the latest release, then exit |
| `--check-update` | | print whether a newer release exists, then exit |
| `--help`, `-h` | | show the flags |

Under systemd, the yt-dlp and logs folders default to the unit's
`StateDirectory`. When the folder next to the binary is not writable,
they go to `~/.cache/watch-together/`.

### Config file

`--config` takes a YAML file (or JSON, by the `.json` extension) with the
same settings. It keeps the password off the command line, where other
users could read it in the process list:

```yaml
port: 8080
secret: change-me
name: Movie night
mediaPath: ""          # --media
advertiseHost: ""      # --advertise-host
ytDlp: true            # --[no-]yt-dlp
ytDlpDir: ""           # --yt-dlp-dir
ytDlpCookies: ""       # --yt-dlp-cookies
animeFlow: ""          # --animeflow
```

### Jellyfin login

For friends without an account on your Jellyfin, the server can fetch
Jellyfin videos with a login of its own: a file for `--jellyfin` (or a
`jellyfin:` map in the config file) with these keys, all from the same
sign-in (Jellyfin ties a token to its client and device fields):

```yaml
baseUrl: https://jelly.example.org
token: <access token>
client: <client name the token was issued to>
device: <device name>
deviceId: <device id>
version: <client version>
serverId: ""           # optional; looked up at start when empty
```

The token is never logged. How the relay works:
[ARCHITECTURE.md "Jellyfin relay"](ARCHITECTURE.md#jellyfin-relay).

### Running it as a service

Unpack the Linux archive to `/opt/starsync`, copy
[deploy/starsync.service](../deploy/starsync.service) to
`/etc/systemd/system/`, edit its flags (better: point it at a root-only
`--config` file), then:

```sh
sudo systemctl enable --now starsync
```

A service set up before the rename (`/opt/watch-together`) must run
`starsync-server` in its `ExecStart`: updates remove the old name
`watch-together-server`.

### Port and logs

Only the server's one TCP port needs to be reachable: sync, `/health`,
file streaming and passing videos on all go through it, as plain
`ws://` and HTTP without TLS. Wire details: [PROTOCOL.md](PROTOCOL.md).

The log folder holds `server-YYYY-MM-DD.log` and the session log
`session-YYYY-MM-DD.log`, kept 7 days; passwords, tokens and cookies are
left out.

## Diagnostics and troubleshooting

**Copy diagnostics** (Settings → Help & about) puts the app's recent log
on the clipboard, without passwords, tokens or cookies: paste it to
whoever helps you, from both sides if you can. In a server it can add the
session log of the last 6 hours.

**The session log.** While you are in a server, the app also sends its
log to that server, which merges everyone's lines and its own into one
session log (next to a dedicated server's logs; your own server keeps it
in the app's logs folder), so a problem can be read afterwards from every
side. Chat is never logged, nor passwords, tokens and cookies. Any member
may read it. Don't want to share? Turn off **Share diagnostics with the
server**: your log stays on your computer.

**Mark a problem** (Ctrl+Shift+B, also in the player's ⋯ and Settings →
Help & about) puts a marker with your name, and a few words if you like,
in the session log at that moment.

When Starsync crashes or freezes, it notes it in its log by itself (on
Windows with the system's crash record, from the next start).

Common messages and fixes:

| You see | What to do |
|---|---|
| "host offline — check address and port" | Wrong address, or the port is not reachable (forwarded) from where you are. |
| "wrong server password (401)" | Ask for the password again, or a fresh invite link. |
| "the host runs an older Starsync — they need to update" (or newer, or "a different Starsync version") | Update whichever side the message names. |
| The picture is frozen but the sound plays | Ctrl+R reloads the video. |
| Everyone waits at "Waiting for Bob" | Bob is BRB or his video is still loading; his card has "Don't wait for Bob". |
| A web page shows no video | The message says which cookies were used; add cookies in Settings → Library & accounts → Web links. |
| Shaders do nothing | The video renders in software; the app says so. Check your GPU drivers. |
