#!/usr/bin/env bash
# Publish a release to Forgejo: create the release, upload the Linux
# tarball built by tool/package_linux.sh, and commit the updated
# updates/manifest.json back to main so --upgrade clients see the new
# version at the stable raw URL.
# Usage: tool/release_publish.sh vX.Y.Z   (run after package_linux.sh)
# Env: RELEASE_TOKEN (preferred) or the Actions-provided GITHUB_TOKEN /
# GITEA_TOKEN (needs repo write or the final push is denied — then set a
# RELEASE_TOKEN secret with write access).
set -euo pipefail

TAG="${1:?usage: tool/release_publish.sh vX.Y.Z}"
VER="${TAG#v}"
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: tag must look like v0.2.0, got $TAG" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARBALL="$ROOT/dist/watch-together-$VER-linux-x64.tar.gz"
[[ -f "$TARBALL" ]] || { echo "error: run tool/package_linux.sh first ($TARBALL missing)" >&2; exit 1; }

PUB="$(sed -n 's/^version: \([0-9.]*\).*/\1/p' "$ROOT/apps/desktop/pubspec.yaml")"
[[ "$PUB" == "$VER" ]] || { echo "error: tag $TAG != desktop pubspec $PUB (bump it in a release commit first)" >&2; exit 1; }

ORIGIN="$(git -C "$ROOT" remote get-url origin)"
SERVER="$(echo "$ORIGIN" | sed -E 's#(https?://[^/]+)/.*#\1#')"
REPO="$(echo "$ORIGIN" | sed -E 's#.*[:/]([^/]+/[^/]+?)(\.git)?$#\1#')"
TOKEN="${RELEASE_TOKEN:-${GITHUB_TOKEN:-${GITEA_TOKEN:-}}}"
[[ -n "$TOKEN" ]] || { echo "error: set RELEASE_TOKEN (or run in Actions with a write token)" >&2; exit 1; }

PROTO="$(sed -n 's/.*protoVersion = \([0-9]*\).*/\1/p' "$ROOT/packages/core/lib/src/constants.dart")"
SHA="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
ASSET="$(basename "$TARBALL")"
PREV="$(git -C "$ROOT" describe --tags --abbrev=0 HEAD 2>/dev/null || true)"
if [[ -n "$PREV" && "$PREV" != "$TAG" ]]; then
  NOTES="$(git -C "$ROOT" log "$PREV..HEAD" --format='- %s' | head -n 20)"
else
  NOTES="Watch together $VER."
fi
export REL_TAG="$TAG" REL_VER="$VER" REL_NOTES="$NOTES"

echo "creating release $TAG on $REPO ..."
REL_ID="$(curl -fsS -H "Authorization: token $TOKEN" -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import json,os; print(json.dumps({"tag_name": os.environ["REL_TAG"], "name": os.environ["REL_TAG"], "body": "Watch together " + os.environ["REL_VER"] + "\n\n" + os.environ["REL_NOTES"], "draft": False, "prerelease": False}))')" \
  "$SERVER/api/v1/repos/$REPO/releases" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
echo "release id: $REL_ID"

echo "uploading $ASSET ..."
curl -fsS -H "Authorization: token $TOKEN" -H 'Content-Type: application/gzip' \
  --data-binary "@$TARBALL" \
  "$SERVER/api/v1/repos/$REPO/releases/$REL_ID/assets?name=$ASSET" > /dev/null

export MANIFEST_FILE="$ROOT/updates/manifest.json" MANIFEST_VER="$VER" \
  MANIFEST_PROTO="$PROTO" MANIFEST_SHA="$SHA" \
  MANIFEST_URL="$SERVER/$REPO/releases/download/$TAG/$ASSET"
python3 - <<'EOF'
import json, os
path = os.environ['MANIFEST_FILE']
try:
    with open(path) as f:
        manifest = json.load(f)
except (FileNotFoundError, ValueError):
    manifest = {}
manifest.update({
    'version': os.environ['MANIFEST_VER'],
    'protocol': int(os.environ['MANIFEST_PROTO']),
    'url': os.environ['MANIFEST_URL'],
    'sha256': os.environ['MANIFEST_SHA'],
    'notes': os.environ['REL_NOTES'].splitlines()[0] if os.environ['REL_NOTES'] else '',
})
with open(path, 'w') as f:
    json.dump(manifest, f, indent=2)
    f.write('\n')
EOF

echo "committing manifest back to main ..."
git -C "$ROOT" fetch origin main 2>/dev/null || true
git -C "$ROOT" checkout -B main origin/main
git -C "$ROOT" add updates/manifest.json
git -C "$ROOT" -c user.name='watch-together-release' -c user.email='release@localhost' \
  commit -m "Release $TAG manifest" -- updates/manifest.json
if ! git -C "$ROOT" push -o ci.skip origin main 2>/dev/null; then
  git -C "$ROOT" push origin main
fi
echo "published $TAG — manifest live at updates/manifest.json on main."
