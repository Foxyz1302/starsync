#!/usr/bin/env bash
# Build a Linux test build here and publish it to the `dev` prerelease of
# the GitHub repo (STARSYNC_GITHUB_REPO, default Foxyz1302/starsync), where
# dev builds update from (see Updater in docs/ARCHITECTURE.md).
# No tag push, no CI, no commit: the working tree is built as it is.
# Usage: tool/dev_release.sh [--minor|--major] [--no-publish]
# Version: `<next>-dev.N`, N one past the published dev build of that
# version. <next> is the next patch after the pubspec's (1.1.2 -> 1.1.3),
# or with --minor / --major the next minor / major (1.2.0 / 2.0.0); once a
# dev line is published past the pubspec's next patch, later runs keep
# following it (1.2.0-dev.2, ...) until the release moves the pubspec.
# Token: GH_TOKEN / GITHUB_TOKEN, else `gh auth token` (tool/publish_github.dart).
# The manifest's `highlights` and `changes` (What's new) and the dev
# release's page are CHANGELOG.md's Unreleased. The manifest is signed
# (manifest.json.sig, uploaded next to it) with STARSYNC_SIGNING_KEY or
# ~/.config/starsync-signing-key (DEVELOPMENT "Signing").
# Prints the one-time command that moves a stable install onto test builds
# and sets its update channel to Dev (the `update-channel` file the app
# takes at its next start).
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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The manifest goes out signed (DEVELOPMENT "Signing"): no key, no publish,
# found out before the build. --no-publish signs only when there is one.
(cd "$ROOT/tool" && dart pub get >/dev/null)
SIGN=1
if [[ "$PUBLISH" == "1" ]]; then
  dart "$ROOT/tool/sign.dart" --check-key
elif ! dart "$ROOT/tool/sign.dart" --check-key >/dev/null 2>&1; then
  SIGN=0; echo "no signing key: the manifest stays unsigned (not published anyway)"
fi
if [[ -n "$(git -C "$ROOT" status --porcelain -- updates/starsync-config.json)" ]]; then
  echo "warning: updates/starsync-config.json has changes that are not published: dart tool/sign_config.dart, commit and push" >&2
fi
# The GitHub repo the dev prerelease lives in.
GH_REPO="${STARSYNC_GITHUB_REPO:-Foxyz1302/starsync}"
BASE_URL="https://github.com/$GH_REPO/releases/download/dev"

PUB="$(sed -n 's/^version: \([0-9.]*\).*/\1/p' "$ROOT/apps/desktop/pubspec.yaml")"
IFS=. read -r MA MI PA <<<"$PUB"
case "$BUMP" in
  patch) NEXT="$MA.$MI.$((PA + 1))" ;;
  minor) NEXT="$MA.$((MI + 1)).0" ;;
  major) NEXT="$((MA + 1)).0.0" ;;
esac
LAST="$(curl -fsSL "$BASE_URL/manifest.json" 2>/dev/null |
  python3 -I -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null || true)"
# Before the first dev build on GitHub, the numbering carries on from the
# last one published on the old host (RELEASE_REPO_URL, else origin's https
# address), so installed dev builds see the new one as newer.
if [[ -z "$LAST" ]]; then
  OLD="${RELEASE_REPO_URL:-$(git -C "$ROOT" remote get-url origin)}"; OLD="${OLD%.git}"
  if [[ "$OLD" =~ ^https?:// ]]; then
    LAST="$(curl -fsSL "$OLD/releases/download/dev/manifest.json" 2>/dev/null |
      python3 -I -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null || true)"
  fi
fi
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
MANIFEST_CHANGES="$(dart "$ROOT/tool/changelog.dart" json unreleased 2>/dev/null || echo '{}')" \
python3 -I - "$MANIFEST" <<'EOF'
import json, os, sys
e = os.environ
url = e['MANIFEST_URL']
# `assetSha256` is what apps from 1.5.0 on check (and require); the
# string `sha256` is for older test builds, which check only that.
manifest = {'version': e['MANIFEST_VER'], 'protocol': int(e['MANIFEST_PROTO']),
            'url': url, 'sha256': e['MANIFEST_SHA'], 'notes': e['MANIFEST_NOTES'],
            'assets': {'linux-x64': url}, 'assetSha256': {'linux-x64': e['MANIFEST_SHA']}}
# What's new in a test build: CHANGELOG.md's Unreleased, when it has items.
log = json.loads(e['MANIFEST_CHANGES'])
changes = log.get('changes') or {}
if any(changes.values()):
    manifest['changes'] = changes
    if log.get('highlights'):
        manifest['highlights'] = log['highlights']
with open(sys.argv[1], 'w') as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
EOF
rm -f "$MANIFEST.sig"
if [[ "$SIGN" == "1" ]]; then dart "$ROOT/tool/sign.dart" "$MANIFEST"; fi

if [[ "$PUBLISH" != "1" ]]; then
  echo "built $TARBALL (not published)"; exit 0
fi
# The publisher retries failed uploads itself and puts the manifest (and
# its .sig) up last, so the previous build stays current until then.
dart "$ROOT/tool/publish_github.dart" --repo "$GH_REPO" dev "$TARBALL" "$MANIFEST"

cat <<EOF

Published $VERSION. Dev builds pick it up with their next update check.
A stable install moves onto test builds (update channel Dev) once: with the app open, run (bash)
  p=\$(pgrep -xo starsync) && d=\$(dirname "\$(readlink /proc/\$p/exe)") && t=\$(mktemp -d) && curl -fsSL $BASE_URL/$(basename "$TARBALL") | tar -xz -C "\$t" --strip-components=1 && cp -rf --remove-destination "\$t"/. "\$d"/ && echo dev > "\$d"/update-channel && rm -rf "\$t" && echo "Done: restart the app." || echo "Failed: is the app open?"
EOF
