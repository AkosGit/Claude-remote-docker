# Claude VNC Desktop — design

**Date:** 2026-08-19
**Status:** approved, implemented

## Goal

A single Docker image giving a browser-accessible Linux desktop that runs the Claude Desktop app, a browser Claude can control, a standard developer toolchain (git, Node/npx, Python, uv), and a path for Claude to push notifications to the user's phone.

## Decisions and the alternatives rejected

### Claude Desktop on Linux

Anthropic ships Claude Desktop for macOS and Windows only. Three shapes were considered:

1. **Unofficial Linux repack** — chosen. Uses `aaddrick/claude-desktop-debian` in a builder stage to repack the official Windows installer against Linux Electron, producing a `.deb`. Only option that yields the actual GUI app with MCP support.
2. Claude Code CLI only — rejected: officially supported and far lighter, but not the desktop app the user asked for.
3. `claude.ai` in a kiosk browser — rejected: no MCP, no local filesystem access.

Within option 1, vendoring upstream's build script was preferred over hand-rolling the `app.asar` extraction and native-binding stub inline. Hand-rolling is self-contained but means owning every breakage when the installer format changes; vendoring lets upstream fixes arrive via a pinned-ref bump.

### Browser control

Both channels, per the user's choice:

- **Chromium with `--remote-debugging-port=9222`**, visible in the desktop, driven by `@playwright/mcp` over CDP. Because it is the same window shown in VNC, the user watches Claude work.
- **Google Chrome** for the Claude in Chrome extension — amd64 only, since no official Linux arm64 Chrome exists. On arm64, Chromium serves both roles and the image logs that at build and boot.

### Notifications

