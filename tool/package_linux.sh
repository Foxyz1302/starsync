#!/usr/bin/env bash
# Package the Linux release bundle into a versioned tar.gz and optionally
# upload it to Discord.
# Usage: tool/package_linux.sh [--skip-build] [--noupload|--no-upload]
# Output: dist/watch-together-<version>-linux-x64.tar.gz containing one
# top-level folder with the executable, lib/ and data/ as built.
# Upload: set DISCORD_WEBHOOK_URL in the environment (never commit it).
# The tarball must stay under Discord's upload limit (25 MB free tier).
# The upload posts a Components V2 card (flag 1<<15): version header,
# short git commit, stat codeblock, and the tarball as a File component.
# Needs: curl, git, python3 (JSON payload building).
set -euo pipefail

SKIP_BUILD=0
UPLOAD=1
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --noupload|--no-upload) UPLOAD=0 ;;
    *) echo "usage: $0 [--skip-build] [--noupload|--no-upload]" >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/apps/desktop"
NAME="watch-together"
ARCH="x64"

VERSION="$(sed -n 's/^version: \([0-9.]*\).*/\1/p' "$APP/pubspec.yaml")"
if [[ -z "$VERSION" ]]; then echo "error: version not found in $APP/pubspec.yaml" >&2; exit 1; fi

if [[ "$SKIP_BUILD" != "1" ]]; then
  (cd "$APP" && flutter build linux --release --dart-define=APP_VERSION="$VERSION")
fi

BUNDLE="$APP/build/linux/$ARCH/release/bundle"
[[ -d "$BUNDLE" ]] || { echo "error: bundle missing (build first): $BUNDLE" >&2; exit 1; }

STAGE="$APP/build/package-stage"
DIST="$ROOT/dist"
FOLDER="$NAME-$VERSION"
TARBALL="$DIST/$FOLDER-linux-$ARCH.tar.gz"
rm -rf "$STAGE"
mkdir -p "$STAGE/$FOLDER" "$DIST"
cp -r "$BUNDLE/." "$STAGE/$FOLDER/"
tar -czf "$TARBALL" -C "$STAGE" "$FOLDER"
rm -rf "$STAGE"
ls -la "$TARBALL"

if [[ "$UPLOAD" == "1" ]]; then
  if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
    echo "warning: DISCORD_WEBHOOK_URL not set — packaged but not uploaded." >&2
  else
    command -v curl >/dev/null || { echo "error: curl not found" >&2; exit 1; }
    command -v python3 >/dev/null || { echo "error: python3 not found" >&2; exit 1; }
    PAYLOAD="$(mktemp)"
    trap 'rm -f "$PAYLOAD"' EXIT
    export PKG_ROOT="$ROOT" PKG_PAYLOAD="$PAYLOAD" PKG_TARBALL="$TARBALL" \
      PKG_FOLDER="$FOLDER" PKG_VERSION="$VERSION" PKG_ARCH="$ARCH"
    python3 <<'EOF'
import json, os, subprocess

root = os.environ['PKG_ROOT']
out = os.environ['PKG_PAYLOAD']
tarball = os.environ['PKG_TARBALL']
fname = os.path.basename(tarball)
folder = os.environ['PKG_FOLDER']
ver = os.environ['PKG_VERSION']
arch = os.environ['PKG_ARCH']
size_mb = os.path.getsize(tarball) / 1048576

def git(*args):
    try:
        p = subprocess.run(['git', '-C', root, *args],
                           capture_output=True, text=True, timeout=10)
        return p.stdout.strip()
    except Exception:
        return ''

commit = git('log', '-1', '--format=%h %s') or 'uncommitted build'
stat = git('show', '--stat', '--oneline', '--format=', 'HEAD')
stat_lines = [l for l in stat.splitlines() if l.strip()][:14]
rest = len([l for l in stat.splitlines() if l.strip()]) - len(stat_lines)
if rest > 0:
    stat_lines.append(f'... +{rest} more files')
block = '```\n' + '\n'.join(stat_lines) + '\n```'

payload = {
    'flags': 1 << 15,
    'attachments': [{
        'id': 0,
        'filename': fname,
        'description': f'{folder} linux {arch} release build',
    }],
    'components': [{
        'type': 17,
        'accent_color': 5793266,
        'components': [
            {'type': 10, 'content':
             f'# 📦 watch-together `{ver}`\n'
             f'-# linux · {arch} · release · {size_mb:.1f} MB'},
            {'type': 10, 'content': f'`{commit[:140]}`'},
            {'type': 10, 'content': block[:1500]},
            {'type': 14, 'divider': True, 'spacing': 1},
            {'type': 13, 'file': {'url': f'attachment://{fname}'}},
        ],
    }],
}
with open(out, 'w') as f:
    json.dump(payload, f)
EOF
    # Plain (non-application) webhooks ignore `components` unless the
    # with_components query param is set — without it Discord 500s.
    SEP='?'; [[ "$DISCORD_WEBHOOK_URL" == *\?* ]] && SEP='&'
    curl -fsS \
      -F "payload_json=<$PAYLOAD;type=application/json" \
      -F "files[0]=@$TARBALL;type=application/gzip" \
      "${DISCORD_WEBHOOK_URL}${SEP}with_components=true" > /dev/null
    echo "uploaded $FOLDER-linux-$ARCH.tar.gz"
  fi
fi
