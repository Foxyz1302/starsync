# How it works

A five-minute tour. Details: [ARCHITECTURE.md](ARCHITECTURE.md), wire format:
[PROTOCOL.md](PROTOCOL.md).

## The pieces

```
  your PC                          friend's PC
 +-------------------+            +-------------------+
 | app  (mpv inside) |            | app  (mpv inside) |
 +---------+---------+            +---------+---------+
           | sync (WebSocket)               | sync (WebSocket)
           v                                v
        +----------------------------------------+
        |  server  (who is here, where are we)   |
        +----------------------------------------+

 video bytes come from somewhere else:
   - a link (any http/https URL): the member who put it up passes it on
     through the relay (or each app, or the server, fetches it)
   - a Jellyfin item: each app plays it with its own Jellyfin account,
     friends without one through the server
   - a file on the host's disk: the server streams it (/m/... endpoint)
   - the relay (/r/...): a member's computer passes a file, a link or a
     Jellyfin item on to the server, which keeps a few minutes in memory
     and streams it to everyone who needs it
```

- **App**: the desktop window. It draws the video with mpv, shows who is
  here, and sends what you do (play, pause, BRB, seek, chat).
- **Server**: keeps one shared clock and the list of people. It never sees
  video frames, only "position 123 s, playing". There is exactly one server
  and one watch session on it.
- **Jellyfin** (or any web host): where the video lives. For a Jellyfin
  item the server only knows which item it is; each app signs in with its
  own account and reports what it watched. For friends without an account
  the member who put it up passes it on through the server (their sign-in
  stays on their computer).

## Ways to run

- **Your server**: every app runs its own server, quietly, from start to
  close, reachable only from that computer. You are on it when you are
  not in a friend's, so watching alone works like a session (progress,
  next episode). Invite opens it to friends on your network (a second
  listener on the same server: nothing restarts, the video and Up next
  carry on) and copies an invite link (`starsync://`, with your internet
  address when the app finds it and the password when one is set); Stop
  sharing closes it again. A friend clicks the link, or just copies it,
  and their app asks to join.
- **Dedicated server**: `starsync-server`, a separate program in the
  release tarball, for an always-on box. See the README.

Friends join either way with Join a friend in the strip at the top of the
window; guests need no Jellyfin or account. Before connecting, the app
checks the server's version and says who has to update when they do not
match. Joining a friend leaves your server (it stays up); leaving theirs
brings you back.

## One session, start to finish

1. **Connect.** The app opens a WebSocket to the server and says hello
   (version, password, name, avatar). Wrong password or version: refused with
   a reason. Otherwise the server answers with a welcome and the current state.
2. **Catch up.** The app opens the current video, jumps to where the server
   says we are, and buffers. Arriving while the video is stopped and wanted
   to play, you are waited for; arriving while it plays, you never hold
   anyone back.
3. **Play and pause.** Play and pause are anyone's, one press for
   everyone (Space, or the play button). Nothing starts because time
   passed: a new video waits for one Play, then starts once everyone
   watching has at least 4 seconds buffered (or what is left, near the
   end). At the end everyone stops and the server stays finished until
   someone seeks back or changes the video.
4. **BRB.** Hold Space (or pick BRB in the right-click menu) and everyone
   waits for you: "Waiting for Bob". When the last one is back it plays
   again, if it was playing. While someone is BRB, Space makes you BRB too
   (or brings you back), and a long hold goes on without them. Out means
   nobody waits for you (closing the player, the menu, being gone on
   without, or AFK: a while without input with nothing playing); Space
   brings you in at the current moment. Someone back from a dropped
   connection or a crash shows as "Bob is back (missed 1:42)".
5. **Play.** The server owns the clock. Each app compares its mpv position
   to the clock: a small lead slows mpv a little (0.95x), a big gap (over 5 s)
   jumps. If someone's buffer runs dry the server waits for them and goes
   on when they have caught up.
6. **Seek.** Anyone can seek, anytime. The server moves the clock and
   everybody follows.
7. **Swap.** Anyone can change the video by pasting another link. Everybody
   stops at 0 and it plays again once everyone has it, if it was playing.
8. **What's next.** Up next is one list on the server for everyone, and
   an episode you put up is followed by its next one. Over a video's last
   10 s the server counts down on every screen and the next one starts the
   moment it ends; anyone can cancel it for everyone (a pause or a seek
   stops it too). The app that has what plays next puts it up; if that
   person is away for a moment, it waits for them.
9. **Leave.** Closing the app or Leave says goodbye and drops you from the
   server; the others keep going. If you vanish without a goodbye, after 15 s
   of silence you are "gone": nobody waits for your video, but you keep
   your place (BRB, out, Up next items, the video you pass on) for
   10 minutes. The app keeps playing and reconnects by itself, with an id
   of its own, and takes that place back.

There are no roles: anyone can play, pause, seek, swap, wait for someone
or go on without them, nudge anyone, and set anyone out (the host too).
Someone out stays connected and in the chat, their player stays where
they were, and nobody waits for them until they join.

Watched or not is counted by the time you were there while it played:
being out, skipping around or a quick look never counts as watching.
Jellyfin hears it for your account; files and links are remembered on
your computer.

## Where video comes from

- **Link**: you paste an http(s) URL. By default your computer opens it and
  passes it on (it plays for everyone whenever it plays for you, cookies
  included); under "Other ways" every app plays it directly, or the server
  fetches it once. A web page (YouTube, X, ...) goes through yt-dlp, which
  the app and the server download and update by themselves.
  A pasted Jellyfin link becomes the Jellyfin item below when possible.
- **Jellyfin item**: picked in the app's library browser. Shared as "this
  item on this Jellyfin server", never as a link with someone's sign-in.
- **Local file (host only)**: you pick a file on your disk. The server
  streams it to everyone, host included, over HTTP with range requests, each
  with a per-person token. Nothing is stored or converted.
- No transcoding, ever. Quality is whatever the file is.
