#!/usr/bin/env bash
# Build a Linux test build here and publish it to the `dev` prerelease on
# Gitea, where dev builds update from (see Updater in docs/ARCHITECTURE.md).
# No tag push, no CI, no commit: the working tree is built as it is.
# Usage: tool/dev_release.sh [--minor|--major] [--no-publish]
# Version: `<next>-dev.N`, N one past the published dev build of that
# version. <next> is the next patch after the pubspec's (1.1.2 -> 1.1.3),
# or with --minor / --major the next minor / major (1.2.0 / 2.0.0); once a
# dev line is published past the pubspec's next patch, later runs keep
# following it (1.2.0-dev.2, ...) until the release moves the pubspec.
# Token: RELEASE_TOKEN, else the file ~/.config/watch-together-release-token
# (a Gitea access token with repository read/write; keep the file 0600).
# Prints the one-time command that moves a stable install onto test builds.
set -euo pipefail

PUBLISH=1
BUMP=patch
for arg in "$@"; do
  case "$arg" in
    --no-publish) PUBLISH=0 ;;
    --minor) BUMP=minor ;;
    --major) BUMP=major ;;
    *) echo "usage: $0 [--minor|--major] [--no-publish]" >&2; exit 1 ;;
  esac
done
TOKEN_FILE="$HOME/.config/watch-together-release-token"
if [[ -z "${RELEASE_TOKEN:-}" && -f "$TOKEN_FILE" ]]; then
  RELEASE_TOKEN="$(tr -d '[:space:]' <"$TOKEN_FILE")"; export RELEASE_TOKEN
fi
if [[ "$PUBLISH" == "1" && -z "${RELEASE_TOKEN:-}" ]]; then
  echo "error: set RELEASE_TOKEN or write $TOKEN_FILE (or pass --no-publish)" >&2; exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_URL="https://git.example.org/Foxyz/sync_replay_project/releases/download/dev"

PUB="$(sed -n 's/^version: \([0-9.]*\).*/\1/p' "$ROOT/apps/desktop/pubspec.yaml")"
IFS=. read -r MA MI PA <<<"$PUB"
case "$BUMP" in
  patch) NEXT="$MA.$MI.$((PA + 1))" ;;
  minor) NEXT="$MA.$((MI + 1)).0" ;;
  major) NEXT="$((MA + 1)).0.0" ;;
esac
LAST="$(curl -fsSL "$BASE_URL/manifest.json" 2>/dev/null |
  python3 -I -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null || true)"
# A published dev line past <next> (started with --minor/--major) wins.
LAST_BASE="${LAST%%-dev.*}"
if [[ -n "$LAST" && "$LAST_BASE" != "$NEXT" &&
      "$(printf '%s\n%s\n' "$NEXT" "$LAST_BASE" | sort -V | tail -1)" == "$LAST_BASE" ]]; then
  NEXT="$LAST_BASE"
fi
N=1
if [[ "$LAST" == "$NEXT-dev."* ]]; then N=$(( ${LAST##*-dev.} + 1 )); fi
export VERSION="$NEXT-dev.$N"
echo "building $VERSION (last published: ${LAST:-none})"

"$ROOT/tool/package_linux.sh" --no-upload
TARBALL="$ROOT/dist/starsync-$VERSION-linux-x64.tar.gz"
[[ -f "$TARBALL" ]] || { echo "error: $TARBALL missing" >&2; exit 1; }

NOTES="$(git -C "$ROOT" log -1 --format=%s)"
[[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]] && NOTES="$NOTES (+ uncommitted changes)"
MANIFEST="$ROOT/dist/manifest.json"
MANIFEST_VER="$VERSION" \
MANIFEST_PROTO="$(sed -n 's/.*protoMax = \([0-9]*\).*/\1/p' "$ROOT/packages/core/lib/src/constants.dart")" \
MANIFEST_URL="$BASE_URL/$(basename "$TARBALL")" \
MANIFEST_SHA="$(sha256sum "$TARBALL" | cut -d' ' -f1)" \
MANIFEST_NOTES="Test build: $NOTES" \
python3 -I - "$MANIFEST" <<'EOF'
import json, os, sys
e = os.environ
url = e['MANIFEST_URL']
with open(sys.argv[1], 'w') as f:
    json.dump({'version': e['MANIFEST_VER'], 'protocol': int(e['MANIFEST_PROTO']),
               'url': url, 'sha256': e['MANIFEST_SHA'], 'notes': e['MANIFEST_NOTES'],
               'assets': {'linux-x64': url}}, f, indent=2)
EOF

if [[ "$PUBLISH" != "1" ]]; then
  echo "built $TARBALL (not published)"; exit 0
fi
# Gitea sometimes resets the upload; the previous build stays up meanwhile.
for try in 1 2 3; do
  dart "$ROOT/tool/release_publish.dart" dev "$TARBALL" "$MANIFEST" && break
  [[ "$try" == 3 ]] && { echo "error: upload failed 3 times" >&2; exit 1; }
  echo "upload failed, retrying ($try/3) ..."; sleep 3
done

cat <<EOF

Published $VERSION. Dev builds pick it up with their next update check.
A stable install moves onto test builds once: with the app open, run (bash)
  p=\$(pgrep -xo 'starsync|watch_together') && d=\$(dirname "\$(readlink /proc/\$p/exe)") && t=\$(mktemp -d) && curl -fsSL $BASE_URL/$(basename "$TARBALL") | tar -xz -C "\$t" --strip-components=1 && cp -rf --remove-destination "\$t"/. "\$d"/ && rm -rf "\$t" && echo "Done: restart the app." || echo "Failed: is the app open?"
EOF
