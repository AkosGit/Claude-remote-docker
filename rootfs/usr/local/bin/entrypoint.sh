#!/bin/bash
# Runs as root. Prepares /home/claude (which is a mounted volume, so it is
# empty or stale on first boot), then hands off to supervisord.
set -euo pipefail

HOME_DIR=/home/claude
SEED_MARKER="${HOME_DIR}/.seeded"

# Everything in the desktop session runs as this user: KasmVNC, XFCE, and
# therefore Chromium and Claude Desktop. Root by default; set SESSION_USER=claude
# in .env to run unprivileged instead.
#
# HOME stays /home/claude regardless, because that is the mounted volume --
# so logins, browser profiles and the TLS cert persist either way.
SESSION_USER="${SESSION_USER:-root}"
if ! id -u "${SESSION_USER}" >/dev/null 2>&1; then
    echo "[entrypoint] FATAL: SESSION_USER='${SESSION_USER}' does not exist" >&2
    exit 1
fi
SESSION_UID="$(id -u "${SESSION_USER}")"
SESSION_GID="$(id -g "${SESSION_USER}")"

log() { echo "[entrypoint] $*"; }

# --- Seed the home volume from the build-time skeleton ------------------------
# The volume is mounted over /home/claude and hides anything the image baked
# there, so the skeleton lives in /opt/skel and is copied in once.
if [[ ! -f "${SEED_MARKER}" ]]; then
    log "First boot: seeding ${HOME_DIR} from /opt/skel"
    cp -a /opt/skel/. "${HOME_DIR}/"
    date -u +"seeded %Y-%m-%dT%H:%M:%SZ" > "${SEED_MARKER}"
else
    # Copy in anything new the image added since the volume was created,
    # without clobbering the user's edits.
    cp -an /opt/skel/. "${HOME_DIR}/" 2>/dev/null || true
fi

mkdir -p \
    "${HOME_DIR}/.config/Claude" \
    "${HOME_DIR}/.config/chromium-profile" \
    "${HOME_DIR}/.config/chrome-profile" \
    "${HOME_DIR}/.claude"

# --- Clear stale browser profile locks ---------------------------------------
# Chromium records the hostname and PID of the process holding a profile in
# SingletonLock. Docker gives the container a new hostname on every recreate,
# so a lock left by the previous container never looks stale to Chromium -- it
# reads as "in use by another Chromium on another computer", refuses to start,
# and puts up a modal dialog nobody is there to dismiss.
#
# Nothing can legitimately hold these at entrypoint time: no browser has
# started yet this boot. Safe to remove unconditionally.
for profile in "${HOME_DIR}/.config/chromium-profile" "${HOME_DIR}/.config/chrome-profile"; do
    if [[ -d "${profile}" ]]; then
        rm -f "${profile}/SingletonLock" \
              "${profile}/SingletonCookie" \
              "${profile}/SingletonSocket" 2>/dev/null || true
    fi
done

# --- Web UI credentials -------------------------------------------------------
# KasmVNC authenticates the web path with a real username and password, not the
# 8-character classic VNC password, so there is no length ceiling here.
VNC_USER="${VNC_USER:-claude}"
if [[ -z "${VNC_PASSWORD:-}" ]]; then
    # od reads a fixed number of bytes and exits on its own. A `tr | head`
    # pipeline would leave tr writing into a closed pipe, and under
    # `set -o pipefail` that SIGPIPE takes the whole entrypoint down.
    VNC_PASSWORD="$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n' | cut -c1-16)"
    log "==============================================="
    log "VNC_PASSWORD was not set. Generated one for you:"
    log "    user:     ${VNC_USER}"
    log "    password: ${VNC_PASSWORD}"
    log "Set VNC_PASSWORD in .env to make it stable."
    log "==============================================="
fi

