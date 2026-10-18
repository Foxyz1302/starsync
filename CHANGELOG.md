# Changelog

What changed in each Starsync version, newest first, in plain words. The
app shows a version's section when it offers the update and once after it
(`What's new`); the release page shows it too. How entries are added and
cut into a release: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#changelog).

## Unreleased

Links you put up are downloaded once for everyone, plus What's new and fixes for Windows, the relay and chat.

### Added

- What's new: the update band shows what changed, and after an update the app shows the full list once (also in Settings → About)
- Sharper subtitles and picture: the video and its subtitles are drawn at your screen's resolution instead of the video's (Settings → Player → Sharp video and subtitles, on by default)
- Invite links: Invite copies a starsync:// link; a friend clicks it (or just copies it and switches to Starsync) and the app asks "Join Bob's server?"
- Invite finds your internet address, lets you pick it or your home-network address, and says when your router needs the port forwarded
- The password goes into an invite link only when you tick "Include the password in the link"
- Starsync runs once: a link clicked while it is open goes to the open window

### Changed

- A link you put up is downloaded once: you and everyone else watch the same stream, so nobody drifts ahead or stalls alone, and sites like Bilibili are far less likely to block it

### Fixed

- Joining while something plays on Windows: the video opens again by itself when it was too early
- Relay: players no longer get stuck after a slow or stalled source
- Relay: X (Twitter) clips play through the relay
- Relay: gentler retries, so Bilibili stops blocking the server
- Relay: a source that refuses the old link (412) gets a fresh address and keeps playing
- Chat pop-ups stay away while the chat panel is open (the sound still plays)

## 1.3.2

Fixes Windows closing by itself about 3 seconds after every start.

### Fixed

- Windows: the app no longer closes by itself about 3 seconds after starting (1.3.0 and 1.3.1)

## 1.3.1

Joining another server no longer opens an empty player, a cleaner mini player and a softer Minimal progress line.

### Changed

- A cleaner mini player: just the picture, play and a plain progress bar
- Minimal controls: the progress line shown while the controls hide is softer and easier on the eyes

### Fixed

- Joining another server no longer opens an empty player

## 1.3.0

The app is now called Starsync and was rebuilt inside for stability: a shared countdown to what plays next, honest watched marks, faster relay seeks and many fixes. Everyone must update to keep watching together.

### Added

- A shared countdown to what plays next, and anyone can cancel it
- The next episode of your local files continues by itself ("Continues with")
- System notifications while the window is in the background
- Your own server is always running: Invite your friends straight in
- See the server's version and everyone's app version
- The library matches your shows with AniList
- A new sound engine and new sounds

### Changed

- The app is now called Starsync (your settings and data come along)
- "Watched" counts only the time you actually watched (Jellyfin too)
- Joining no longer pauses everyone
- A dropped connection comes back as the same member, not a new one
- A server restart no longer loses what was playing
- Faster seeks over the relay

### Fixed

- The app no longer freezes on exit
- Shaders on Windows
- X11: video renders properly again (also with software rendering)
- Black video when joining mid-play on X11
- Many stability fixes from the rebuild
