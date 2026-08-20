#!/bin/bash
# KasmVNC: X server + websocket transport + web client, all in one process.
#
# Access is web-only. The raw RFB port stays disabled (Xkasmvnc defaults
# rfbport to 0) because KasmVNC authenticates the web path with a real
# username/password via -KasmPasswordFile, while raw RFB would need the far
# weaker 8-character VNC auth.
#
# TLS (VNC_TLS=1, the default) is not decoration. Browsers expose
# navigator.clipboard only in a secure context: HTTPS anywhere, or plain HTTP
# on localhost and nowhere else. Serving plain HTTP to a remote machine
# therefore breaks copy/paste silently, with no error anywhere -- so any
# deployment you reach over a network needs this on.
#
# VNC_TLS=0 falls back to plain HTTP. Only sane when you reach the port
# exclusively via localhost, either on the same machine or through an SSH
# tunnel that terminates at 127.0.0.1 on your end.
set -euo pipefail

args=(
    :1
    -geometry "${VNC_RESOLUTION:-1920x1080}"
    -depth "${VNC_DEPTH:-24}"
    -websocketPort "${NOVNC_PORT:-6080}"
    -interface 0.0.0.0
    -httpd /usr/share/kasmvnc/www
    -KasmPasswordFile "${HOME}/.kasmpasswd"
    -FrameRate "${VNC_FRAMERATE:-30}"
    -desktop "claude-vnc-desktop"
    -SecurityTypes None
)

if [[ "${VNC_TLS:-1}" == "1" ]]; then
    CERT_DIR="${HOME}/.vnc-tls"
    if [[ ! -s "${CERT_DIR}/kasmvnc.crt" || ! -s "${CERT_DIR}/kasmvnc.key" ]]; then
        echo "[vnc] TLS requested but no certificate found in ${CERT_DIR}" >&2
        exit 1
    fi
    args+=(-sslOnly 1 -cert "${CERT_DIR}/kasmvnc.crt" -key "${CERT_DIR}/kasmvnc.key")
    echo "[vnc] serving HTTPS on :${NOVNC_PORT:-6080}"
else
    args+=(-sslOnly 0)
    echo "[vnc] serving plain HTTP on :${NOVNC_PORT:-6080}"
    echo "[vnc] WARNING: clipboard will only work if you reach this via localhost."
fi

exec /usr/bin/Xkasmvnc "${args[@]}"
