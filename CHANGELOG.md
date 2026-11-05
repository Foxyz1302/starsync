# Changelog

What changed in each Starsync version, newest first, in plain words. The
app shows a version's section when it offers the update and once after it
(`What's new`); the release page shows it too. How entries are added and
cut into a release: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#changelog).

## Unreleased

### Highlights

- BRB instead of ready: hold Space and everyone waits for you, and nothing starts by itself any more
- A round menu on a right-click hold: BRB, skip the OP or go to the next episode, step out or join
- Screenshots: S picks an area (with or without subtitles), Shift+S takes the whole picture
- People cards: point at someone's avatar or name to see their card
- Jellyfin: right-click has everything, and a whole show or season can be marked watched
- Smoother on Linux at your monitor's refresh rate, and crashes on Windows should be rarer
- Joining without a name just asks what to call you, and settings live in six tidy pages
- Closing the window really closes Starsync, and memory no longer grows with every video
- Your volume is remembered, and M mutes

### Added

- The video's volume is remembered: the next start begins where you left it
- M mutes and unmutes the video
- When Starsync crashes or freezes, it now notes it in the diagnostics it shares by itself (on Windows with the system's crash report from the next start), so a problem can be tracked down without you sending anything
- Mark a whole Jellyfin show or season watched (or unwatched) from its page or its right-click menu; a whole show asks first
- People cards: rest the mouse on someone (their avatar in the top bar or in fullscreen, a member's row, a chat line, a toast, or click a danmaku line's name) for a card with a bigger picture (click it to see it full size), whether they are watching, BRB, AFK, out or reconnecting, their Starsync version and what they pass on, plus Wait for / Don't wait for, Nudge and Out. A click keeps it open
- BRB: hold Space for half a second and everyone waits for you ("Waiting for Bob"); when you are back it plays on if it was playing. While someone is BRB, Space makes you BRB too or brings you back, and holding it for 2 seconds goes on without them
- Right-click and hold on the video (or right-click, then click) for a round menu: BRB or I'm back, Skip OP, Skip 1:30 or Next episode, Out or Join
- "Wait for Bob" on someone's card when they ran off without pressing anything, and "Don't wait for Bob" to go on without whoever everyone waits for
- Someone who comes back from further behind (out, a crash, a stalled video) gives everyone "Rewind for Alice (1:42)" for half a minute
- Up next counts down over the last 10 seconds of a video and the next one starts the moment it ends; a pause or Cancel stops it at the end. Clips under a minute just say what is up next
- Avatar shape: everyone's picture as a rounded square, or as a circle (Settings → Party → More)
- Screenshots: S freezes the picture for you alone (the video keeps playing for everyone) so you can drag over the part you want, or click for all of it, with or without subtitles (T); Shift+S takes the whole picture at once. Each lands in Pictures/Starsync, named after the show, episode and moment, and is copied to paste anywhere; click the little preview to crop it again

### Changed

- Updates and the Schedule now come from example.org (the old update address stopped working)
- Linux: animations, scrolling and dragging follow your monitor's refresh rate (for example 75 Hz) instead of a fixed 60, and dragging rows with a fast mouse no longer stutters
- Play and pause are everyone's: one press of Space or the play button plays or pauses for the whole group, and nobody presses "ready" any more (the ready count, Force ready and Mark everyone ready are gone). A new video waits for one Play, and putting something up keeps it playing or paused
- Nothing starts by itself because time passed: the group waits for a video that is still loading until it is there or someone goes on without it
- The pill at the bottom says who everyone waits for, with their pictures and the keys that do something now ("Space: BRB too · Hold Space: continue without"); holding Space fills it, and subtitles move up out of its way
- Out replaces sitting out: nobody waits for you, your player stays where you were, and Space or Join brings you in at the current moment. Closing the player, or the window minimised for 10 minutes while it plays, sets you out
- AFK replaces auto sit-out: 10 minutes without input while nothing plays; any key or the mouse brings you back. It has no switch any more
- Pictures fill their shape, with a small badge for BRB (a cup), AFK (Zz) and out (a crossed eye) instead of a coloured ring; loading and reconnecting run round the edge, and the pictures in the top bar are bigger
- "Next episode" shows through the ending, or the last 90 seconds when the ending is not known
- An Up next item that does not come up in time is asked of someone else who can put it up (or once more) instead of quietly stopping
- Everyone needs this version: an older app is told to update before it joins
- The server's name in the top bar shows it can be clicked (a ▾, a hover and a tooltip): it opens everyone in the server
- A pasted or dropped link or video says "Opening youtube.com…" (or "Adding … to Up next…") at the bottom of the window until it is up
- The player's timeline shows exactly which parts of the video are downloaded, also behind you and around a jump, not just how far ahead (both designs, and Minimal's thin line)
- The volume slider now stays next to the speaker in the player (in a narrow window it still slides out when you point at the speaker)
- The player panel opens with Sound: the video's volume and App sounds (how loud the app's own cues are, so the two are no longer confused); its All settings button opens the matching Settings page
- ⚙ in the player now opens and closes the player settings panel directly. Change video, Copy link, Reload video, Skip 1:30, Chapters, Mark a problem and Leave server moved to a new ⋯ button in the player's top bar ("Video and session"), next to Up next. The shader is picked in the panel (or with Ctrl+0…6)
- The player panel shows the same rows with the same names as Settings: Subtitles & audio together, the upscaling shader with HQ or Fast under it, sharp video and hardware decoding folded under Troubleshooting, and now chat pop-ups and the controls size too
- Settings → Notifications & sounds starts with what shows over the video (toasts or danmaku, chat pop-ups, joins and leaves); the danmaku look with its preview, what pops up when, and each sound's own settings are under More
- Settings has six pages: Player, Party, Notifications & sounds, Library & accounts, Updates, and Help & about. Each starts with the settings people change and folds the rest under More, and Ctrl+, opens on Player
- Your picture, name and colour can be changed right in Settings → Party, next to your server and recent servers
- yt-dlp and its cookies are in Settings → Library & accounts → Web links (where a "needs cookies" message now points), and "Play the next episode automatically" is in Settings → Player
- Diagnostics, sharing them with the server, the keyboard shortcuts (now all of them: M, Ctrl+, Ctrl+V and the library's keys) and About are together in Settings → Help & about
- A few choices made way for their defaults: the controls always hide after 3 s, and updates are always checked (nothing installs without asking). The time display follows a click on the time, and hiding re-releases is in the Latest row's menu
- Joining without a name no longer stops with an error: the app asks "Wait, what do we call you?" right there (your computer's user name to start with, plus picture and colour), and OK carries on with the join
- In fullscreen the party's avatars come up with the controls, also while the video plays, and work like the ones in the strip
- A click on an avatar in the top bar now opens that person's card; who is in the server opens from the server's name next to the avatars (or "Everyone in the server" on a card)
- A message sent from the quick chat box now shows as your own chat bubble with everyone else's, instead of a separate echo where the box was
- A pasted or dropped link goes up with one click on its card, like adding it to Up next (it used to open the Link page first). While the others are watching something, Add to queue comes first on the card and putting up says "Put it up now"
- The old program names from before Starsync (`watch_together`, `watch-together-server`, `.exe` on Windows) are gone from the folder: if you start Starsync from an old shortcut, make a new one to `starsync` / `starsync.exe`
- A Jellyfin item's right-click menu now has everything its details panel has, with the same names and icons: Mark watched or unwatched, Remove from Continue and Open the show page sit next to Put it up, the queue, Copy title and Open in Jellyfin, for episodes, movies, shows and seasons everywhere they show. A mark shows on every row at once
- Right-click a show in Files to put up its next episode or open its page; a video's right-click works without a server too, and a link's preview has the same menu as a recent link
- What's new shows a version's few highlights; All changes opens the full list right there
- Linux: menus, the timeline and chat stay smooth over a playing video instead of stuttering along with it, and sound and picture line up more closely
- Windows: the video player runs on a much newer mpv, and players are shut down more safely, which should make crashes while opening or switching videos rarer

### Fixed

- Closing the window could leave Starsync running unseen in the background, with its players, for hours; it now ends within a few seconds (and always within 20)
- A video could take seconds to show, or Up next could stop getting ready, when it was started while nothing on screen moved
- Video memory no longer grows with every video played (about 10 MB more per video at 2560×1080 until the app was closed)
- Linux: the app gives memory back after a video (or a folder's thumbnails) is done, instead of keeping more with every video
- The player panel's hardware decoding offered Custom with nowhere to type the value; it has the field now, as in Settings
- A chat message that arrived before the sender's picture showed only their initial; the picture now appears as soon as it is there
- After a server is updated, the members card shows its new version (it kept the old one until you rejoined)
- The arrow keys could move to the window buttons at the top, and Enter then closed the app; the window buttons never take the keys now, and in the player the arrows and Enter only do player things
- PgUp and PgDn went the wrong way through chapters: PgUp is the next chapter and PgDn the previous one, as in mpv
- Minimal player design: a click near the time at the end of the timeline switched the time display instead of seeking; only a click on the time itself switches it now
- When the person passing a video on stopped sending it for a while (about 40 s or more), your video could stop as if it had ended; it now opens again where everyone is once the video comes through again
- With the window in the background, a burst of news (a video change, Up next, chat) no longer makes some desktop notifications go missing (KDE refused them): the first shows at once and the rest come together in one a few seconds later

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
