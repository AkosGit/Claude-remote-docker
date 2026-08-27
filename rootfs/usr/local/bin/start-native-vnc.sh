#!/bin/bash
# Native RFB access to the SAME display KasmVNC serves, via TigerVNC's
# x0vncserver.
#
# This replaced x11vnc, which is unusable on some hosts: Debian ships 0.9.16
# (2019) linked against libvncserver 0.9.14, and on Ubuntu 25.04 that pairing
# accepts TCP connections into the kernel backlog and then never calls
# accept() -- connections sit in CLOSE_WAIT with inode 0 while the process
# idles in do_select. Reproduced with a minimal `x11vnc -display :1 -rfbport
# 5905 -nopw`, so it is neither the flags nor AppArmor.
#
# x0vncserver does the same job -- scrape an existing X display and serve it
# over RFB -- from TigerVNC 1.12, which is maintained. It also tracks RandR
# properly, so KasmVNC's dynamic resizing no longer needs suppressing: x11vnc
# wedged in check_xrandr_event and spun at ~50% CPU, which is why it had to be
# run with -noxrandr and could not follow resizes.
#
# KasmVNC cannot serve this itself. It accepts -rfbport and opens no listener
# for it -- verified against /proc/net/tcp, which shows only the websocket
# port. It is websocket-only and the parameter is vestigial.
#
# Not restricted to localhost: inside the container it must listen on all
# interfaces for Docker's port publishing to reach it. BIND_ADDR applies the
# host-side restriction.
set -euo pipefail

export DISPLAY=:1

PASSWD_FILE="${HOME}/.vnc/native-vnc.passwd"
if [[ ! -s "${PASSWD_FILE}" ]]; then
    echo "[native-vnc] no password file at ${PASSWD_FILE}; refusing to start" >&2
    echo "[native-vnc] an unauthenticated VNC port is not something to open by accident" >&2
    exit 1
fi

# Wait for the X server; x0vncserver exits immediately if the display is absent.
for _ in $(seq 1 90); do
    if xdpyinfo -display :1 >/dev/null 2>&1; then break; fi
    sleep 1
done
if ! xdpyinfo -display :1 >/dev/null 2>&1; then
    echo "[native-vnc] display :1 never appeared" >&2
    exit 1
fi

args=(
    -display :1
    -rfbport "${X11VNC_PORT:-5901}"
    -localhost no
    -PasswordFile "${PASSWD_FILE}"
)

# X11VNC_TLS keeps its name so existing .env files continue to work.
if [[ "${X11VNC_TLS:-${VNC_TLS:-1}}" == "1" ]]; then
    CERT_DIR="${HOME}/.vnc-tls"
    if [[ ! -s "${CERT_DIR}/kasmvnc.crt" || ! -s "${CERT_DIR}/kasmvnc.key" ]]; then
        echo "[native-vnc] X11VNC_TLS=1 but no certificate in ${CERT_DIR}" >&2
        echo "[native-vnc] refusing to serve unencrypted RFB by accident" >&2
        exit 1
    fi
    args+=(-SecurityTypes X509Vnc
           -X509Cert "${CERT_DIR}/kasmvnc.crt"
           -X509Key  "${CERT_DIR}/kasmvnc.key")
    echo "[native-vnc] TLS enabled (X509Vnc). Needs a VNC-over-TLS client;"
    echo "[native-vnc] macOS Screen Sharing cannot connect -- set X11VNC_TLS=0."
else
    args+=(-SecurityTypes VncAuth)
    echo "[native-vnc] TLS disabled: the RFB stream is unencrypted."
    echo "[native-vnc] Fine over an encrypted overlay (ZeroTier/Tailscale) or an"
    echo "[native-vnc] SSH tunnel; NOT fine on a plain LAN or the internet."
fi

exec x0vncserver "${args[@]}"
