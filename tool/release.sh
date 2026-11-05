#!/usr/bin/env bash
# Cut a release without typing a version anywhere: derives the next
# version (patch by default), turns CHANGELOG.md's Unreleased into that
# version (refuses when it has no items, warns when it has no Highlights),
# bumps all three pubspecs in lockstep, signs the config when it changed,
# commits and tags. Review, then `git push --follow-tags`: CI builds and
# publishes the archives (it has no signing key). Then
# `tool/sign_release.sh X.Y.Z` writes and signs updates/manifest.json from
# the published archives, and `git push` shows the release to the apps.
# Needs the signing key (DEVELOPMENT "Signing").
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
# Fail before anything changes when there is no signing key.
[[ -f "$ROOT/tool/.dart_tool/package_config.json" ]] || (cd "$ROOT/tool" && dart pub get >/dev/null)
dart "$ROOT/tool/sign.dart" --check-key
dart "$ROOT/tool/changelog.dart" cut "$VER"
for f in $PUBSPECS; do
  sed -i -E "s/^version: .*/version: $VER/" "$ROOT/$f"
done
# The config goes out signed with the release when it changed.
CONFIG=updates/starsync-config.json
if [[ -n "$(git -C "$ROOT" status --porcelain -- "$CONFIG")" ]] ||
   ! dart "$ROOT/tool/sign.dart" --verify "$ROOT/$CONFIG" >/dev/null; then
  dart "$ROOT/tool/sign_config.dart"
fi

git -C "$ROOT" add $PUBSPECS CHANGELOG.md "$CONFIG" "$CONFIG.sig"
if git -C "$ROOT" diff --cached --quiet; then
  echo "everything already at $VER — tagging only"
else
  git -C "$ROOT" commit -m "Release v$VER" -- $PUBSPECS CHANGELOG.md "$CONFIG" "$CONFIG.sig"
fi
git -C "$ROOT" tag -a -m "Release v$VER" "v$VER"
echo "review with: git show v$VER — then: git push --follow-tags"
echo "once CI has published both archives: tool/sign_release.sh $VER, then git push"
