<p align="center">
  <img src="apps/desktop/assets/icon/icon_256.png" width="128" height="128" alt="Starsync icon">
</p>

<h1 align="center">Starsync</h1>

<p align="center">Watch anything together with friends, in sync, each on your own screen.</p>

Starsync is a desktop app for Linux and Windows. You and your friends each
run it; when one of you plays, pauses or seeks, everyone's video does the
same. Play your own files, your Jellyfin library, links (YouTube and many
other sites) or live streams. No accounts: a friend clicks your invite
link and they are in.

Each person's video plays in a real player ([mpv](https://mpv.io)) on
their own computer, at the file's full quality, with their own subtitles,
audio track and volume. Nothing runs in a browser and nothing is
re-encoded.

<!--
  SCREENSHOT (owner to add): save a screenshot of the player with a few
  people in the top strip as docs/images/starsync.png, then uncomment:
<p align="center">
  <img src="docs/images/starsync.png" width="800" alt="Starsync playing an episode, three friends in the strip at the top and the chat open on the right">
</p>
-->

## Features

- **One clock for everyone**: play, pause, seek and skip move the whole
  group, and a friend who joins late starts at the same moment.
- **Watch anything**: files on your disk, Jellyfin, links to videos or
  web pages (through [yt-dlp](https://github.com/yt-dlp/yt-dlp)), and
  live streams, where everyone sees the same moment.
- **No accounts, no setup for guests**: an invite link carries the
  address and password; clicking it is all a friend does.
- **Made for watching together**: hold Space for BRB and everyone waits
  for you; a shared Up next with a countdown; chat (or danmaku over the
  picture); Skip OP and Next episode.
- **Jellyfin-friendly**: everyone with an account plays it with their own
  sign-in and keeps their progress; friends without one watch through
  whoever put it up.
- **Your computer is the server**: the app hosts by itself. For an
  always-on box there is a small standalone server, `starsync-server`.
- **Per-person picture**: Anime4K upscaling, your own mpv shaders,
  screenshots (S) that save and copy.

## Download

Get the latest release from
[GitHub](https://github.com/Foxyz1302/starsync/releases/latest), also on
[foxyz.ru](https://foxyz.ru):

| System | File | Notes |
|---|---|---|
| Linux (x64) | `starsync-<version>-linux-x64.tar.gz` | needs mpv's library from your distribution (the `mpv` or `libmpv2` package) |
| Windows (x64) | `starsync-<version>-windows-x64.zip` | mpv is included |

Unpack it anywhere you can write to and run `starsync` (`starsync.exe` on
Windows). Starsync updates itself: it says when a new version is out, and
installs only updates signed by its developer.

## Getting started

### Join a friend

1. Run Starsync.
2. Click the invite link your friend sent (`starsync://…`), or just copy
   it and switch to Starsync. It asks "Join Bob's server?"; press Join.
3. Tell it what to call you. Space plays and pauses for everyone.

### Invite friends

1. Pick something in the Library: a file, a Jellyfin episode or a link.
2. Press **Invite** in the strip at the top. An invite link is copied;
   send it to your friends.
3. Friends outside your home network need TCP port 8080 forwarded on your
   router to your computer (Starsync does not open ports itself), or a
   VPN such as Tailscale.

### Run a dedicated server

Each download also has `starsync-server`, which runs without a display:

```sh
./starsync-server --port 8080 --secret <password>
```

Everyone, you included, then uses **Join a friend** with the server's
address and password. Every flag, the config file and a systemd unit:
[the guide](docs/GUIDE.md#dedicated-server).

## Good to know

- **Linux and Windows only.** No macOS, phones or browsers.
- **Everyone runs the same version.** A server refuses an app with a
  different protocol and says who has to update.
- **The original file plays everywhere.** There is no transcoding, so each
  computer must be able to play it, and passing a video on to friends
  needs an upload faster than the video's bitrate (a 2 GB, 25-minute
  episode is about 11 Mbit/s).
- **Built for friends.** Anyone in a server can play, pause, change the
  video or set others out. The password keeps strangers out; the
  connection is plain `ws://` without encryption.

## Documentation

| | |
|---|---|
| [User guide](docs/GUIDE.md) | every feature, setting and keyboard shortcut, the dedicated server, troubleshooting |
| [How it works](docs/HOW-IT-WORKS.md) | a short tour of the pieces and one session from start to finish |
| [Architecture](docs/ARCHITECTURE.md) | packages, sync, media, updater, design decisions |
| [Protocol](docs/PROTOCOL.md) | the wire format between app and server |
| [Development](docs/DEVELOPMENT.md) | building, tests, releases, debugging |
| [Changelog](CHANGELOG.md) | what changed in each version |

## Build from source

You need the Flutter SDK (beta channel, Dart 3.13 or newer). On Linux,
also the build tools and libraries:

```sh
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev \
  libwayland-dev libmpv-dev libepoxy-dev
```

On Windows, Visual Studio with the "Desktop development with C++"
workload. Then:

```sh
git clone https://github.com/Foxyz1302/starsync
cd starsync/apps/desktop
flutter pub get
flutter run -d linux    # or: -d windows
```

Release builds, tests and the rest: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Feedback

Bugs and ideas go to [GitHub issues](https://github.com/Foxyz1302/starsync/issues).
When something does not play, Settings → Help & about → **Copy
diagnostics** puts the app's recent log (passwords, tokens and cookies
left out) on the clipboard; paste it into the issue.

## License and credits

Starsync is MIT-licensed: see [LICENSE](LICENSE). Everything it is built
on, with its license, is listed in the app (Settings → Help & about →
Open-source licenses) and in `THIRD_PARTY_LICENSES.txt` in each download.

- Video plays in [mpv](https://mpv.io) through the
  [media_kit](https://github.com/media-kit/media-kit) Flutter package
  (Starsync uses [its own fork](https://github.com/Foxyz1302/media-kit)).
- The upscaling shaders are [Anime4K](https://github.com/bloc97/Anime4K) by bloc97 (MIT).
- The Minimal player design's timeline and controls are inspired by
  [uosc](https://github.com/tomasklaen/uosc) by tomasklaen (LGPL-2.1; no
  uosc code is included).
- Web pages are read by [yt-dlp](https://github.com/yt-dlp/yt-dlp), which
  Starsync downloads and keeps updated by itself.
