#!/bin/bash
# Google Antigravity (amd64 only -- Google publishes no arm64 Linux build).
#
# It is a VS Code / Electron fork, so it needs --no-sandbox for exactly the
# same reason Claude Desktop and Chromium do: Electron's sandbox requires
# privileges a container does not have, and it refuses to start as root
# without the flag. The container is the isolation boundary here.
set -euo pipefail

export DISPLAY=:1

APP=/opt/antigravity/antigravity
if [[ ! -x "${APP}" ]]; then
    echo "[antigravity] not installed (expected on arm64 -- x64-only upstream)." >&2
    exit 1
fi

# No GPU in the container; Electron's GPU process otherwise burns cycles
# failing and can take the window down with it.
exec "${APP}" --no-sandbox --disable-gpu "$@"
