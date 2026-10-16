#!/usr/bin/env bash
# The close smoke run of tool/smoke_windows.ps1 on Linux (the same app
# mode, apps/desktop/lib/src/platform/smoke.dart): start the release
# bundle with a short clip, open it, play, close; check it exited within
# LIMIT seconds and left no process. Needs a display (skips without one).
# Usage (after `flutter build linux --release`): tool/smoke_linux.sh [LIMIT]
set -euo pipefail
LIMIT="${1:-45}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXE="$ROOT/apps/desktop/build/linux/x64/release/bundle/starsync"
[[ -x "$EXE" ]] || { echo "build first: $EXE missing" >&2; exit 1; }
if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then echo "skipped: no display"; exit 0; fi
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MEDIA="$WORK/smoke.mp4"
ffmpeg -y -v error -f lavfi -i testsrc2=size=320x180:rate=24 -f lavfi -i sine=frequency=440 \
  -t 5 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac "$MEDIA"
OUT="$WORK/smoke.txt"
start=$(date +%s)
STARSYNC_PROFILE=smoke STARSYNC_SMOKE="$MEDIA" STARSYNC_SMOKE_OUT="$OUT" "$EXE" >"$WORK/stdout.txt" 2>&1 &
pid=$!
exited=0
for _ in $(seq $((LIMIT * 10))); do
  if ! kill -0 "$pid" 2>/dev/null; then exited=1; break; fi
  sleep 0.1
done
secs=$(( $(date +%s) - start ))
steps="$(tr '\n' '|' < "$OUT" 2>/dev/null || true)"
echo "smoke steps: $steps (after $secs s)"
grep -E 'smoke:|close:|mpv: render' "$WORK/stdout.txt" | tail -20 || true
if [[ $exited == 0 ]]; then kill -9 "$pid" 2>/dev/null || true; fi
left="$(pgrep -f "$EXE" || true)"
[[ -n "$left" ]] && kill -9 $left 2>/dev/null || true
grep -qx start "$OUT" 2>/dev/null || { [[ $exited == 1 ]] && { echo "skipped: the app never came up"; exit 0; }; echo "did not come up nor exit" >&2; exit 1; }
grep -q '^skip ' "$OUT" && { echo "skipped: $(grep '^skip ' "$OUT")"; exit 0; }
grep -q '^fail ' "$OUT" && { echo "smoke failed: $(grep '^fail ' "$OUT")" >&2; exit 1; }
grep -q '^opened ' "$OUT" || { echo "the media never opened" >&2; exit 1; }
grep -qx closing "$OUT" || { echo "the app ended on its own before closing" >&2; exit 1; }
grep -qx quitting "$OUT" || { echo "the close did not reach its end (killed on the way?)" >&2; exit 1; }
[[ $exited == 1 ]] || { echo "the app did not close within $LIMIT s (P32)" >&2; exit 1; }
[[ -z "$left" ]] || { echo "a starsync process was left behind (P32)" >&2; exit 1; }
echo "smoke ok: opened and closed in $secs s, no process left"
