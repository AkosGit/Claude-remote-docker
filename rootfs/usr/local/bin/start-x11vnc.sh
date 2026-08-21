#!/bin/bash
# Exports the EXISTING :1 display over raw RFB, for native VNC clients.
#
# x11vnc is not an X server. It attaches to the display Xkasmvnc already
# created and re-exports it, so this is literally the same desktop as the web
# UI -- same windows, same Claude Desktop instance, same Chromium. That is why
# it does not hit the SingletonLock / single-instance collisions that running a
# second X server (TightVNC, a second Xkasmvnc) would cause.
#
# NOT bound to localhost here on purpose: inside the container it must listen
# on all interfaces for Docker's port publishing to reach it. The loopback
# restriction is applied on the host side by BIND_ADDR in docker-compose.yml.
set -euo pipefail

export DISPLAY=:1

PASSWD_FILE="${HOME}/.vnc/x11vnc.passwd"
if [[ ! -s "${PASSWD_FILE}" ]]; then
    echo "[x11vnc] no password file at ${PASSWD_FILE}; refusing to start" >&2
    echo "[x11vnc] an unauthenticated VNC port is not something to open by accident" >&2
    exit 1
fi

# Wait for the X server; x11vnc exits immediately if the display is absent.
for _ in $(seq 1 90); do
    if xdpyinfo -display :1 >/dev/null 2>&1; then break; fi
    sleep 1
done
if ! xdpyinfo -display :1 >/dev/null 2>&1; then
    echo "[x11vnc] display :1 never appeared" >&2
    exit 1
fi

# Controlled by X11VNC_TLS, sharing the web UI's certificate, so one cert
# covers both servers. x11vnc is built against libssl and wraps the RFB stream
# in TLS with -ssl.
#
# Consequence worth knowing: with -ssl enabled, plain unencrypted VNC clients
# can no longer connect. Clients that speak VNC-over-SSL (bVNC Secure, SSVNC)
# work; macOS Screen Sharing does not, and needs X11VNC_TLS=0 or an SSH tunnel.
TLS_ARGS=()
# X11VNC_TLS overrides VNC_TLS for this server only, defaulting to it when
# unset. The split exists because the two paths have opposite constraints:
# the web UI NEEDS TLS (navigator.clipboard requires a secure context, so
# turning it off silently kills copy/paste), while TLS here costs client
# compatibility -- macOS Screen Sharing and plain VNC clients cannot speak
# VNC-over-SSL at all. Over an encrypted overlay such as ZeroTier or Tailscale,
# the RFB stream is already encrypted in transit, so dropping it here gives up
# little and buys back every VNC client.
if [[ "${X11VNC_TLS:-${VNC_TLS:-1}}" == "1" ]]; then
    PEM="${HOME}/.vnc-tls/kasmvnc.pem"
    if [[ -s "${PEM}" ]]; then
        TLS_ARGS=(-ssl "${PEM}")
        echo "[x11vnc] TLS enabled, using ${PEM}"
    else
        echo "[x11vnc] X11VNC_TLS=1 but ${PEM} is missing; refusing to serve" >&2
        echo "[x11vnc] unencrypted VNC on a bound address by accident" >&2
        exit 1
    fi
else
    echo "[x11vnc] TLS disabled: the RFB stream itself is unencrypted."
    echo "[x11vnc] Fine over an encrypted overlay (ZeroTier/Tailscale) or an SSH"
    echo "[x11vnc] tunnel; NOT fine on a plain LAN or a public network."
fi

exec x11vnc \
    "${TLS_ARGS[@]}" \
    -display :1 \
    -rfbauth "${PASSWD_FILE}" \
    -rfbport "${X11VNC_PORT:-5901}" \
    -shared \
    -forever \
    -noxdamage \
    -repeat \
    -xkb \
    -o /dev/stdout
