# syntax=docker/dockerfile:1.7
#
# Claude VNC Desktop
# ------------------
# A Debian-based container running an XFCE desktop over VNC/noVNC, with:
#   - Claude Desktop (unofficial Linux repack of the official Windows build)
#   - Chromium wired for CDP control via Playwright MCP
#   - Google Chrome (amd64 only) for the Claude in Chrome extension
#   - git, Node.js 22 (node/npm/npx), Python 3, uv
#   - An ntfy MCP server so Claude can push notifications to your phone
#
# Multi-arch: builds natively on amd64 and arm64.

# =============================================================================
# Stage 1: build the Claude Desktop .deb
# =============================================================================
# Claude Desktop has no official Linux build. aaddrick/claude-desktop-debian
# repacks the official Windows installer (extract nupkg -> patch app.asar ->
# stub the Windows-only native bindings -> rebuild against Linux Electron).
#
# We pin to a commit so builds are reproducible. To pick up upstream fixes
# after Anthropic changes their installer format, bump CLAUDE_DEB_REF.
FROM debian:bookworm-slim AS claude-builder

ARG CLAUDE_DEB_REPO=https://github.com/aaddrick/claude-desktop-debian.git
ARG CLAUDE_DEB_REF=main

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget git sudo file \
        p7zip-full icoutils imagemagick \
        dpkg-dev fakeroot build-essential \
        python3 \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Upstream's build.sh refuses to run as root and calls sudo itself.
RUN useradd -m -s /bin/bash builder \
    && echo 'builder ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/builder \
    && chmod 0440 /etc/sudoers.d/builder

USER builder
WORKDIR /home/builder

RUN git clone "${CLAUDE_DEB_REPO}" claude-desktop-debian \
    && cd claude-desktop-debian \
    && git checkout "${CLAUDE_DEB_REF}" \
    && git rev-parse HEAD > /home/builder/CLAUDE_DEB_COMMIT

# Electron is fetched during the build; needs network.
RUN cd /home/builder/claude-desktop-debian \
    && chmod +x ./build.sh \
    && ./build.sh --build deb --clean yes

# The script's output path has moved between upstream revisions, so find it
# rather than hardcoding. Fail loudly if nothing turned up.
RUN set -eux; \
    deb="$(find /home/builder/claude-desktop-debian -name 'claude-desktop*.deb' -print -quit)"; \
    test -n "$deb"; \
    mkdir -p /home/builder/out; \
    cp "$deb" /home/builder/out/claude-desktop.deb; \
    ls -lh /home/builder/out/

# =============================================================================
# Stage 2: the runtime image
# =============================================================================
FROM debian:bookworm-slim AS final

ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    DISPLAY=:1

