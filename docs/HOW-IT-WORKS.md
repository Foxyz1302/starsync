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
        |  server  (who is ready, where are we)  |
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
  here, and sends what you do (ready, seek, chat).
- **Server**: keeps one shared clock and the list of people. It never sees
  video frames, only "position 123 s, playing". There is exactly one server
  and one watch session on it.
- **Jellyfin** (or any web host): where the video lives. For a Jellyfin
  item the server only knows which item it is; each app signs in with its
  own account and reports what it watched. For friends without an account
  the member who put it up passes it on through the server (their sign-in
  stays on their computer).

## Ways to run

- **Host from the app**: the app you click Host in also runs the server.
  Simplest. The server lives as long as that app.
- **Dedicated server**: `watch-together-server`, a separate program in the
  release tarball, for an always-on box. See the README.

Friends join either way with Join a friend in the strip at the top of the
window; guests need no Jellyfin or account.

- **Watch solo**: put something up without joining or hosting and the
  app hosts a private server reachable only from this computer, so
  watching alone works like a session (progress, next episode). Invite
  friends turns it into a normal hosted server, video and position kept.

## One session, start to finish

1. **Connect.** The app opens a WebSocket to the server and says hello
   (version, password, name, avatar). Wrong password or version: refused with
   a reason. Otherwise the server answers with a welcome and the current state.
2. **Catch up.** The app opens the current video, jumps to where the server
   says we are, and buffers. Arriving while the video is stopped, you are
   waited for; arriving while it plays, you never hold anyone back.
3. **Ready gate.** Press Space to say you are ready. The server starts
   playback only when everyone who is ready has at least 4 seconds buffered
   (or what is left, near the end). At the end everyone stops and the server
   stays finished until someone seeks back or changes the video.
   Everyone who was there before it started must be ready, so one person
   alone cannot start it for the others. A lone viewer can play alone.
4. **Play.** The server owns the clock. Each app compares its mpv position
   to the clock: a small lead slows mpv a little (0.95x), a big gap (over 5 s)
   jumps. If someone's buffer runs dry the server pauses everyone and resumes
   when they have caught up.
5. **Seek.** Anyone can seek, anytime. The server moves the clock and
   everybody follows. Seeking does not change anyone's ready flag.
6. **Swap.** Anyone can change the video by pasting another link. Everybody
   stops at 0 and the gate runs again for everyone there; ready flags stay
   as they were (a setting unreadies you instead).
7. **Leave.** Closing or leaving drops you from the server; the others keep
   going. If you vanish without saying goodbye, you are marked stale after 15 s
   (stops blocking) and removed after 30 s. The app reconnects by itself and
   takes over your old place (same member, ready flag and video).

There are no roles: anyone can seek, swap, force-ready others, nudge
anyone, and sit anyone out (the host too). Someone sitting out stays
connected and in the chat, but their app loads nothing and nobody waits
for them until they join back.

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
