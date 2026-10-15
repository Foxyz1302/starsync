#!/bin/sh
# Update this install in place (same as clicking Update in the app).
# The server binary runs the updater: it needs no GTK/display (VPS).
# The old server name is the fallback for installs from before the rename.
cd "$(dirname "$0")" || exit 1
if [ -x ./starsync-server ]; then exec ./starsync-server --upgrade "$@"; fi
exec ./watch-together-server --upgrade "$@"
