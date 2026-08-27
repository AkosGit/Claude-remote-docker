#!/bin/bash
# Claude Desktop, from Anthropic's official Linux package.
#
# --no-sandbox because Electron refuses to start as root with its sandbox
# enabled, and this session runs as root by default. --disable-gpu because
# there is no GPU: without it the GPU process burns cycles failing, and can
# take the window down with it.
#
# App output goes to stdout, so `docker compose logs` shows it.
set -euo pipefail

export DISPLAY=:1

# No GPU in the container, so --disable-gpu is passed directly.

# Session persistence is left to the app's own os_crypt autodetection. It finds
# the gnome-keyring that arrives as a dependency of gcr and offers to create a
# keyring -- a prompt that buys nothing here, since nothing would unlock it on
# the next start, so logins do not survive a restart.
#
# Adding --password-store=basic to the exec below skips the prompt and persists
# the token, at the cost of storing it on disk in the home volume with weak
# protection. Left off deliberately: that is a trade to make, not inherit.

APP=""
for candidate in claude-desktop; do
    if command -v "${candidate}" >/dev/null 2>&1; then APP="${candidate}"; break; fi
done
if [[ -z "${APP}" ]]; then
    echo "[claude-desktop] no claude-desktop launcher found on PATH" >&2
    exit 1
fi

# Wait for the window manager, or the app opens against a bare X server and
# comes up undecorated and unmovable.
for _ in $(seq 1 60); do
    if pgrep -x xfwm4 >/dev/null 2>&1; then break; fi
    sleep 0.5
done

exec "${APP}" --no-sandbox --disable-gpu \
    --disable-smooth-scrolling --force-prefers-reduced-motion "$@"
