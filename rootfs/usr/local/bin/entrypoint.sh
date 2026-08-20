#!/bin/bash
# Runs as root. Prepares /home/claude (which is a mounted volume, so it is
# empty or stale on first boot), then hands off to supervisord.
set -euo pipefail

HOME_DIR=/home/claude
SEED_MARKER="${HOME_DIR}/.seeded"

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

# kasmvncpasswd reads the password twice, as if typed at a prompt.
# -w grants write (input) permission, -o marks the account owner.
printf '%s\n%s\n' "${VNC_PASSWORD}" "${VNC_PASSWORD}" \
    | kasmvncpasswd -u "${VNC_USER}" -wo "${HOME_DIR}/.kasmpasswd" >/dev/null
chmod 600 "${HOME_DIR}/.kasmpasswd"

# KasmVNC's web UI can download files the desktop puts here.
mkdir -p "${HOME_DIR}/Downloads"

# --- TLS certificate ----------------------------------------------------------
# Lives in the home volume so the browser only has to be told to trust it once.
if [[ "${VNC_TLS:-1}" == "1" ]]; then
    /usr/local/bin/gen-tls-cert.sh "${HOME_DIR}/.vnc-tls"
    if [[ -z "${VNC_TLS_SAN:-}" ]]; then
        log "NOTE: VNC_TLS_SAN is unset, so the certificate only covers"
        log "      localhost. Reaching this by server IP or hostname will make"
        log "      the browser reject it outright rather than just warn. Set"
        log "      VNC_TLS_SAN to that address in .env, then delete"
        log "      the .vnc-tls directory in the home volume to reissue."
    fi
fi

# --- ntfy sanity check --------------------------------------------------------
if [[ -z "${NTFY_TOPIC:-}" ]]; then
    log "WARNING: NTFY_TOPIC is unset. The send_notification MCP tool will fail"
    log "         until you set it. See .env.example."
fi

# --- Ownership ----------------------------------------------------------------
chown -R 1000:1000 "${HOME_DIR}"
mkdir -p /workspace && chown 1000:1000 /workspace || true

# Shared memory: Chromium and Electron are unhappy with Docker's default 64MB.
if [[ "$(df -k /dev/shm 2>/dev/null | awk 'NR==2 {print $2}')" == "65536" ]]; then
    log "WARNING: /dev/shm is only 64MB. Set shm_size: 2gb in docker-compose.yml"
    log "         or Chromium tabs will crash."
fi

log "Claude Desktop build commit: $(cat /etc/claude-desktop-build-commit 2>/dev/null || echo unknown)"
log "Browser note: $(cat /etc/claude-desktop-arch-notes 2>/dev/null || echo unknown)"
if [[ "${VNC_TLS:-1}" == "1" ]]; then
    log "Web desktop: https://localhost:${NOVNC_PORT:-6080}/ (user: ${VNC_USER})"
    log "  Self-signed certificate: expect a one-time browser warning."
else
    log "Web desktop: http://localhost:${NOVNC_PORT:-6080}/ (user: ${VNC_USER})"
fi

exec "$@"
