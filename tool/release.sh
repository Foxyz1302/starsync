#!/usr/bin/env bash
# Cut a release without typing a version anywhere: derives the next
# version (patch by default), bumps all three pubspecs in lockstep,
# commits, and tags. Review, then `git push --follow-tags` — CI takes
# it from there (build, Forgejo release, manifest commit-back).
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
git -C "$ROOT" add $PUBSPECS
if git -C "$ROOT" diff --cached --quiet; then
  echo "pubspecs already at $VER — tagging only"
else
  git -C "$ROOT" commit -m "Release v$VER" -- $PUBSPECS
fi
git -C "$ROOT" tag "v$VER"
echo "review with: git show v$VER — then: git push --follow-tags"
