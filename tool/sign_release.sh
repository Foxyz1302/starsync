#!/usr/bin/env bash
# The owner's step after CI published a release on GitHub (DEVELOPMENT
# "Releasing", "Signing"): CI has no signing key, so this downloads the
# release's archives (Linux and Windows) from the GitHub release
# (STARSYNC_GITHUB_REPO, default Foxyz1302/starsync), checks each is the
# bundle of that version, writes updates/manifest.json (asset URLs, their
# sha256 in `assetSha256`, `notes` / `highlights` / `changes` from
# CHANGELOG.md), signs it (manifest.json.sig) and the config when it
# changed, and commits on main.
# The 1.4 bridge (on unless --no-bridge): apps up to 1.4.x read only the
# Gitea's copy of updates/manifest.json (its old history's main) and check
# no signature, so the same manifest and .sig go on top of the Gitea's main
# as one commit, on the local branch `gitea-bridge`. The Gitea is
# RELEASE_REPO_URL, else origin's https address (none is written in the
# tree); the push token RELEASE_TOKEN, else
# ~/.config/watch-together-release-token (https with a token header: ssh
# to it is blocked).
# Then push both (printed, or done with --push): main to GitHub (remote
# STARSYNC_GITHUB_REMOTE, default `github`), gitea-bridge to the Gitea's main.
# --dry-run: everything in a temporary folder (the manifest, its signature
# checked, the bridge commit built but on no branch), nothing committed,
# nothing pushed.
# Key: STARSYNC_SIGNING_KEY or ~/.config/starsync-signing-key.
# Usage: tool/sign_release.sh <version|vX.Y.Z> [--push] [--no-bridge] [--dry-run]
set -euo pipefail

usage() { echo "usage: $0 <version> [--push] [--no-bridge] [--dry-run]" >&2; exit 64; }
VER=""
PUSH=0
BRIDGE=1
DRY=0
for arg in "$@"; do
  case "$arg" in
    --push) PUSH=1 ;;
    --no-bridge) BRIDGE=0 ;;
    --dry-run) DRY=1 ;;
    -*) usage ;;
    *) [[ -z "$VER" ]] || usage; VER="${arg#v}" ;;
  esac
