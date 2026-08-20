#!/bin/bash
# Claude Desktop (unofficial Linux repack).
#
# The .deb installs its launcher as `claude-desktop-unofficial`, not
# `claude-desktop`, so resolve both names.
#
# That launcher builds its own Electron argument list. On X11 + deb it does
# NOT add --no-sandbox (it only does so for AppImage and Wayland), so we pass
# it ourselves: Electron's sandbox needs privileges a default container lacks.
# Extra arguments are appended after the launcher's own, which is what we want.
#
# The launcher redirects app output to ~/.cache/claude-desktop-debian/launcher.log
# rather than stdout, so `docker compose logs` will not show app errors --
# read that file instead. `claude-desktop-unofficial --doctor` is also useful.
set -euo pipefail

export DISPLAY=:1

# Headless container: there is no GPU, and Chromium's GPU process can hit a
# FATAL exhaustion loop trying to use one. The launcher honours this env var.
export CLAUDE_DISABLE_GPU="${CLAUDE_DISABLE_GPU:-1}"

# CLAUDE_PASSWORD_STORE is deliberately NOT defaulted here. Without it, the
# app's own os_crypt autodetection decides how to persist your session, and it
# will refuse weak on-disk storage rather than write tokens unsafely -- which
# in a container with no keyring means logging in again after each restart.
# Setting CLAUDE_PASSWORD_STORE=basic in .env trades that away for
# convenience: the token lands on disk in the home volume with weak
# protection. Opt in only if you accept that.

APP=""
for candidate in claude-desktop-unofficial claude-desktop; do
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

exec "${APP}" --no-sandbox "$@"
