# syntax=docker/dockerfile:1.7
#
# Claude VNC Desktop
# ------------------
# A Debian-based container running an XFCE desktop over VNC/noVNC, with:
#   - Claude Desktop, from Anthropic's official Linux apt repository
#   - Chromium wired for CDP control via Playwright MCP
#   - git, Node.js 22 (node/npm/npx), Python 3, uv
#   - An ntfy MCP server so Claude can push notifications to your phone
#
# Multi-arch: builds natively on amd64 and arm64.

# =============================================================================
# The runtime image (single stage)
# =============================================================================
FROM debian:bookworm-slim AS final

ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    DISPLAY=:1

# --- Core OS + desktop -------------------------------------------------------
# Minimal XFCE: session, WM, panel, settings, terminal, file manager.
# Deliberately NOT installing the xfce4 metapackage or xfce4-goodies.
#
# xfdesktop4 is also omitted: it draws the wallpaper and desktop icons and
# costs ~37MB resident, none of which matters when every application is
# launched from the panel menu. The panel still provides the applications menu;
# what you lose is the desktop-background right-click menu.
#
# xdg-desktop-portal and gcr are NOT trimmed despite being similar dead weight:
# apt shows claude-desktop depends on the former and github-desktop on the
# latter, so removing them uninstalls the applications this image exists for.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg git openssh-client openssl \
        sudo procps psmisc nano less locales tini tmux xz-utils \
        supervisor \
        xfce4-session xfwm4 xfce4-panel xfce4-settings \
        xfce4-terminal thunar \
        dbus-x11 x11-xserver-utils x11-utils xdg-utils \
        fonts-dejavu-core fonts-liberation \
        xclip xsel \
        tigervnc-scraping-server tigervnc-tools \
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
# The only browser in the image. It is both the CDP target Playwright MCP
# drives and the browser you install the Claude extension into.
#
# Google Chrome was removed: it publishes no arm64 Linux build, so carrying it
# meant an architecture-conditional install, a second wrapper, a second profile
# and a second .desktop rewrite -- all so amd64 could have a browser that does
# the same job as the one already here.
RUN apt-get update && apt-get install -y --no-install-recommends \
        chromium chromium-common \
    && rm -rf /var/lib/apt/lists/*

# --- Claude Desktop ----------------------------------------------------------
# Installed from Anthropic's OFFICIAL Linux repository, which publishes both
# amd64 and arm64. This replaces a two-stage unofficial repack of the Windows
# installer (aaddrick/claude-desktop-debian), which no longer builds at all:
# Anthropic reshaped the Electron bundle and that project's patch anchors stop
# matching, failing with "Anchor 'cowork C1 (foreground download)' matched no
# file under app.asar.contents/.vite/build". Pinning it did not help, because
# the artifact being patched is downloaded fresh on every build.
#
# The pool .deb is fetched directly and checksum-verified rather than added as
# an apt source: the repository publishes a signed InRelease but no public key
# at any discoverable URL, so apt could not verify it either way. The SHA256 is
# read from the repository's own Packages index at build time, so there is no
# per-architecture hash hardcoded here to rot.
ARG CLAUDE_DESKTOP_VERSION=1.34493.1
ARG CLAUDE_APT_BASE=https://downloads.claude.ai/claude-desktop/apt/stable
RUN set -eux; \
    idx="$(curl -fsSL "${CLAUDE_APT_BASE}/dists/stable/main/binary-${TARGETARCH}/Packages")"; \
    pool="pool/main/c/claude-desktop/claude-desktop_${CLAUDE_DESKTOP_VERSION}_${TARGETARCH}.deb"; \
    sha="$(printf '%s' "$idx" | awk -v f="$pool" 'BEGIN{RS=""} $0 ~ ("Filename: " f) {for(i=1;i<=NF;i++) if($i=="SHA256:") print $(i+1)}')"; \
    test -n "$sha"; \
    echo "Claude Desktop ${CLAUDE_DESKTOP_VERSION} ${TARGETARCH} sha256=$sha"; \
    curl -fsSL -o /tmp/claude-desktop.deb "${CLAUDE_APT_BASE}/${pool}"; \
    echo "$sha  /tmp/claude-desktop.deb" | sha256sum -c -; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/claude-desktop.deb; \
    rm -f /tmp/claude-desktop.deb; \
    rm -rf /var/lib/apt/lists/*; \
    echo "${CLAUDE_DESKTOP_VERSION}" > /etc/claude-desktop-version; \
    command -v claude-desktop

# --- opencode ----------------------------------------------------------------
# Terminal coding agent. The npm package fetches the right platform binary on
# install, so this works on both architectures.
RUN npm install -g opencode-ai \
    && opencode --version

# --- Intel SDE (Software Development Emulator, amd64 only) ------------------
# Emulates AVX/AVX2/AVX-512 instructions on x86_64 CPUs that lack them
# (such as Intel Pentium Silver / Celeron / Atom processors).
ARG INTEL_SDE_VERSION=10.13.1-2026-07-28
RUN set -eux; \
    if [ "${TARGETARCH}" = "amd64" ]; then \
        url="https://downloadmirror.intel.com/924984/sde-external-${INTEL_SDE_VERSION}-lin.tar.xz"; \
        mkdir -p /opt/intel-sde; \
        curl -fsSL "$url" | tar -xJ -C /opt/intel-sde --strip-components=1; \
        ln -sf /opt/intel-sde/sde64 /usr/local/bin/sde64; \
        ln -sf /opt/intel-sde/sde /usr/local/bin/sde; \
        test -x /usr/local/bin/sde64; \
    fi

# --- Muse CLI ----------------------------------------------------------------
# Meta's terminal AI coding agent. Installs on both amd64 and arm64.
# Transparently falls back to Intel SDE emulation on x86_64 CPUs lacking AVX2.
RUN set -eux; \
    mkdir -p /opt/muse; \
    curl -fsSL https://dev.meta.ai/install.sh | MUSE_INSTALL_DIR=/opt/muse bash; \
    test -x /opt/muse/muse; \
    printf '%s\n' \
        '#!/bin/bash' \
        'set -e' \
        'if [ "$(uname -m)" = "x86_64" ] && ! grep -q "avx2" /proc/cpuinfo 2>/dev/null; then' \
        '    if command -v sde64 >/dev/null 2>&1; then' \
        '        exec sde64 -follow_child -- /opt/muse/muse "$@"' \
        '    fi' \
        'fi' \
        'exec /opt/muse/muse "$@"' \
        > /usr/local/bin/muse; \
    chmod 0755 /usr/local/bin/muse; \
    chmod -R a+rX /opt/muse

# --- Antigravity IDE (amd64 only) --------------------------------------------
# Google publishes no arm64 Linux build -- the arm64 URL is a hard 404 -- so
# install on amd64 and note the absence
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

# --- Antigravity CLI (agy) ---------------------------------------------------
# Google's terminal AI coding agent. Flat native binary supporting both amd64
# and arm64. Provides the `agy` command and an `antigravity-cli` alias.
RUN set -eux; \
    curl -fsSL https://antigravity.google/cli/install.sh | bash -s -- --dir /usr/local/bin; \
    test -x /usr/local/bin/agy; \
    ln -sf /usr/local/bin/agy /usr/local/bin/antigravity-cli; \
    if [ ! -e /usr/local/bin/antigravity ]; then \
        ln -sf /usr/local/bin/agy /usr/local/bin/antigravity; \
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

# --- Electron: disable the sandbox for root shells ---------------------------
# The entrypoint exports ELECTRON_DISABLE_SANDBOX for supervisord's children,
# which covers the desktop session and anything launched from it. It does NOT
# cover a shell opened with `docker exec`, which receives the image's static
# environment instead. Electron apps started from such a shell would still die
# with "Running as root without --no-sandbox is not supported".
#
# profile.d covers login shells on both paths, and is guarded on uid 0 so the
# sandbox stays intact under SESSION_USER=claude.
RUN printf '%s\n' \
    '# Electron will not start as root with its sandbox enabled. The container' \
    '# is the isolation boundary here, not the app.' \
    'if [ "$(id -u)" = "0" ]; then' \
    '  export ELECTRON_DISABLE_SANDBOX=1' \
    'fi' \
    > /etc/profile.d/00-electron-sandbox.sh \
    && chmod 0644 /etc/profile.d/00-electron-sandbox.sh

# --- Chromium: --no-sandbox globally, but only when running as root ----------
# Debian's /usr/bin/chromium is a shell wrapper that sources /etc/chromium.d/*
# and appends $CHROMIUM_FLAGS, which gives one place to fix every Chromium
# launch -- including ones this image never sees, such as a tool spawning a
# browser or someone typing `chromium` in a terminal. The per-app wrappers in
# /usr/local/bin only cover launches we control.
#
# Guarded on uid 0: with SESSION_USER=claude the sandbox works normally and
# must not be weakened.
RUN printf '%s\n' \
    '# Chromium refuses to start as root unless the sandbox is disabled.' \
    '# The container is the isolation boundary here, not the browser.' \
    'if [ "$(id -u)" = "0" ]; then' \
    '  CHROMIUM_FLAGS="$CHROMIUM_FLAGS --no-sandbox"' \
    'fi' \
    > /etc/chromium.d/00-container-root-no-sandbox \
    && chmod 0644 /etc/chromium.d/00-container-root-no-sandbox

# --- GitHub Desktop ----------------------------------------------------------
# GitHub publishes no Linux build. shiftkey/desktop is the long-standing
# community fork and, unlike Antigravity, ships both amd64 and arm64 debs -- so
# this needs no architecture branch.
ARG GITHUB_DESKTOP_VERSION=3.4.13-linux1
RUN set -eux; \
    url="https://github.com/shiftkey/desktop/releases/download/release-${GITHUB_DESKTOP_VERSION}/GitHubDesktop-linux-${TARGETARCH}-${GITHUB_DESKTOP_VERSION}.deb"; \
    echo "GitHub Desktop: $url"; \
    wget -q -O /tmp/github-desktop.deb "$url"; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/github-desktop.deb; \
    rm -f /tmp/github-desktop.deb; \
    rm -rf /var/lib/apt/lists/*; \
    command -v github-desktop

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

for path in glob.glob("/usr/share/applications/*github*desktop*.desktop"):
    rewrite(path, "/usr/local/bin/start-github-desktop.sh")

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

# KasmVNC's video encoding mode needs ffmpeg's libraries at runtime. Without
# them it logs "ffmpeg: Could not open libavformat.so" at every start and falls
# back to still-image encoding for everything.
#
# That mode is what handles high-change regions -- scrolling, video, animation
# -- which is exactly the traffic that costs the most over RFB. Worth ~30MB.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libavformat59 libavcodec59 libswscale6 libavutil57 \
    && rm -rf /var/lib/apt/lists/* \
    && ldconfig -p | grep -q libavformat \
    && ldconfig -p | grep -q libswscale

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
    && chmod -R a+rX /opt/skel /opt/ntfy-mcp /opt/muse \
    && chown -R 1000:1000 /opt/skel /opt/ntfy-mcp /opt/muse \
    && if [ -d /opt/intel-sde ]; then chmod -R a+rX /opt/intel-sde; fi

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
