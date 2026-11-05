#!/bin/sh
# Update this install in place (same as clicking Update in the app).
# The server binary runs the updater: it needs no GTK/display (VPS).
cd "$(dirname "$0")" || exit 1
exec ./starsync-server --upgrade "$@"
