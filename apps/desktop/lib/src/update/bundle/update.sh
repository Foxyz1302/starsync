#!/bin/sh
# Update this install in place (same as clicking Update in the app).
cd "$(dirname "$0")" && exec ./watch_together --upgrade "$@"
