#!/usr/bin/env bash
# Cut a release without typing a version anywhere: derives the next
# version (patch by default), bumps all three pubspecs in lockstep,
# writes updates/manifest.json (predictable asset URL — no CI roundtrip
# needed), commits, and tags. Review, then `git push --follow-tags` —
# CI takes it from there (build, Forgejo release, asset upload).
# Usage: tool/release.sh [patch|minor|major] [--dry-run]
set -euo pipefail

BUMP=patch
DRY=0
for arg in "$@"; do
  case "$arg" in
    patch|minor|major) BUMP="$arg" ;;
    --dry-run) DRY=1 ;;
    *) echo "usage: $0 [patch|minor|major] [--dry-run]" >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBSPECS="apps/desktop/pubspec.yaml packages/core/pubspec.yaml packages/server/pubspec.yaml"

LATEST="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
if [[ -z "$LATEST" ]]; then
  VER="$(sed -n 's/^version: \([0-9.]*\).*/\1/p' "$ROOT/apps/desktop/pubspec.yaml")"
  WHY="no tags yet — first release takes the pubspec version"
else
  BASE="${LATEST#v}"
  IFS=. read -r MA MI PA <<<"$BASE"
  case "$BUMP" in
    major) MA=$((MA + 1)); MI=0; PA=0 ;;
    minor) MI=$((MI + 1)); PA=0 ;;
    patch) PA=$((PA + 1)) ;;
  esac
  VER="$MA.$MI.$PA"
  WHY="bump $BUMP from $LATEST"
fi
if git -C "$ROOT" rev-parse "v$VER" >/dev/null 2>&1; then
  echo "error: tag v$VER already exists" >&2
  exit 1
fi
echo "release will be v$VER ($WHY)"

if [[ "$DRY" == "1" ]]; then
  exit 0
fi
for f in $PUBSPECS; do
  sed -i -E "s/^version: .*/version: $VER/" "$ROOT/$f"
done

ORIGIN="$(git -C "$ROOT" remote get-url origin)"
SERVER="$(echo "$ORIGIN" | sed -E 's#(https?://[^/]+)/.*#\1#')"
REPO="$(echo "${ORIGIN%.git}" | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#')"
PROTO="$(sed -n 's/.*protoVersion = \([0-9]*\).*/\1/p' "$ROOT/packages/core/lib/src/constants.dart")"
if [[ -n "$LATEST" && "$LATEST" != "v$VER" ]]; then
  NOTES="$(git -C "$ROOT" log -n 20 "$LATEST..HEAD" --format='- %s')"
else
  NOTES="Watch together $VER."
fi
export MANIFEST_FILE="$ROOT/updates/manifest.json" MANIFEST_VER="$VER" \
  MANIFEST_PROTO="$PROTO" MANIFEST_NOTES="$NOTES" \
  MANIFEST_BASE="$SERVER/$REPO/releases/download/v$VER/watch-together-$VER"
python3 - <<'EOF'
import json, os
path = os.environ['MANIFEST_FILE']
try:
    with open(path) as f:
        manifest = json.load(f)
except (FileNotFoundError, ValueError):
    manifest = {}
base = os.environ['MANIFEST_BASE']
# Asset names must match tool/package_linux.sh / package_windows.ps1.
# `url` stays the Linux tarball for builds that predate `assets` (<= 0.2.1).
assets = {
    'linux-x64': base + '-linux-x64.tar.gz',
    'windows-x64': base + '-windows-x64.zip',
}
manifest.update({
    'version': os.environ['MANIFEST_VER'],
    'protocol': int(os.environ['MANIFEST_PROTO']),
    'url': assets['linux-x64'],
    'assets': assets,
    'notes': os.environ['MANIFEST_NOTES'].splitlines()[0] if os.environ['MANIFEST_NOTES'] else '',
})
manifest.pop('sha256', None)
with open(path, 'w') as f:
    json.dump(manifest, f, indent=2)
    f.write('\n')
EOF

git -C "$ROOT" add $PUBSPECS updates/manifest.json
if git -C "$ROOT" diff --cached --quiet; then
  echo "everything already at $VER — tagging only"
else
  git -C "$ROOT" commit -m "Release v$VER" -- $PUBSPECS updates/manifest.json
fi
git -C "$ROOT" tag -a -m "Release v$VER" "v$VER"
echo "review with: git show v$VER — then: git push --follow-tags"
