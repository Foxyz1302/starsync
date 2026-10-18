# Changelog

What changed in each Starsync version, newest first, in plain words. The
app shows a version's section when it offers the update and once after it
(`What's new`); the release page shows it too. How entries are added and
cut into a release: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#changelog).

## Unreleased

### Added

- The video's volume is remembered: the next start begins where you left it
- M mutes and unmutes the video

### Changed

- The volume slider now stays next to the speaker in the player (in a narrow window it still slides out when you point at the speaker)
- The player panel opens with Sound: the video's volume and App sounds (how loud the app's own cues are, so the two are no longer confused); its All settings button opens the matching Settings page
- ⚙ in the player now opens and closes the player settings panel directly. Change video, Copy link, Reload video, Skip 1:30, Chapters, Mark everyone ready, Mark a problem and Leave server moved to a new ⋯ button in the player's top bar ("Video and session"), next to Up next. The shader is picked in the panel (or with Ctrl+0…6)
- Joining without a name no longer stops with an error: the app asks "Wait, what do we call you?" right there (your computer's user name to start with, plus picture and colour), and OK carries on with the join
- In fullscreen the party's avatars come up with the controls, also while the video plays, and work like the ones in the strip: hover for names, click for who is in the server
- A message sent from the quick chat box now shows as your own chat bubble with everyone else's, instead of a separate echo where the box was

### Fixed

- The player panel's hardware decoding offered Custom with nowhere to type the value; it has the field now, as in Settings
- A chat message that arrived before the sender's picture showed only their initial; the picture now appears as soon as it is there
- After a server is updated, the members card shows its new version (it kept the old one until you rejoined)

## 1.4.0

Links you put up are downloaded once for everyone, quick chat and danmaku in the player, plus What's new and fixes for Windows, the relay and chat.

### Added

- What's new: the update band shows what changed, and after an update the app shows the full list once (also in Settings → About)
- Update channel in Settings → Updates: Stable, or Dev for test builds; Dev stays on test builds after a release and still gets the newer release when there is one
- Sharper subtitles and picture: the video and its subtitles are drawn at your screen's resolution instead of the video's (Settings → Player → Sharp video and subtitles, on by default)
- Invite links: Invite copies just a starsync:// link, password included, so a friend just clicks it (or copies it and switches to Starsync) and the app asks "Join Bob's server?"
- Invite finds your internet address on its own and says when your router needs the port forwarded; Other addresses picks your home-network or VPN address instead
- Starsync runs once: a link clicked while it is open goes to the open window
- Quick chat: press Enter in the big player to type a message in a small box at the bottom, without opening the chat panel and without the mouse pointer or the controls popping up; it shares its draft with the chat panel, closes by itself when you stop typing, and subtitles move up out of its way
- Danmaku notifications: chat, joins, leaves and Up next can fly across the top of the picture instead of popping up (Settings → Notifications & sounds → Notifications: Danmaku, off by default), with speed, how many at once, where, opacity, size, boldness, outline and avatars all adjustable and a live preview
- Player panel: ⚙ → Player settings opens a panel at the right of the player that stays open while you watch, with tracks, subtitle size, picture, volume and notification settings
- Subtitles can move up above the controls while they show (Settings → Player → Subtitles above the controls, off by default), and their size can be changed

### Changed

- A link you put up is downloaded once: you and everyone else watch the same stream, so nobody drifts ahead or stalls alone, and sites like Bilibili are far less likely to block it

### Fixed

- Upscaling shaders (Anime4K, the HQ modes) no longer shift the colours or draw a grid over the picture, which showed most in a large window or fullscreen
- Sharp video: resizing the window or opening the chat panel no longer shrinks the picture for a moment before it jumps back
- Joining while something plays on Windows: the video opens again by itself when it was too early
- Relay: players no longer get stuck after a slow or stalled source
- Relay: X (Twitter) clips play through the relay
- Relay: gentler retries, so Bilibili stops blocking the server
- Relay: a source that refuses the old link (412) gets a fresh address and keeps playing
- Chat pop-ups stay away while the chat panel is open (the sound still plays)
- Bilibili and other sites no longer stop a video halfway when you watch alone or with "Everyone fetches it": a cut connection picks up where it left off

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