done
[[ -n "$VER" ]] || usage
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must look like 1.5.0, got $VER" >&2; exit 64; }
[[ "$DRY$PUSH" != "11" ]] || { echo "error: --dry-run pushes nothing; drop --push" >&2; exit 64; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
git -C "$ROOT" rev-parse -q --verify "refs/tags/v$VER" >/dev/null ||
  { echo "error: no tag v$VER (cut it with tool/release.sh first)" >&2; exit 1; }
[[ -f "$ROOT/tool/.dart_tool/package_config.json" ]] || (cd "$ROOT/tool" && dart pub get >/dev/null)
dart "$ROOT/tool/sign.dart" --check-key

GH_REPO="${STARSYNC_GITHUB_REPO:-Foxyz1302/starsync}"
GH_REMOTE="${STARSYNC_GITHUB_REMOTE:-github}"
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
if [[ "$DRY" == "0" && "$BRANCH" != "main" ]]; then
  # Apps read the manifest from main, and --push pushes main.
  [[ "$PUSH" == "0" ]] || { echo "error: on $BRANCH, not main" >&2; exit 1; }
  echo "warning: on $BRANCH, not main: apps read the manifest from main" >&2
fi
if [[ "$DRY" == "0" ]] && ! git -C "$ROOT" remote get-url "$GH_REMOTE" 2>/dev/null | grep -q "github.com[:/]$GH_REPO"; then
  echo "warning: remote $GH_REMOTE is not github.com/$GH_REPO (STARSYNC_GITHUB_REMOTE names it)" >&2
fi

# The Gitea for the bridge: its https address (never written in the tree)
# and the token its push needs.
GITEA="" TOKEN="" TOKEN_SHOWN=""
if [[ "$BRIDGE" == "1" ]]; then
  GITEA="${RELEASE_REPO_URL:-$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)}"
  GITEA="${GITEA%.git}.git"
  [[ "$GITEA" =~ ^https:// ]] ||
    { echo "error: the 1.4 bridge needs the Gitea's https address: set RELEASE_REPO_URL (or --no-bridge)" >&2; exit 1; }
  TOKEN_FILE="$HOME/.config/watch-together-release-token"
  if [[ -n "${RELEASE_TOKEN:-}" ]]; then
    TOKEN="$RELEASE_TOKEN"; TOKEN_SHOWN='$RELEASE_TOKEN'
  elif [[ -r "$TOKEN_FILE" ]]; then
    TOKEN="$(tr -d '[:space:]' <"$TOKEN_FILE")"; TOKEN_SHOWN="\$(cat ~/.config/watch-together-release-token)"
  else
    TOKEN=""; TOKEN_SHOWN='$RELEASE_TOKEN'
    [[ "$PUSH" == "0" ]] || { echo "error: no Gitea token: set RELEASE_TOKEN or write $TOKEN_FILE" >&2; exit 1; }
  fi
fi
# git on the Gitea, the token as a header from the environment (never on
# the command line, never printed).
gitea_git() {
  if [[ -n "$TOKEN" ]]; then
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader \
      GIT_CONFIG_VALUE_0="Authorization: token $TOKEN" git -C "$ROOT" "$@"
  else
    git -C "$ROOT" "$@"
  fi
}

BASE="https://github.com/$GH_REPO/releases/download/v$VER/starsync-$VER"
# The protocol of the tagged code, not of the working tree.
PROTO="$(git -C "$ROOT" show "v$VER:packages/core/lib/src/constants.dart" | sed -n 's/.*protoMax = \([0-9]*\).*/\1/p')"
CHANGES="$(dart "$ROOT/tool/changelog.dart" json "$VER")"

WORK="$(mktemp -d)"
BRIDGE_TREE="$WORK/gitea-main"
cleanup() {
  if [[ -d "$BRIDGE_TREE" ]]; then git -C "$ROOT" worktree remove --force "$BRIDGE_TREE" 2>/dev/null || true; fi
  rm -rf "$WORK"
  git -C "$ROOT" worktree prune 2>/dev/null || true
}
trap cleanup EXIT
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

# A dry run writes and signs the manifest in the temporary folder.
if [[ "$DRY" == "1" ]]; then
  mkdir "$WORK/out"
  MANIFEST="$WORK/out/manifest.json"
else
  MANIFEST="$ROOT/updates/manifest.json"
fi
export MANIFEST_FILE="$MANIFEST" MANIFEST_VER="$VER" \
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
CONFIG_STALE=0
if [[ -n "$(git -C "$ROOT" status --porcelain -- "$CONFIG")" ]] ||
   ! dart "$ROOT/tool/sign.dart" --verify "$ROOT/$CONFIG" >/dev/null; then
  CONFIG_STALE=1
fi
if [[ "$DRY" == "1" ]]; then
  [[ "$CONFIG_STALE" == "0" ]] || echo "dry run: the config would be signed again (dart tool/sign_config.dart)"
else
  [[ "$CONFIG_STALE" == "0" ]] || dart "$ROOT/tool/sign_config.dart"
fi
dart "$ROOT/tool/sign.dart" "$MANIFEST"
dart "$ROOT/tool/sign.dart" --verify "$MANIFEST"

if [[ "$DRY" == "1" ]]; then
  echo "dry run: the manifest against the committed one:"
  git -C "$ROOT" diff --no-index --stat -- "$ROOT/updates/manifest.json" "$MANIFEST" && echo "  identical"
  git -C "$ROOT" diff --no-index -- "$ROOT/updates/manifest.json" "$MANIFEST" || true
  if cmp -s "$ROOT/updates/manifest.json.sig" "$MANIFEST.sig"; then
    echo "dry run: manifest.json.sig identical to the committed one"
  else
    echo "dry run: manifest.json.sig differs from the committed one (a new manifest)"
  fi
else
  git -C "$ROOT" add updates/manifest.json updates/manifest.json.sig "$CONFIG" "$CONFIG.sig"
  if git -C "$ROOT" diff --cached --quiet; then
    echo "the signed manifest of v$VER is already committed"
  else
    git -C "$ROOT" commit -q -m "Publish v$VER: signed manifest" -- \
      updates/manifest.json updates/manifest.json.sig "$CONFIG" "$CONFIG.sig"
    echo "committed the signed manifest of v$VER"
  fi
fi

# The 1.4 bridge: the same two files, byte for byte, as one commit on top
# of the Gitea's main (old history), built in a temporary worktree.
# `[skip ci]`: the old history's Gitea CI has nothing to check here.
BRIDGE_PUSH=""
if [[ "$BRIDGE" == "1" ]]; then
  echo "fetching the Gitea's main for the 1.4 bridge ..."
  gitea_git fetch -q "$GITEA" refs/heads/main
  GITEA_MAIN="$(git -C "$ROOT" rev-parse FETCH_HEAD)"
  git -C "$ROOT" worktree add -q --detach "$BRIDGE_TREE" "$GITEA_MAIN"
  mkdir -p "$BRIDGE_TREE/updates"
  cp "$MANIFEST" "$BRIDGE_TREE/updates/manifest.json"
  cp "$MANIFEST.sig" "$BRIDGE_TREE/updates/manifest.json.sig"
  git -C "$BRIDGE_TREE" add -- updates/manifest.json updates/manifest.json.sig
  if git -C "$BRIDGE_TREE" diff --cached --quiet; then
    echo "1.4 bridge: the Gitea's main already has this manifest ($(git -C "$ROOT" rev-parse --short "$GITEA_MAIN"))"
  else
    git -C "$BRIDGE_TREE" commit -q --no-verify \
      -m "Publish v$VER for apps up to 1.4.x: the signed manifest, downloads on GitHub [skip ci]" \
      -- updates/manifest.json updates/manifest.json.sig
    BRIDGE_COMMIT="$(git -C "$BRIDGE_TREE" rev-parse HEAD)"
    # Exactly the bytes signed, and nothing else in the commit.
    for f in manifest.json manifest.json.sig; do
      [[ "$(git -C "$ROOT" rev-parse "$BRIDGE_COMMIT:updates/$f")" == \
         "$(git -C "$ROOT" hash-object --no-filters "$(dirname "$MANIFEST")/$f")" ]] ||
        { echo "error: the bridge's updates/$f is not the signed file" >&2; exit 1; }
    done
    echo "1.4 bridge: commit $(git -C "$ROOT" rev-parse --short "$BRIDGE_COMMIT") on the Gitea's main $(git -C "$ROOT" rev-parse --short "$GITEA_MAIN"):"
    git -C "$ROOT" show --stat --format='  %s' "$BRIDGE_COMMIT" | sed '1!s/^/  /'
    if [[ "$DRY" == "1" ]]; then
      echo "dry run: the bridge commit is on no branch (git show $BRIDGE_COMMIT)"
    else
      git -C "$ROOT" branch -f gitea-bridge "$BRIDGE_COMMIT"
      BRIDGE_PUSH=1
    fi
  fi
fi

GH_CMD="git push $GH_REMOTE main"
GITEA_CMD="git -c http.extraHeader=\"Authorization: token $TOKEN_SHOWN\" push $GITEA gitea-bridge:main"
if [[ "$DRY" == "1" ]]; then
  echo "dry run: nothing committed or pushed. A real run would then push:"
  echo "  $GH_CMD"
  [[ "$BRIDGE" == "0" ]] || echo "  $GITEA_CMD"
elif [[ "$PUSH" == "1" ]]; then
  echo "pushing main to $GH_REMOTE ..."
  git -C "$ROOT" push "$GH_REMOTE" main
  if [[ -n "$BRIDGE_PUSH" ]]; then
    echo "pushing the 1.4 bridge to the Gitea's main ..."
    gitea_git push "$GITEA" gitea-bridge:refs/heads/main
  fi
  echo "v$VER is out: apps see it at their next check"
else
  echo "review with: git show (and git show gitea-bridge), then push:"
  echo "  $GH_CMD"
  [[ -z "$BRIDGE_PUSH" ]] || echo "  $GITEA_CMD"
  echo "(or run again with --push)"
fi
