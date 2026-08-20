#!/bin/bash
# The visible, Claude-controllable browser.
#
# --remote-debugging-port exposes CDP on localhost only, which is what
# Playwright MCP attaches to (--cdp-endpoint http://127.0.0.1:9222). Because
# this is the same window you see in VNC, you watch Claude drive it live.
#
# --no-sandbox: Chromium's own sandbox needs privileges a default container
# does not have. The container is the isolation boundary here, not the browser.
set -euo pipefail

export DISPLAY=:1

BROWSER=""
for candidate in /usr/bin/chromium /usr/bin/chromium-browser; do
    if [[ -x "${candidate}" ]]; then BROWSER="${candidate}"; break; fi
done
if [[ -z "${BROWSER}" ]]; then
    echo "[chromium] No chromium binary found" >&2
    exit 1
fi

exec "${BROWSER}" \
    --no-sandbox \
    --disable-dev-shm-usage \
    --disable-gpu \
    --no-first-run \
    --no-default-browser-check \
    --hide-crash-restore-bubble \
    --password-store=basic \
    --remote-debugging-port="${CDP_PORT:-9222}" \
    --remote-debugging-address=127.0.0.1 \
    --user-data-dir="${HOME}/.config/chromium-profile" \
    --window-size="${VNC_RESOLUTION/x/,}" \
    "${CHROMIUM_START_URL:-https://claude.ai}"
