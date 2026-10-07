#!/usr/bin/env bash
# Publish a release to Gitea: create the release and upload the Linux
# tarball built by tool/package_linux.sh. The manifest is written by
# tool/release.sh at release time (predictable asset URL), so this
# script never touches git — no push-back, no write-token problem
# beyond the release API itself.
# Usage: tool/release_publish.sh vX.Y.Z   (run after package_linux.sh)
# Env: RELEASE_TOKEN (preferred) or the Actions-provided GITHUB_TOKEN /
# GITEA_TOKEN.
set -euo pipefail

TAG="${1:?usage: tool/release_publish.sh vX.Y.Z}"
VER="${TAG#v}"
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: tag must look like v0.2.0, got $TAG" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARBALL="$ROOT/dist/watch-together-$VER-linux-x64.tar.gz"
[[ -f "$TARBALL" ]] || { echo "error: run tool/package_linux.sh first ($TARBALL missing)" >&2; exit 1; }

PUB="$(sed -n 's/^version: \([0-9.]*\).*/\1/p' "$ROOT/apps/desktop/pubspec.yaml")"
[[ "$PUB" == "$VER" ]] || { echo "error: tag $TAG != desktop pubspec $PUB (run tool/release.sh first)" >&2; exit 1; }

ORIGIN="$(git -C "$ROOT" remote get-url origin)"
SERVER="$(echo "$ORIGIN" | sed -E 's#(https?://[^/]+)/.*#\1#')"
REPO="$(echo "${ORIGIN%.git}" | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#')"
TOKEN="${RELEASE_TOKEN:-${GITHUB_TOKEN:-${GITEA_TOKEN:-}}}"
[[ -n "$TOKEN" ]] || { echo "error: set RELEASE_TOKEN (or run in Actions)" >&2; exit 1; }

ASSET="$(basename "$TARBALL")"
PREV="$(git -C "$ROOT" describe --tags --abbrev=0 HEAD 2>/dev/null || true)"
if [[ -n "$PREV" && "$PREV" != "$TAG" ]]; then
  NOTES="$(git -C "$ROOT" log "$PREV..HEAD" --format='- %s' | head -n 20)"
else
  NOTES="Watch together $VER."
fi
export REL_TAG="$TAG" REL_VER="$VER" REL_NOTES="$NOTES"

API="$SERVER/api/v1/repos/$REPO"
# Re-runs reuse the release for this tag instead of failing on a duplicate.
REL_ID="$(curl -fsS -H "Authorization: token $TOKEN" "$API/releases/tags/$TAG" 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' 2>/dev/null || true)"
if [[ -z "$REL_ID" ]]; then
  echo "creating release $TAG on $REPO ..."
  REL_ID="$(curl -fsS -H "Authorization: token $TOKEN" -H 'Content-Type: application/json' \
    -d "$(python3 -c 'import json,os; print(json.dumps({"tag_name": os.environ["REL_TAG"], "name": os.environ["REL_TAG"], "body": "Watch together " + os.environ["REL_VER"] + "\n\n" + os.environ["REL_NOTES"], "draft": False, "prerelease": False}))')" \
    "$API/releases" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
fi
echo "release id: $REL_ID"

echo "uploading $ASSET ..."
# Gitea's asset API takes a multipart form with an `attachment` field.
curl -fsS -H "Authorization: token $TOKEN" \
  -F "attachment=@$TARBALL;type=application/gzip" \
  "$API/releases/$REL_ID/assets?name=$ASSET" > /dev/null
echo "published $TAG."
