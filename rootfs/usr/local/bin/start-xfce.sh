#!/bin/bash
# Starts the XFCE session under its own D-Bus session bus.
#
# Chromium and Claude Desktop are launched by XFCE's autostart rather than by
# supervisord, so that they inherit this D-Bus session. Electron needs it for
# the system tray, and Chromium needs it for notifications and keyring access.
# Trade-off: supervisorctl cannot restart them individually. Use
# `restart-browser` for Chromium, or relaunch from the XFCE app menu.
set -euo pipefail

export DISPLAY=:1

# Wait for the X server.
for _ in $(seq 1 60); do
    if xdpyinfo -display :1 >/dev/null 2>&1; then break; fi
    sleep 0.5
done

xsetroot -solid "#1f2430" || true

exec dbus-launch --exit-with-session xfce4-session
