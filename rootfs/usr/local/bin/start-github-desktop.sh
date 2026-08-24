#!/bin/bash
# GitHub Desktop (community Linux build from shiftkey/desktop -- GitHub ships
# no official Linux release).
#
# Electron, so it needs --no-sandbox when the session runs as root, for the
# same reason Claude Desktop and Chromium do. ELECTRON_DISABLE_SANDBOX is
# already exported image-wide for uid 0, but the flag is passed explicitly here
# too: this wrapper is what the menu entry points at, and being independent of
# environment inheritance is the whole point of a wrapper.
set -euo pipefail

export DISPLAY=:1

APP=""
for candidate in github-desktop githubdesktop; do
    if command -v "${candidate}" >/dev/null 2>&1; then APP="${candidate}"; break; fi
done
if [[ -z "${APP}" ]]; then
    echo "[github-desktop] not installed" >&2
    exit 1
fi

# No GPU in the container.
exec "${APP}" --no-sandbox --disable-gpu "$@"
