#!/usr/bin/env bash
# A 720p test video for subtitle placement and sharpness: an .ass track
# (default) with a top-positioned sign (\an8) and bottom dialogue, and an
# SRT track with plain bottom lines. Needs ffmpeg.
#
#   tool/make_sub_test.sh [out.mkv] [seconds]
#
# Default output: ~/Videos/starsync-sub-test.mkv, 60 s.
set -euo pipefail

out="${1:-$HOME/Videos/starsync-sub-test.mkv}"
secs="${2:-60}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

clock() { # seconds -> H:MM:SS.cc (ass) or HH:MM:SS,mmm (srt)
  local s=$1 fmt=$2
  local h=$((s / 3600)) m=$((s % 3600 / 60)) r=$((s % 60))
  if [[ $fmt == ass ]]; then printf '%d:%02d:%02d.00' $h $m $r; else printf '%02d:%02d:%02d,000' $h $m $r; fi
}

lines=(
  "Bottom dialogue: the controls should never cover this line."
  "A second line of dialogue,\\Nsplit over two rows."
  "日本語の字幕もここに表示されます。"
  "Short one."
  "The sign at the top must stay where it is."
)

{
  cat <<'EOF'
[Script Info]
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720
WrapStyle: 0
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Noto Sans,48,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2.5,1,2,40,40,36,1
Style: Sign,Noto Serif,40,&H0000E5FF,&H000000FF,&H00301000,&H00000000,1,0,0,0,100,100,1,0,1,3,0,8,40,40,30,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
EOF
  echo "Dialogue: 0,$(clock 0 ass),$(clock "$secs" ass),Sign,,0,0,0,,{\\an8}TOP SIGN (\\\\an8): stays put"
  i=0
  for ((t = 0; t < secs; t += 4)); do
    echo "Dialogue: 0,$(clock $t ass),$(clock $((t + 4)) ass),Default,,0,0,0,,${lines[$((i % ${#lines[@]}))]}"
    i=$((i + 1))
  done
} >"$work/subs.ass"

{
  n=1
  for ((t = 0; t < secs; t += 4)); do
    echo $n
    echo "$(clock $t srt) --> $(clock $((t + 4)) srt)"
    echo "Plain SRT line $n at the bottom"
    echo
    n=$((n + 1))
  done
} >"$work/subs.srt"

mkdir -p "$(dirname "$out")"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=1280x720:rate=24:duration=$secs" \
  -f lavfi -i "sine=frequency=440:duration=$secs" \
  -i "$work/subs.ass" -i "$work/subs.srt" \
  -map 0:v -map 1:a -map 2 -map 3 \
  -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -c:a aac -b:a 96k \
  -c:s:0 ass -c:s:1 srt \
  -metadata:s:s:0 title="ASS: top sign + bottom dialogue" -metadata:s:s:0 language=eng \
  -metadata:s:s:1 title="SRT: bottom lines" -metadata:s:s:1 language=eng \
  -disposition:s:0 default -disposition:s:1 0 \
  "$out"
echo "$out"
