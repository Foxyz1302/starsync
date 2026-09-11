# mpv HTTP contract (Phase 1, verified against Relic endpoint)

Spike: `tool/range_logger.dart` (Relic, `mountMediaRoute` + `onLog` hook).
Player: stock mpv CLI headless (`--vo=null --ao=null`). Server logs
`METHOD path range=<h> -> status bytes=<n>`.

## Real traces

mp4, 570692 B, full play (`--frames=300`):

```text
get /m/file range=- -> 200 bytes=570692
get /m/file range=bytes=0- -> 206 bytes=570692
```

One no-Range open (mpv probes full length), then a single open-ended
stream to EOF. Small file fits demuxer cache; one connection does it all.

mkv (ffmpeg remux of same file), 562197 B, play + `--start=8` seek:

```text
get /m/file range=bytes=0- -> 206 bytes=562197
get /m/file range=bytes=0- -> 206 bytes=562197
get /m/file range=bytes=562093- -> 206 bytes=104
get /m/file range=bytes=243694- -> 206 bytes=318503
```

Two `bytes=0-` opens (demuxer probe + playback), a 104 B tail read at
`size-104` (Cues-at-EOF probe — mpv expresses it open-ended, not as
`bytes=-n`; the server answers both identically), then a mid-file open
at a cluster boundary for the seek/start position. Seeks always arrive
as a fresh `bytes=N-` connection, never as a mutation of the old one.

Outage: server SIGINT-killed 5 s mid-play (looping file, comma-form
reconnect flags), restarted. mpv kept playing from cache, no error, no
reconnect storm; no new Range request inside the post-restart window.
Short drops are ridden out from cache — matches the north-star case.
Cache-exhaustion reconnect (long drop) is a Phase 5 chaos assertion;
`tool/shaper.dart` (KB/s cap + latency + `--kill-after`) exists for it.

## Server behavior table (all byte-exact tested, 16 server tests)

| Request | Response |
|---|---|
| no Range | 200, exact `Content-Length`, full bytes |
| `bytes=a-b` | 206, `Content-Range: a-b/size`, exact length |
| `bytes=a-` | 206 open-ended to EOF, exact length |
| `bytes=-n` | 206 tail `size-n..EOF` (Cues probe) |
| unsatisfiable start | 416 + `Content-Range: bytes */size` |
| host offline | 503 + `Retry-After: 2` (mpv retries with reconnect flags) |
| bad token / kicked / gone | 401 / 403 / 410 |

Always: `Accept-Ranges: bytes`; `Content-Type` from extension
(mkv `video/x-matroska`, mp4 `video/mp4`, webm, avi, mov, ts, mka/mp3).

## Relic notes

- Range arrives as typed `RangeHeader` (`req.headers.range`), not a raw
  string. Multi-range takes the first entry; unit is preserved so
  non-`bytes` units still 416. `resolveMediaRequest` in
  `packages/server` stays framework-agnostic and is the tested truth.
- Reconnect flag syntax is build-sensitive: this mpv rejected the
  colon-joined `--stream-lavf-o=a=1:b=1` form and accepted commas.
  The exact media_kit property set is re-verified in Phase 4 through
  mpv `set_property`, not CLI flags.

## Remaining manual (human + media_kit, Phase 4)

1.4 GB real file through the endpoint with the pinned buffer props;
long-outage reconnect with cache exhaustion via shaper.
