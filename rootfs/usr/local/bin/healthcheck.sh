#!/bin/bash
# Scheme-aware healthcheck. Basic auth means an unauthenticated probe returns
# 401, which still proves the server is up and serving; -k accepts the
# self-signed certificate.
set -uo pipefail

if [[ "${VNC_TLS:-1}" == "1" ]]; then
    url="https://127.0.0.1:${NOVNC_PORT:-6080}/"
else
    url="http://127.0.0.1:${NOVNC_PORT:-6080}/"
fi

code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "${url}" || echo 000)"
case "${code}" in
    200|401) exit 0 ;;
    *) echo "healthcheck: ${url} returned ${code}" >&2; exit 1 ;;
esac