ntfy over Pushover (user's choice: free, no account, self-hostable). Delivered as an MCP server rather than a CLI script or a Claude Code hook, so Claude calls it deliberately. Two tools: `send_notification` and `notification_status`. Configuration is read from the environment at call time, not import time, so changing the topic needs a restart but not a rebuild.

The public ntfy.sh has no access control on topics; this is documented rather than worked around.

### Desktop stack

Minimal XFCE (session, WM, desktop, panel, settings, terminal, Thunar — not the `xfce4` metapackage) over TigerVNC, with noVNC for browser access. `Xvnc` is the X server itself, so no separate Xvfb is needed. Openbox would have saved roughly 400 MB but the user chose a real desktop to live in.

### Process supervision

supervisord runs three programs: `xvnc`, `xfce`, `novnc`.

Chromium and Claude Desktop are deliberately **not** supervised. They are launched from XFCE autostart so they inherit the session D-Bus that `start-xfce.sh` creates — Electron needs it for the tray, Chromium for notifications and keyring. The cost is that `supervisorctl` cannot restart them individually; a `restart-browser` helper covers the common case.

### State

One named volume at `/home/claude`, plus a `./workspace` bind mount.

A volume mounted at `/home/claude` hides anything the image baked there, so all build-time user config lives in `/opt/skel` and the entrypoint seeds home from it on first boot (marker file), then uses `cp -an` on later boots to add new files without clobbering user edits.

### Multi-arch

Single Dockerfile branching on `TARGETARCH`: native builds on Apple Silicon and on x86 servers. Only Google Chrome diverges.

## Accepted trade-offs

- `--no-sandbox` on both Chromium and Electron. Their sandboxes need privileges a default container lacks; the container is the isolation boundary.
- noVNC is plain HTTP behind an 8-character VNC password. Compose binds it to loopback only.
- Image size lands around 2.2–2.6 GB. XFCE plus Electron plus two browsers sets that floor.
- The unofficial Claude Desktop build will break when Anthropic changes their installer. Mitigated by a bumpable pinned ref, not eliminated.

## Verification status

Built and run on arm64 (Docker 29.3.1, Apple Silicon). Verified: noVNC HTTP 200, VNC RFB 003.008 handshake, CDP reporting Chrome/151, all six processes up, toolchain versions, the ntfy MCP server's `initialize` / `tools/list` / `notification_status` over stdio, Playwright MCP starting against the CDP endpoint, and a screen capture showing XFCE with Claude Desktop and Chromium rendered.

Not verified: an actual push to a phone (would publish to a public ntfy topic — left for the user), Claude Desktop login, the Claude in Chrome extension install, and the amd64 build path including Google Chrome.

## Defects found during build-out, and their fixes

1. **Entrypoint died with SIGPIPE (exit 141).** `tr -dc … </dev/urandom | head -c 12` — `head` closes the pipe, `tr` takes SIGPIPE, and `set -o pipefail` propagated it. Replaced with `od -An -N8`, which reads a bounded number of bytes and exits on its own.
2. **`vncpasswd: command not found`.** Debian's `tigervnc-common` and `tigervnc-standalone-server` do not ship it; `tigervnc-tools` does, as `tigervncpasswd`. Added the package and made the entrypoint resolve either name.
3. **Claude Desktop never launched.** The `.deb` installs `/usr/bin/claude-desktop-unofficial`, not `claude-desktop`. The wrapper now resolves both names. Also discovered that upstream's launcher adds `--no-sandbox` only for AppImage and Wayland, so the X11 + deb path needs it passed explicitly, and that `CLAUDE_DISABLE_GPU=1` avoids a GPU-process FATAL loop in a headless container.
4. **Chromium refused to start after any container recreate.** Chromium writes the container hostname into the profile's `SingletonLock`; Docker assigns a new hostname on each recreate, so a leftover lock always read as "in use by another Chromium on another computer" and Chromium blocked on a modal nobody could dismiss. Fixed twice over: the entrypoint clears stale `Singleton*` files (nothing can legitimately hold them before any browser has started), and compose pins `hostname:`.
5. **The ntfy MCP server crashed on import.** MCP Python SDK 2.0.0 renamed `FastMCP` to `MCPServer` and moved it from `mcp.server.fastmcp` to `mcp.server.mcpserver`; the `mcp>=1.2.0` floor silently resolved to 2.x. Ported to the 2.x API and pinned `>=2.0.0,<3`. The build-time smoke test was also strengthened from `import mcp` to importing the actual class — the weak check is what let this reach runtime.

## Corrections to the pre-build design

The size estimate of 2.2–2.6 GB was low: the built arm64 image is 3.41 GB.


## Amendment 2026-08-19: noVNC replaced by KasmVNC

Prompted by a request to make native copy/paste work.

**Finding that drove the change:** noVNC cannot do seamless clipboard, and never could. Grepping the latest upstream release (1.7.0, not just Debian's packaged 1.3.0) shows no use of `navigator.clipboard` anywhere. Its clipboard is a manual paste-into-a-textarea side panel, and it has no file transfer at all. Upgrading noVNC would have bought nothing.

**Options weighed:**

| Option | Clipboard | File transfer | Verdict |
| --- | --- | --- | --- |
| noVNC | Manual panel | None | Rejected: cannot do the job |
| KasmVNC | Seamless (`navigator.clipboard` confirmed in the shipped bundle) | Download only, via `/api/downloads` serving `~/Downloads` | **Chosen** |
| Apache Guacamole | Seamless | Two-way over SFTP | Rejected: needs guacd plus a Java webapp, turning this into a multi-container stack |
| xrdp + RDP client | Native | Two-way folder redirection | Rejected: not browser-based, second remote-access stack in the image |
| TigerVNC Viewer on :5901 | Native | None | Rejected as the primary path once the web UI could do it |

No upload endpoint or upload strings exist anywhere in the open-source KasmVNC package; upload is a Kasm Workspaces commercial feature. This does not matter here, because the `./workspace` bind mount already provides unrestricted two-way file movement.

**Structural consequences:**

- `Xkasmvnc` subsumes the X server, websocket transport, and web client, so `tigervnc-*`, `novnc`, and `websockify` all leave the image and supervisord drops from three programs to two.
- Authentication changes model: KasmVNC uses basic auth with a username and password file (`~/.kasmpasswd`, written by `kasmvncpasswd`), replacing the classic 8-character VNC password. `.env` gains `VNC_USER`.
- The raw RFB port is dropped entirely rather than left exposed under weaker auth. Its purpose had been a working clipboard, which the web UI now provides.
- `-sslOnly 0` serves plain HTTP, which is sound only under the existing loopback binding. That binding is now load-bearing for a second reason: `navigator.clipboard` requires a secure context, and plain HTTP qualifies only on localhost. Republishing the port on a LAN address would silently break the clipboard as well as the security model. The README documents SSH tunnelling as the remote-access path.

**Interim work discarded:** a `vncconfig -nowin` autostart was added first, since without it TigerVNC bridges no X selections to RFB at all and no client could copy/paste in either direction. It was verified working, then removed with the rest of the TigerVNC stack — KasmVNC handles the clipboard in the server itself.

**Verified after the switch:** build succeeds, `Xkasmvnc` reports KasmVNC 1.5.0, four services run (websockify correctly gone), the web UI returns 401 unauthenticated, 401 on a wrong password, and 200 on the right one, the served page is titled KasmVNC, the served UI bundle contains three `navigator.clipboard` references, `/api/downloads` answers 200, and a screen capture shows XFCE with Claude Desktop and Chromium rendered.

**Not verified:** the actual host-to-container copy/paste round trip, which needs a human driving a real browser.

## Amendment 2026-08-20: TLS by default, and a mode bug that explains the amd64 failure

### Defect: `chmod +x` is not enough for a shell script

Reported as "on amd64 the Chrome browser and Claude app did not launch". The cause is not architecture.

The Dockerfile used `chmod +x /usr/local/bin/*.sh`. Where the source file was mode `0700` on the build host, `+x` produced `0711` — execute without read. A `#!/bin/bash` script must be **readable** by the user executing it, because the kernel hands the file to the interpreter and the interpreter reads the source. Result: `Permission denied`, exit 126.

It presented as a partial failure for two compounding reasons:

1. `entrypoint.sh` runs as **root** under supervisord, and root bypasses the read check — so the container appeared to start normally.
2. Every supervisord program runs as `user=claude` (uid 1000), so those failed. Which ones failed depended on which source files happened to carry `0700` versus `0755` in that particular checkout — file modes that Git does not fully record (it tracks only the executable bit) and that therefore vary with the clone's umask.

In the affected working tree, `start-vnc.sh` was `0711` while `start-chromium.sh` and `start-claude-desktop.sh` were `0700`, producing exactly the reported symptom: desktop up, both applications missing.

Fixed by setting the mode absolutely rather than relatively — `chmod 0755`, plus `chmod -R a+rX` over `/opt/skel` and `/opt/ntfy-mcp` — so the image no longer inherits the build host's modes or umask. Repo file modes were normalised to 0755/0644 as well.

Lesson worth keeping: in a Dockerfile, set permissions absolutely. A relative `chmod` silently imports whatever the build host happened to have, which is how a build reproducible on one machine breaks on another.

### TLS by default

Reported as "clipboard is not translating" on the remote amd64 deployment.

Server side was already correct: KasmVNC ships `data_loss_prevention.clipboard.server_to_client.enabled: true` and `client_to_server.enabled: true`, both unlimited. Confirmed also that KasmVNC handles the clipboard inside the server and needs no `vncconfig`-style helper, so dropping the TigerVNC bridge was not a regression.

The cause was client-side: `navigator.clipboard` is exposed only in a secure context — HTTPS anywhere, or plain HTTP on `localhost` and nowhere else. The remote deployment was reached by IP over plain HTTP, so the API was simply absent and the clipboard failed silently, with no error surfaced anywhere.

Changes:

- `VNC_TLS` defaults to `1`. `gen-tls-cert.sh` issues a self-signed cert on first boot into the home volume, so the fingerprint is stable across restarts and the browser only has to be told once. `VNC_TLS=0` restores plain HTTP for localhost-only or SSH-tunnelled use.
- `VNC_TLS_SAN` adds the address actually typed in the browser. IPv4 literals are emitted as `IP:` entries and names as `DNS:`, because Chrome matches only `subjectAltName` and treats a mismatch as a hard rejection rather than a click-through warning.
- `BIND_ADDR` (default `127.0.0.1`) controls the published interface, so a remote deployment is an explicit opt-in rather than an accident.
- The healthcheck moved into `healthcheck.sh`, which picks http or https from `VNC_TLS` and accepts 200 or 401 — basic auth means an unauthenticated probe returns 401, which still proves the server is serving.

Verified: all scripts `0755` in the image; all four services running, including the two that previously failed; HTTPS returns 401 unauthenticated and 200 authenticated; the served certificate carries `DNS:localhost, IP:127.0.0.1` plus the configured SANs; and the fingerprint is unchanged after `docker compose restart`.

Not verified: the host-to-container copy/paste round trip itself, which needs a human at a browser.