# kasmvncpasswd refuses passwords under 6 characters. That limit is input
# validation in the CLI tool, not a property of the file format: the file is
# plain `user:hash:perms` where hash is standard SHA-256 crypt with the fixed
# salt "kasm". Verified by reproducing a kasmvncpasswd-written hash byte for
# byte with `openssl passwd -5 -salt kasm`.
#
# So short passwords are honoured by writing the entry directly. The supported
# tool is still used whenever it will accept the input, so the normal path stays
# on the vendor's own code and only the awkward case takes the bypass.
write_kasm_password() {
    local user="$1" pw="$2" file="$3"
    if [[ ${#pw} -ge 6 ]]; then
        printf '%s\n%s\n' "${pw}" "${pw}" | kasmvncpasswd -u "${user}" -wo "${file}" >/dev/null
    else
        log "NOTE: password is ${#pw} characters. kasmvncpasswd enforces a 6"
        log "      character minimum, so the entry is being written directly."
        log "      A password this short is weak -- fine for a loopback-bound"
        log "      desktop, not for one reachable over a network."
        local hash
        hash="$(openssl passwd -5 -salt kasm "${pw}")"
        printf '%s:%s:wo\n' "${user}" "${hash}" > "${file}"
    fi
    chmod 600 "${file}"
}

write_kasm_password "${VNC_USER}" "${VNC_PASSWORD}" "${HOME_DIR}/.kasmpasswd"

# --- x11vnc password ----------------------------------------------------------
# Native VNC clients reach the SAME desktop through x11vnc.
#
# It has its own variable because the two servers cannot share one value
# sensibly: classic RFB VncAuth is DES with an 8-byte key, so it has a hard
# 8-character ceiling and no username field at all, while the web UI takes a
# real username and a password of any practical length.
#
# X11VNC_PASSWORD wins if set; otherwise this falls back to VNC_PASSWORD, so
# the simple case still needs only one value.
X11VNC_PW_FULL="${X11VNC_PASSWORD:-${VNC_PASSWORD}}"
X11VNC_PW="${X11VNC_PW_FULL:0:8}"

if [[ -z "${X11VNC_PW}" ]]; then
    log "WARNING: no x11vnc password could be derived; x11vnc will not start."
else
    mkdir -p "${HOME_DIR}/.vnc"
    x11vnc -storepasswd "${X11VNC_PW}" "${HOME_DIR}/.vnc/x11vnc.passwd" >/dev/null 2>&1
    chmod 600 "${HOME_DIR}/.vnc/x11vnc.passwd"
    log "x11vnc: native VNC on port ${X11VNC_PORT:-5901}"
    log "  password: ${X11VNC_PW}"
    if [[ -n "${X11VNC_PASSWORD:-}" ]]; then
        log "  source:   X11VNC_PASSWORD"
    else
        log "  source:   VNC_PASSWORD"
    fi
    log "  the VNC protocol has no username field -- leave it blank"
    # Truncation past 8 characters is silent, so it has to be said out loud.
    if [[ ${#X11VNC_PW_FULL} -gt 8 ]]; then
        log "  NOTE: you set ${#X11VNC_PW_FULL} characters, but VNC uses only the first 8."
        log "        Type exactly '"'"'${X11VNC_PW}'"'"' in your VNC client."
    fi
fi

# KasmVNC's web UI can download files the desktop puts here.
mkdir -p "${HOME_DIR}/Downloads"

# --- TLS ----------------------------------------------------------------------
# One variable per server, because the two have opposite constraints and a
# single switch forced a bad trade:
#
#   KASMVNC_TLS - the web UI. Wants to stay on: navigator.clipboard only exists
#                 in a secure context, so turning TLS off over a network
#                 silently kills copy/paste with no error anywhere.
#   X11VNC_TLS  - the native VNC port. Wants to stay off unless you need it:
#                 macOS Screen Sharing and ordinary VNC clients cannot speak
#                 VNC-over-SSL and simply hang against it. Over an encrypted
#                 overlay (ZeroTier, Tailscale) or an SSH tunnel the stream is
#                 already encrypted, so this costs little.
#
# VNC_TLS is still honoured as the fallback for both, so configs written before
# the split keep working rather than silently changing behaviour.
KASMVNC_TLS="${KASMVNC_TLS:-${VNC_TLS:-1}}"
X11VNC_TLS="${X11VNC_TLS:-${VNC_TLS:-1}}"
export KASMVNC_TLS X11VNC_TLS

# The certificate is shared, so generate it if either server wants TLS.
if [[ "${KASMVNC_TLS}" == "1" || "${X11VNC_TLS}" == "1" ]]; then
    /usr/local/bin/gen-tls-cert.sh "${HOME_DIR}/.vnc-tls"
    if [[ -z "${VNC_TLS_SAN:-}" ]]; then
        log "NOTE: VNC_TLS_SAN is unset, so the certificate only covers"
        log "      localhost. Reaching this by server IP or hostname will make"
        log "      the browser reject it outright rather than just warn. Set"
        log "      VNC_TLS_SAN to that address in .env, then delete"
        log "      the .vnc-tls directory in the home volume to reissue."
    fi
fi

# --- ntfy MCP configuration ---------------------------------------------------
# Write the ntfy settings to a file the MCP server reads directly.
#
# The server is not a child of this container's init. Claude Desktop spawns it,
# and Claude Desktop is started by XFCE autostart, under xfce4-session, under
# dbus-launch, under supervisord. Relying on every link in that chain to pass
# the environment along is fragile -- Electron in particular does not reliably
# do so -- and when it breaks the symptom is baffling: the variables are
# clearly present in any shell you open in the container, but absent in the
# MCP server's process, so it looks like the container was started wrong when
# it was not. This file bypasses the chain entirely.
NTFY_CONF="${HOME_DIR}/.config/ntfy-mcp.env"
mkdir -p "${HOME_DIR}/.config"

if [[ -n "${NTFY_TOPIC:-}" ]]; then
    umask 077
    cat > "${NTFY_CONF}" <<EOF
# Written by entrypoint.sh on container start, from the container environment.
# Edit freely: the MCP server reads this per tool call, so changes take effect
# on the next call with no restart. A container restart overwrites it whenever
# NTFY_TOPIC is set in the environment.
NTFY_TOPIC=${NTFY_TOPIC}
NTFY_SERVER=${NTFY_SERVER:-https://ntfy.sh}
NTFY_TOKEN=${NTFY_TOKEN:-}
EOF
    umask 022
    # The topic string is the only access control on public ntfy.sh, so treat
    # it as a secret rather than as configuration.
    chmod 600 "${NTFY_CONF}"
    log "ntfy: wrote MCP config to ${NTFY_CONF} (topic set)"
else
    log "WARNING: NTFY_TOPIC is unset, so the send_notification MCP tool will"
    log "         fail. Set it in the .env file next to docker-compose.yml and"
    log "         restart. Existing ${NTFY_CONF}, if any, is left untouched."
fi

# --- Ownership ----------------------------------------------------------------
# Chown unconditionally to the session user. Switching SESSION_USER leaves the
# volume owned by the previous one, and a half-owned home is exactly the
# failure this consolidation exists to avoid.
chown -R "${SESSION_UID}:${SESSION_GID}" "${HOME_DIR}"
mkdir -p /workspace && chown "${SESSION_UID}:${SESSION_GID}" /workspace || true

# Shared memory: Chromium and Electron are unhappy with Docker's default 64MB.
if [[ "$(df -k /dev/shm 2>/dev/null | awk 'NR==2 {print $2}')" == "65536" ]]; then
    log "WARNING: /dev/shm is only 64MB. Set shm_size: 2gb in docker-compose.yml"
    log "         or Chromium tabs will crash."
fi

log "Claude Desktop build commit: $(cat /etc/claude-desktop-build-commit 2>/dev/null || echo unknown)"
log "Browser note: $(cat /etc/claude-desktop-arch-notes 2>/dev/null || echo unknown)"
log "Session runs as: ${SESSION_USER} (uid ${SESSION_UID})"
log "TLS: KasmVNC=${KASMVNC_TLS}  x11vnc=${X11VNC_TLS}"
if [[ "${KASMVNC_TLS}" == "1" ]]; then
    log "Web desktop: https://${BIND_ADDR:-localhost}:${NOVNC_PORT:-6080}/ (user: ${VNC_USER})"
    log "  Self-signed certificate: expect a one-time browser warning."
else
    log "Web desktop: http://${BIND_ADDR:-localhost}:${NOVNC_PORT:-6080}/ (user: ${VNC_USER})"
    log "  WARNING: plain HTTP. The clipboard will not work unless you reach"
    log "           this over localhost, because navigator.clipboard needs a"
    log "           secure context."
fi
if [[ "${X11VNC_TLS}" == "1" ]]; then
    log "Native VNC: ${BIND_ADDR:-localhost}:${X11VNC_PORT:-5901} over TLS"
    log "  Needs a VNC-over-SSL client (bVNC Secure, SSVNC)."
    log "  macOS Screen Sharing cannot connect."
else
    log "Native VNC: ${BIND_ADDR:-localhost}:${X11VNC_PORT:-5901} plain RFB"
    log "  Works with any VNC client, including macOS Screen Sharing."
fi

export SESSION_USER

exec "$@"
