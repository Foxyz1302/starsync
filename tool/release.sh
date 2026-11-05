#!/usr/bin/env bash
# Cut a release without typing a version anywhere: derives the next
# version (patch by default), turns CHANGELOG.md's Unreleased into that
# version (refuses when it has no items, warns when it has no Highlights),
# bumps all three pubspecs in lockstep, writes updates/manifest.json
# (predictable asset URL — no CI roundtrip needed; `notes`, `highlights`
# and `changes` from the changelog), commits,
# and tags. Review, then `git push --follow-tags` —
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

# What people read (the update band, What's new, the release page) is
# CHANGELOG.md's Unreleased: no items, no release.
CHANGES="$(dart "$ROOT/tool/changelog.dart" json unreleased)"
COUNT="$(python3 -I -c 'import json,sys; print(sum(map(len, json.loads(sys.argv[1])["changes"].values())))' "$CHANGES")"
if [[ "$COUNT" == "0" ]]; then
  echo "error: CHANGELOG.md's Unreleased has no items — write what changed for people first" >&2
  exit 1
fi
HIGHLIGHTS="$(python3 -I -c 'import json,sys; print(len(json.loads(sys.argv[1])["highlights"]))' "$CHANGES")"
if [[ "$HIGHLIGHTS" == "0" ]]; then
  echo "warning: Unreleased has no ### Highlights; What's new shows its first items instead (write 2-5 short lines)" >&2
fi
if [[ -z "$(sed -n '/^## Unreleased/,/^### /{/^#/d;p}' "$ROOT/CHANGELOG.md" | tr -d '[:space:]')" ]]; then
  echo "warning: Unreleased has no summary line; older apps (which show only notes) get its highlights or first items" >&2
fi
echo "changelog for v$VER:"
dart "$ROOT/tool/changelog.dart" markdown unreleased "$VER" | sed 's/^/  /'

if [[ "$DRY" == "1" ]]; then
  exit 0
fi
dart "$ROOT/tool/changelog.dart" cut "$VER"
CHANGES="$(dart "$ROOT/tool/changelog.dart" json "$VER")"
for f in $PUBSPECS; do
  sed -i -E "s/^version: .*/version: $VER/" "$ROOT/$f"
done

ORIGIN="$(git -C "$ROOT" remote get-url origin)"
SERVER="$(echo "$ORIGIN" | sed -E 's#(https?://[^/]+)/.*#\1#')"
REPO="$(echo "${ORIGIN%.git}" | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#')"
PROTO="$(sed -n 's/.*protoMax = \([0-9]*\).*/\1/p' "$ROOT/packages/core/lib/src/constants.dart")"
export MANIFEST_FILE="$ROOT/updates/manifest.json" MANIFEST_VER="$VER" \
  MANIFEST_PROTO="$PROTO" MANIFEST_CHANGES="$CHANGES" \
  MANIFEST_BASE="$SERVER/$REPO/releases/download/v$VER/starsync-$VER"
python3 -I - <<'EOF'
import json, os
path = os.environ['MANIFEST_FILE']
try:
    with open(path) as f:
        manifest = json.load(f)
except (FileNotFoundError, ValueError):
    manifest = {}
base = os.environ['MANIFEST_BASE']
log = json.loads(os.environ['MANIFEST_CHANGES'])
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
    # One line: 1.2.x and 1.3.x apps show only this.
    'notes': ' '.join(log['notes'].split()) or 'Starsync ' + os.environ['MANIFEST_VER'],
    # {"added": [...], "changed": [...], "fixed": [...]}: What's new.
    'changes': log['changes'],
})
# The few lines What's new shows first (1.4.x and older ignore the key).
if log['highlights']:
    manifest['highlights'] = log['highlights']
else:
    manifest.pop('highlights', None)
manifest.pop('sha256', None)
with open(path, 'w') as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write('\n')
EOF

git -C "$ROOT" add $PUBSPECS updates/manifest.json CHANGELOG.md
if git -C "$ROOT" diff --cached --quiet; then
  echo "everything already at $VER — tagging only"
else
  git -C "$ROOT" commit -m "Release v$VER" -- $PUBSPECS updates/manifest.json CHANGELOG.md
fi
git -C "$ROOT" tag -a -m "Release v$VER" "v$VER"
echo "review with: git show v$VER — then: git push --follow-tags"
