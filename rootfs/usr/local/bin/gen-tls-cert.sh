#!/bin/bash
# Generates a self-signed certificate for the KasmVNC web UI, once, into the
# home volume so it survives restarts -- a cert that changed on every boot
# would make the browser re-prompt forever and train you to click through
# warnings without reading them.
#
# Why this exists: browsers expose navigator.clipboard only in a secure
# context. Plain HTTP qualifies solely on localhost, so any remote deployment
# needs TLS or the clipboard silently does nothing.
#
# Chrome ignores the certificate's Common Name entirely and matches only
# subjectAltName, and an SAN entry for an IP address must be typed as IP:,
# not DNS:. Getting that wrong yields a cert the browser rejects outright
# rather than merely warning about.
set -euo pipefail

CERT_DIR="${1:?usage: gen-tls-cert.sh <dir>}"
CRT="${CERT_DIR}/kasmvnc.crt"
KEY="${CERT_DIR}/kasmvnc.key"
COMBINED="${CERT_DIR}/kasmvnc.pem"

mkdir -p "${CERT_DIR}"

if [[ -s "${CRT}" && -s "${KEY}" ]]; then
    echo "[tls] reusing existing certificate in ${CERT_DIR}"
    # An older cert predates the combined PEM; rebuild it rather than leaving
    # x11vnc without one.
    if [[ ! -s "${COMBINED}" ]]; then
        cat "${KEY}" "${CRT}" > "${COMBINED}"
        chmod 600 "${COMBINED}"
        echo "[tls] rebuilt combined PEM for x11vnc"
    fi
    exit 0
fi

# Always valid for loopback; VNC_TLS_SAN adds the address you actually browse
# to (server IP, hostname, or Tailscale name), comma-separated.
sans="DNS:localhost,IP:127.0.0.1"
if [[ -n "${VNC_TLS_SAN:-}" ]]; then
    IFS=',' read -ra entries <<< "${VNC_TLS_SAN}"
    for e in "${entries[@]}"; do
        e="$(echo "$e" | tr -d '[:space:]')"
        [[ -z "$e" ]] && continue
        # An IPv4 literal must be declared as IP:, a name as DNS:.
        if [[ "$e" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            sans="${sans},IP:${e}"
        else
            sans="${sans},DNS:${e}"
        fi
    done
fi

echo "[tls] generating self-signed certificate"
echo "[tls]   subjectAltName = ${sans}"

openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "${KEY}" -out "${CRT}" \
    -days 3650 -sha256 \
    -subj "/CN=claude-vnc-desktop" \
    -addext "subjectAltName=${sans}" \
    -addext "basicConstraints=CA:FALSE" \
    -addext "keyUsage=digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" \
    >/dev/null 2>&1

chmod 600 "${KEY}"
chmod 644 "${CRT}"

# x11vnc's -ssl wants one PEM holding both key and certificate, unlike
# KasmVNC which takes them as separate files. Same key material either way, so
# both servers present an identical certificate and VNC_TLS_SAN covers both.
cat "${KEY}" "${CRT}" > "${COMBINED}"
chmod 600 "${COMBINED}"

echo "[tls] certificate written to ${CRT}"
echo "[tls] combined PEM for x11vnc written to ${COMBINED}"