# --- Core OS + desktop -------------------------------------------------------
# Minimal XFCE: session, WM, desktop, panel, settings, terminal, file manager.
# Deliberately NOT installing the xfce4 metapackage or xfce4-goodies.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg git openssh-client \
        sudo procps psmisc nano less locales tini \
        supervisor \
        xfce4-session xfwm4 xfdesktop4 xfce4-panel xfce4-settings \
        xfce4-terminal thunar \
        dbus-x11 x11-xserver-utils x11-utils xdg-utils \
        fonts-dejavu-core fonts-liberation \
        xclip xsel \
        libnotify-bin \
    && rm -rf /var/lib/apt/lists/*

# --- Node.js 22 (node, npm, npx) --------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && node --version && npm --version && npx --version

# --- Python 3 + uv -----------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-venv python3-pip \
    && rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh \
      | env UV_INSTALL_DIR=/usr/local/bin UV_UNMANAGED_INSTALL=/usr/local/bin sh \
    && uv --version

# --- Browsers ----------------------------------------------------------------
# Chromium is the CDP target that Playwright MCP drives. Available on both arches.
RUN apt-get update && apt-get install -y --no-install-recommends \
        chromium chromium-common \
    && rm -rf /var/lib/apt/lists/*

# Google Chrome ships Linux binaries for amd64 only. On arm64 there is no
# official build, so Chromium doubles as the extension browser.
RUN set -eux; \
    if [ "${TARGETARCH}" = "amd64" ]; then \
        wget -q -O /tmp/chrome.deb \
            https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb; \
        apt-get update; \
        apt-get install -y --no-install-recommends /tmp/chrome.deb; \
        rm -f /tmp/chrome.deb; \
        rm -rf /var/lib/apt/lists/*; \
        echo "google-chrome-stable" > /etc/claude-desktop-arch-notes; \
    else \
        echo "No official Google Chrome for ${TARGETARCH}; using Chromium for the extension browser." \
            > /etc/claude-desktop-arch-notes; \
    fi; \
    cat /etc/claude-desktop-arch-notes

# --- Claude Desktop ----------------------------------------------------------
COPY --from=claude-builder /home/builder/out/claude-desktop.deb /tmp/claude-desktop.deb
COPY --from=claude-builder /home/builder/CLAUDE_DEB_COMMIT /etc/claude-desktop-build-commit

RUN apt-get update \
    && apt-get install -y --no-install-recommends /tmp/claude-desktop.deb \
    && rm -f /tmp/claude-desktop.deb \
    && rm -rf /var/lib/apt/lists/*

# --- ntfy MCP server ---------------------------------------------------------
COPY rootfs/opt/ntfy-mcp/ /opt/ntfy-mcp/
RUN uv venv /opt/ntfy-mcp/.venv \
    && VIRTUAL_ENV=/opt/ntfy-mcp/.venv uv pip install --python /opt/ntfy-mcp/.venv/bin/python "mcp>=2.0.0,<3" \
    && /opt/ntfy-mcp/.venv/bin/python -c "from mcp.server.mcpserver import MCPServer; print('mcp server API ok')"

# --- KasmVNC -----------------------------------------------------------------
# Xkasmvnc is the X server, the websocket transport, and the web client in one
# process. Replaces Xvnc + websockify + noVNC.
#
# Why not noVNC: neither Debian's 1.3.0 nor upstream 1.7.0 uses the async
# clipboard API, so its clipboard is a manual paste-into-a-textarea panel.
# KasmVNC's web UI does use it, giving real host<->desktop copy/paste.
ARG KASMVNC_VERSION=1.5.0
RUN set -eux; \
    url="https://github.com/kasmtech/KasmVNC/releases/download/v${KASMVNC_VERSION}/kasmvncserver_bookworm_${KASMVNC_VERSION}_${TARGETARCH}.deb"; \
    wget -q -O /tmp/kasmvnc.deb "$url"; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/kasmvnc.deb; \
    rm -f /tmp/kasmvnc.deb; \
    rm -rf /var/lib/apt/lists/*; \
    Xkasmvnc -version 2>&1 | head -2 || true; \
    test -d /usr/share/kasmvnc/www

# --- User --------------------------------------------------------------------
RUN useradd -m -u 1000 -s /bin/bash claude \
    && echo 'claude ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/claude \
    && chmod 0440 /etc/sudoers.d/claude \
    && dbus-uuidgen --ensure

# --- Scripts, config skeleton, supervisor ------------------------------------
# Everything user-facing lands in /opt/skel, NOT /home/claude: the home volume
# is mounted over /home/claude at runtime and would hide anything baked here.
# entrypoint.sh seeds home from skel on first boot.
COPY rootfs/usr/local/bin/ /usr/local/bin/
COPY rootfs/etc/supervisor/conf.d/ /etc/supervisor/conf.d/
COPY rootfs/opt/skel/ /opt/skel/

RUN chmod +x /usr/local/bin/*.sh /usr/local/bin/restart-browser \
    && chown -R 1000:1000 /opt/skel /opt/ntfy-mcp

# --- Runtime -----------------------------------------------------------------
ENV VNC_RESOLUTION=1920x1080 \
    VNC_DEPTH=24 \
    VNC_PORT=5901 \
    NOVNC_PORT=6080 \
    CDP_PORT=9222 \
    NTFY_SERVER=https://ntfy.sh \
    HOME=/home/claude

EXPOSE 6080 5901

VOLUME ["/home/claude"]
WORKDIR /workspace

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
