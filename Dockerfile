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
        ca-certificates curl wget gnupg git openssh-client openssl \
        sudo procps psmisc nano less locales tini \
        supervisor \
        xfce4-session xfwm4 xfdesktop4 xfce4-panel xfce4-settings \
        xfce4-terminal thunar \
        dbus-x11 x11-xserver-utils x11-utils xdg-utils \
        fonts-dejavu-core fonts-liberation \
        xclip xsel \
        x11vnc \
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

# --- opencode ----------------------------------------------------------------
# Terminal coding agent. The npm package fetches the right platform binary on
# install, so this works on both architectures.
RUN npm install -g opencode-ai \
    && opencode --version

# --- Antigravity (amd64 only) ------------------------------------------------
# Google publishes no arm64 Linux build -- the arm64 URL is a hard 404 -- so
# this mirrors the Google Chrome handling: install on amd64, note the absence
# on arm64 rather than failing the build.
#
# The download URL is version-pinned and Google rotates it, so a hardcoded URL
# eventually 404s. Build tries the pinned URL first for reproducibility, then
# falls back to scraping the current one off the download page.
ARG ANTIGRAVITY_URL=https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/1.23.2-4781536860569600/linux-x64/Antigravity.tar.gz
RUN set -eux; \
    if [ "${TARGETARCH}" != "amd64" ]; then \
        echo "Antigravity: no upstream arm64 build; skipping on ${TARGETARCH}." \
            > /etc/antigravity-notes; \
        cat /etc/antigravity-notes; \
    else \
        url="${ANTIGRAVITY_URL}"; \
        if ! curl -fsIL --max-time 30 "$url" >/dev/null 2>&1; then \
            echo "Pinned Antigravity URL is dead; scraping the download page."; \
            url="$(curl -fsSL --compressed --max-time 30 https://antigravity.google/download/linux \
                   | grep -oE 'https://[^"'"'"']*linux-x64/Antigravity\.tar\.gz' \
                   | head -1)"; \
            test -n "$url"; \
        fi; \
        echo "Antigravity: $url"; \
        curl -fsSL --max-time 600 -o /tmp/antigravity.tar.gz "$url"; \
        mkdir -p /opt; \
        tar xzf /tmp/antigravity.tar.gz -C /opt; \
        rm -f /tmp/antigravity.tar.gz; \
        mv /opt/Antigravity /opt/antigravity; \
        test -x /opt/antigravity/antigravity; \
        ln -sf /opt/antigravity/bin/antigravity /usr/local/bin/antigravity; \
        echo "$url" > /etc/antigravity-notes; \
    fi

# --- GitHub CLI --------------------------------------------------------------
RUN set -eux; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    rm -rf /var/lib/apt/lists/*; \
    gh --version

# --- Fix the application-menu launchers --------------------------------------
# The .desktop files shipped by the Claude and Chromium packages Exec the raw
# binaries, with no --no-sandbox. Electron and Chromium both refuse to start as
# root without it, so launching from the XFCE menu died with a trace trap while
# autostart -- which goes through the wrappers in /usr/local/bin -- worked fine.
# That asymmetry is confusing to debug, so point the menu at the same wrappers.
#
# Desktop Actions ("New Window", "New Incognito Window") carry their own Exec=
# lines, so every line has to be rewritten, not just the first.
RUN python3 - <<'PYEOF'
import glob, os, re

def rewrite(path, replacement):
    with open(path) as fh:
        text = fh.read()
    new = re.sub(r"^Exec=\S+", "Exec=" + replacement, text, flags=re.M)
    if new != text:
        with open(path, "w") as fh:
            fh.write(new)
        print("patched", path)

for path in glob.glob("/usr/share/applications/*claude*.desktop"):
    rewrite(path, "/usr/local/bin/start-claude-desktop.sh")

for path in glob.glob("/usr/share/applications/*chromium*.desktop"):
    rewrite(path, "/usr/local/bin/start-chromium.sh")

# Chrome gets its own wrapper: routing it through start-chromium.sh would
# silently launch Chromium instead, leaving Chrome unlaunchable from the menu.
for path in glob.glob("/usr/share/applications/*google-chrome*.desktop"):
    rewrite(path, "/usr/local/bin/start-chrome.sh")
PYEOF

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
COPY rootfs/usr/share/applications/ /usr/share/applications/
COPY rootfs/usr/local/bin/ /usr/local/bin/
COPY rootfs/etc/supervisor/conf.d/ /etc/supervisor/conf.d/
COPY rootfs/opt/skel/ /opt/skel/

# chmod 0755, NOT `chmod +x`. A shell script must be READABLE by whoever runs
# it -- the kernel hands the file to the interpreter, which then reads it. If
# the source file is 0700 on the build host, `chmod +x` yields 0711: execute
# without read. root ignores that, so the entrypoint still runs, but every
# supervisord program runs as uid 1000 and dies with "Permission denied".
# Setting the mode absolutely makes the image independent of the build host's
# file modes and umask.
RUN chmod 0755 /usr/local/bin/*.sh /usr/local/bin/restart-browser \
    && chmod -R a+rX /opt/skel /opt/ntfy-mcp \
    && chown -R 1000:1000 /opt/skel /opt/ntfy-mcp

# --- Runtime -----------------------------------------------------------------
# The whole desktop session runs as this user: KasmVNC, XFCE, and therefore
# Chromium and Claude Desktop. Root by default so Claude can act privileged
# without the mixed-ownership breakage that launching a single app under sudo
# causes. Set SESSION_USER=claude to run unprivileged.
ENV SESSION_USER=root \
    VNC_RESOLUTION=1920x1080 \
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
