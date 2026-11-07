#!/usr/bin/env bash
# The owner's step after CI published a release (DEVELOPMENT "Releasing",
# "Signing"): CI has no signing key, so this downloads the release's
# archives (Linux and Windows) from the Gitea release (origin's, or
# RELEASE_REPO_URL: https://gitea.example.org/owner/repo), checks each is the
# bundle of that version, writes updates/manifest.json (asset URLs, their
# sha256 in `assetSha256`, `notes` / `highlights` / `changes` from
# CHANGELOG.md), signs it (manifest.json.sig) and the config when it
# changed, and commits. Then `git push`: apps see the release once the
# signed manifest is on main.
# Key: STARSYNC_SIGNING_KEY or ~/.config/starsync-signing-key.
# Usage: tool/sign_release.sh <version|vX.Y.Z>
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <version>" >&2; exit 64; }
VER="${1#v}"
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must look like 1.5.0, got $1" >&2; exit 64; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
git -C "$ROOT" rev-parse -q --verify "refs/tags/v$VER" >/dev/null ||
  { echo "error: no tag v$VER (cut it with tool/release.sh first)" >&2; exit 1; }
[[ -f "$ROOT/tool/.dart_tool/package_config.json" ]] || (cd "$ROOT/tool" && dart pub get >/dev/null)
dart "$ROOT/tool/sign.dart" --check-key

BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || echo "warning: on $BRANCH, not main: apps read the manifest from main" >&2

ORIGIN="${RELEASE_REPO_URL:-$(git -C "$ROOT" remote get-url origin)}"
SERVER="$(echo "$ORIGIN" | sed -E 's#(https?://[^/]+)/.*#\1#')"
REPO="$(echo "${ORIGIN%.git}" | sed -E 's#.*[:/]([^/]+/[^/]+)$#\1#')"
BASE="$SERVER/$REPO/releases/download/v$VER/starsync-$VER"
# The protocol of the tagged code, not of the working tree.
PROTO="$(git -C "$ROOT" show "v$VER:packages/core/lib/src/constants.dart" | sed -n 's/.*protoMax = \([0-9]*\).*/\1/p')"
CHANGES="$(dart "$ROOT/tool/changelog.dart" json "$VER")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Asset names must match tool/package_linux.sh / package_windows.ps1.
declare -A ASSETS=([linux-x64]="$BASE-linux-x64.tar.gz" [windows-x64]="$BASE-windows-x64.zip")
declare -A SHAS=()
for platform in linux-x64 windows-x64; do
  url="${ASSETS[$platform]}"
  file="$WORK/$(basename "$url")"
  echo "downloading $url ..."
  curl -fSL --retry 3 -o "$file" "$url" ||
    { echo "error: $url not downloadable (has CI published v$VER for $platform?)" >&2; exit 1; }
  # The bundle of this version: a starsync-$VER/ folder with the binary.
  python3 -I - "$file" "$VER" "$platform" <<'EOF'
import sys, tarfile, zipfile
path, ver, platform = sys.argv[1:]
want = f'starsync-{ver}/starsync' + ('.exe' if platform.startswith('windows') else '')
if path.endswith('.zip'):
    names = zipfile.ZipFile(path).namelist()
else:
    names = tarfile.open(path, 'r:gz').getnames()
names = {n.replace('\\', '/').lstrip('./') for n in names}
if want not in names:
    sys.exit(f'error: {path} has no {want}: not the {ver} bundle')
EOF
  SHAS[$platform]="$(sha256sum "$file" | cut -d' ' -f1)"
  echo "  $platform sha256 ${SHAS[$platform]}"
done

export MANIFEST_FILE="$ROOT/updates/manifest.json" MANIFEST_VER="$VER" \
  MANIFEST_PROTO="$PROTO" MANIFEST_CHANGES="$CHANGES" \
  MANIFEST_LINUX="${ASSETS[linux-x64]}" MANIFEST_WINDOWS="${ASSETS[windows-x64]}" \
  MANIFEST_LINUX_SHA="${SHAS[linux-x64]}" MANIFEST_WINDOWS_SHA="${SHAS[windows-x64]}"
python3 -I - <<'EOF'
import json, os
e = os.environ
log = json.loads(e['MANIFEST_CHANGES'])
assets = {'linux-x64': e['MANIFEST_LINUX'], 'windows-x64': e['MANIFEST_WINDOWS']}
manifest = {
    'version': e['MANIFEST_VER'],
    'protocol': int(e['MANIFEST_PROTO']),
    # The Linux tarball, for builds that predate `assets` (<= 0.2.1).
    'url': assets['linux-x64'],
    'assets': assets,
    # Required from 1.5.0 on; apps up to 1.4.x read only a string `sha256`
    # (which would be wrong for Windows), so there is none.
    'assetSha256': {'linux-x64': e['MANIFEST_LINUX_SHA'], 'windows-x64': e['MANIFEST_WINDOWS_SHA']},
    # One line: 1.2.x and 1.3.x apps show only this.
    'notes': ' '.join(log['notes'].split()) or 'Starsync ' + e['MANIFEST_VER'],
    # {"added": [...], "changed": [...], "fixed": [...]}: What's new.
    'changes': log['changes'],
}
# The few lines What's new shows first (1.4.x and older ignore the key).
if log['highlights']:
    manifest['highlights'] = log['highlights']
with open(e['MANIFEST_FILE'], 'w') as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write('\n')
EOF

CONFIG=updates/starsync-config.json
if [[ -n "$(git -C "$ROOT" status --porcelain -- "$CONFIG")" ]] ||
   ! dart "$ROOT/tool/sign.dart" --verify "$ROOT/$CONFIG" >/dev/null; then
  dart "$ROOT/tool/sign_config.dart"
fi
dart "$ROOT/tool/sign.dart" "$ROOT/updates/manifest.json"

git -C "$ROOT" add updates/manifest.json updates/manifest.json.sig "$CONFIG" "$CONFIG.sig"
if git -C "$ROOT" diff --cached --quiet; then
  echo "the signed manifest of v$VER is already committed"
else
  git -C "$ROOT" commit -q -m "Publish v$VER: signed manifest" -- \
    updates/manifest.json updates/manifest.json.sig "$CONFIG" "$CONFIG.sig"
  echo "committed the signed manifest of v$VER"
fi
echo "review with: git show — then: git push (apps see v$VER once it is on main)"
