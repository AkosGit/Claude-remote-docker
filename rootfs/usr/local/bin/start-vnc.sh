#!/bin/bash
# KasmVNC: X server + websocket transport + web client, all in one process.
#
# Access is web-only. The raw RFB port is left disabled (Xkasmvnc defaults
# rfbport to 0) because KasmVNC authenticates the web path with a real
# username/password via -KasmPasswordFile, while raw RFB would need the far
# weaker 8-character VNC auth. The reason to keep a native VNC client around
# was its working clipboard, and the web UI now does that itself.
#
# -sslOnly 0 serves plain HTTP. That is safe *only* because compose binds the
# port to 127.0.0.1: browsers treat localhost as a secure context, which is
# what lets navigator.clipboard (and therefore seamless copy/paste) work over
# plain HTTP. Exposing this on a LAN address would both be insecure AND break
# the clipboard, since a non-localhost HTTP origin is not a secure context.
set -euo pipefail

exec /usr/bin/Xkasmvnc :1 \
    -geometry "${VNC_RESOLUTION:-1920x1080}" \
    -depth "${VNC_DEPTH:-24}" \
    -websocketPort "${NOVNC_PORT:-6080}" \
    -interface 0.0.0.0 \
    -sslOnly 0 \
    -httpd /usr/share/kasmvnc/www \
    -KasmPasswordFile "${HOME}/.kasmpasswd" \
    -FrameRate "${VNC_FRAMERATE:-30}" \
    -desktop "claude-vnc-desktop" \
    -SecurityTypes None
