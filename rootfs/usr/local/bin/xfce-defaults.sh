#!/bin/bash
# Corrects two XFCE defaults that are wrong for a remote desktop, once per home
# volume. Applied at session start rather than shipped as xfconf XML: those
# files are whole-channel dumps, and a partial xfce4-panel.xml risks the panel
# treating it as authoritative and drawing no panels at all.
#
# Guarded by a marker so it runs on a fresh volume and never again. If you
# deliberately change either setting later, a restart will not undo it.
set -uo pipefail

export DISPLAY=:1
MARKER="${HOME}/.config/.xfce-defaults-applied"

[[ -f "${MARKER}" ]] && exit 0

# xfconfd is started by the session; give it a moment to claim the bus.
for _ in $(seq 1 30); do
    if xfconf-query -c xfwm4 -l >/dev/null 2>&1; then break; fi
    sleep 1
done
if ! xfconf-query -c xfwm4 -l >/dev/null 2>&1; then
    echo "[xfce-defaults] xfconfd never became available; leaving defaults alone" >&2
    exit 0
fi

# Desktop magnifier. Bound to Alt+scroll, and zoom_pointer makes the view chase
# the mouse -- trivially easy to trigger by accident in a VNC session, where
# modifier keys pass straight through to the remote desktop, and thoroughly
# confusing when you do not know what happened.
xfconf-query -c xfwm4 -p /general/zoom_desktop -s false 2>/dev/null

# The bottom dock ships with "intelligently hide", which parks its body below
# the screen edge and leaves a 3px trigger strip. On a remote desktop that
# reads as "the bottom of the screen is missing" rather than as a hidden panel.
xfconf-query -c xfce4-panel -p /panels/panel-2/autohide-behavior -s 0 2>/dev/null

# Compositing does shadows and transparency. There is no GPU, so it is done on
# the CPU, and none of it survives VNC's encoding anyway. Measured: idle CPU
# 2.12% -> 0.49% with it off.
xfconf-query -c xfwm4 -p /general/use_compositing -s false 2>/dev/null

# GTK widget animations in Thunar and the XFCE dialogs. Same reasoning as the
# browser motion flags: each animated frame is a screen region VNC must encode.
xfconf-query -c xsettings -p /Gtk/EnableAnimations -n -t bool -s false 2>/dev/null

mkdir -p "$(dirname "${MARKER}")"
date -u +"applied %Y-%m-%dT%H:%M:%SZ" > "${MARKER}"
echo "[xfce-defaults] applied container-appropriate XFCE defaults"
