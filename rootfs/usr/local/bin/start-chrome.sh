#!/bin/bash
# Google Chrome (amd64 only -- there is no official Linux build for arm64,
# where Chromium fills this role instead).
#
# This is the browser you install the Claude in Chrome extension into. It is
# deliberately NOT the CDP target: that is Chromium, driven by Playwright MCP.
# Keeping them apart means an agent driving the browser cannot disturb the
# session your extension is logged into.
#
# --no-sandbox for the same reason as everywhere else here: Chrome's sandbox
# needs privileges a container does not have, and it flatly refuses to start
# as root without this.
set -euo pipefail

export DISPLAY=:1

if ! command -v google-chrome-stable >/dev/null 2>&1; then
    echo "[chrome] google-chrome-stable is not installed (expected on arm64)." >&2
    echo "[chrome] Use Chromium instead." >&2
    exit 1
fi

if [[ $# -eq 0 ]]; then
    set -- "${CHROME_START_URL:-https://claude.ai}"
fi

exec google-chrome-stable \
    --no-sandbox \
    --disable-dev-shm-usage \
    --disable-gpu \
    --no-first-run \
    --no-default-browser-check \
    --password-store=basic \
    --user-data-dir="${HOME}/.config/chrome-profile" \
    "$@"
