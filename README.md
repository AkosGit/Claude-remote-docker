# Claude VNC Desktop

A Docker image containing a lightweight Linux desktop you reach from your browser, with Claude Desktop, a browser Claude can drive, a normal developer toolchain, and push notifications to your phone.

## What's inside

| Component | Notes |
| --- | --- |
| XFCE desktop | Minimal session: window manager, panel, terminal, file manager. No `xfce4-goodies`. |
| KasmVNC | `Xkasmvnc` is the X server, the websocket transport, and the web client in one process. Serves HTTPS at `https://localhost:6080/` behind basic auth. Chosen over noVNC for seamless clipboard — see below. |
| Claude Desktop | **Official** Anthropic Linux package from `downloads.claude.ai`. Both architectures. Launches automatically with the session. |
| Chromium | The only browser. Visible in the desktop, exposing CDP on `127.0.0.1:9222` — both what Claude drives and where you install the Claude extension. |
| Playwright MCP | `@playwright/mcp` attached to the visible Chromium, so you watch Claude click. |
| ntfy MCP | `send_notification` and `notification_status` tools that push to your phone. |
| x0vncserver | TigerVNC's screen-scraper. Re-exports the *same* `:1` display over raw RFB on 5901 for native VNC clients. Not a second X server, so no second desktop. |
| GitHub Desktop | Community Linux build ([shiftkey/desktop](https://github.com/shiftkey/desktop)) — GitHub ships no official Linux release. Both architectures. |
| Toolchain | git, GitHub CLI (`gh`), Node.js 22 (`node`, `npm`, `npx`), Python 3, `uv`, `opencode`. |
| Antigravity | Google's IDE. **amd64 only** — Google publishes no arm64 Linux build, so arm64 skips it and says so. |

## Quick start

```bash
cp .env.example .env
```

Edit `.env` and set `NTFY_TOPIC` to something long and random:

```bash
openssl rand -hex 16
```

Then build and run. The first build downloads Electron, two browsers, and the Claude Desktop installer, so expect 10–20 minutes and about 3.4 GB.

```bash
docker compose up -d --build
```

Watch the logs for the generated credentials if you left `VNC_PASSWORD` blank:

```bash
docker compose logs -f claude-desktop
```

Open <https://localhost:6080/> and sign in. Default username is `claude`. Expect a one-time certificate warning — the cert is self-signed.

## First-run setup

Four things need doing once. All of them persist in the `claude-home` volume afterwards.

1. **Log into Claude Desktop.** It launches with the session. The OAuth flow opens in Chromium inside the desktop, so it completes without leaving the VNC session.
2. **Install the Claude in Chrome extension.** Open Chromium from the XFCE menu, go to the Chrome Web Store, and install it. Sign in.
3. **Subscribe your phone to ntfy.** Install the ntfy app on iOS or Android, add a subscription for the topic you put in `NTFY_TOPIC`, pointed at `NTFY_SERVER`.
4. **Test the notification path.** Ask Claude Desktop: *"Use the ntfy tool to send me a test notification."* Your phone should buzz. If it does not, ask it to run `notification_status` — that reports the configuration, and which source it came from, without sending anything.

### How the ntfy MCP server gets its configuration

Worth knowing, because the obvious assumption is wrong. The MCP server is **not** a child of the container's init. Claude Desktop spawns it, and Claude Desktop is started by XFCE autostart, under `xfce4-session`, under `dbus-launch`, under supervisord. Every link has to pass the environment along, and Electron does not reliably do so.

When that breaks, the symptom is confusing: `NTFY_TOPIC` is plainly visible in any shell you open in the container, yet the MCP server reports it as unset — which looks like the container was started wrong when it was not.

So the entrypoint also writes the values to `~/.config/ntfy-mcp.env` (mode `0600`), and the server reads that whenever its environment is empty. That path depends on no process inheriting anything.

`notification_status` tells you which source was used. To change the topic without restarting, edit that file — config is read per tool call:

```bash
docker compose exec -u claude claude-desktop \
  sh -c 'echo NTFY_TOPIC=my-new-topic > ~/.config/ntfy-mcp.env'
```

A container restart rewrites the file from the environment whenever `NTFY_TOPIC` is set there.

## Everyday use

```bash
docker compose up -d      # start
docker compose down       # stop, keeping all state
docker compose down -v    # stop and wipe the home volume (full reset)
```

Your code lives in `./workspace` on the host and appears at `/workspace` in the container, so you can edit it in your usual editor and run it inside.

To get a shell:

```bash
docker compose exec -u claude claude-desktop bash
```

Chromium is started by XFCE autostart rather than by supervisord (it needs the session D-Bus for notifications and keyring access), so `supervisorctl` cannot restart it. Use the helper instead:

```bash
docker compose exec -u claude claude-desktop restart-browser
```

## Two ways in, one desktop

Both servers show the **same** session — same windows, same Claude Desktop instance. Move a window in one and it moves in the other.

| | Port | Client | Auth |
| --- | --- | --- | --- |
| KasmVNC (web) | 6080 | any browser | username + password |
| x0vncserver (native) | 5901 | Screen Sharing, bVNC, TigerVNC Viewer | password only |

KasmVNC is an X server; x0vncserver is not — it attaches to the display KasmVNC already created and re-exports it. That distinction is why this works. Running a *second* X server instead (TightVNC, another Xkasmvnc) would give you a second, separate desktop, and with a shared `HOME` you would get two Claude Desktops fighting over a single-instance lock and two Chromiums fighting over `SingletonLock`.

KasmVNC cannot serve raw RFB itself, incidentally: it accepts `-rfbport` and then ignores it, opening no listener. It is websocket-only. That is why x11vnc exists here at all.

### TLS: one switch per server

They pull in opposite directions, so there are two variables:

| | Default | Why |
| --- | --- | --- |
| `KASMVNC_TLS` | `1` | Keep it on. `navigator.clipboard` exists only in a secure context, so turning it off and browsing by IP silently kills copy/paste. |
| `X11VNC_TLS` | follows `VNC_TLS` | `1` wraps RFB in TLS, but then **only** VNC-over-SSL clients connect (bVNC Secure, SSVNC) — macOS Screen Sharing and ordinary clients just hang, waiting on a ClientHello that never comes. `0` is right when the traffic already rides ZeroTier, Tailscale, or an SSH tunnel. |

Both share one certificate, so `VNC_TLS_SAN` covers whichever are on. `VNC_TLS` is still honoured as a fallback for both, so older `.env` files keep working.

### Password limits, measured

| | Min | Max | Truncation |
| --- | --- | --- | --- |
| `VNC_PASSWORD` (web) | 1 | ~180 | none |
| `X11VNC_PASSWORD` (native) | 1 | **8, hard** | **silent past 8** |

`kasmvncpasswd` refuses anything under 6 characters, but that is CLI input validation only — the file is `user:hash:perms` with a SHA-256 crypt hash and a fixed `kasm` salt, so the entrypoint writes it directly when needed.

The native ceiling is the protocol: RFB VncAuth is DES with an 8-byte key. Storing `abcdefghWXYZ` and `abcdefgh` produces byte-identical files, so a 20-character password there buys exactly 8 characters of security with no warning from any client. The entrypoint says so out loud whenever you set more than 8.

## Clipboard and file transfer

**Copy/paste is seamless** — ordinary Cmd+C on your Mac, Cmd+V in the desktop, and back. This is why the image uses KasmVNC rather than noVNC: noVNC has no `navigator.clipboard` support in any released version (I checked 1.7.0, not just Debian's 1.3.0), so its clipboard is a manual paste-into-a-textarea panel. KasmVNC's web UI uses the real clipboard API.

**This needs a secure context, which is why the image serves HTTPS by default.** Browsers expose `navigator.clipboard` only over HTTPS, or over plain HTTP on `localhost` and nowhere else. Serving plain HTTP to a remote machine breaks copy/paste silently, with no error shown anywhere.

So `VNC_TLS=1` is the default: a self-signed certificate is generated on first boot into the home volume, and you accept a one-time browser warning. It persists across restarts, so you are not re-prompted.

**Set `VNC_TLS_SAN` to the address you actually type in the browser** — server IP, hostname, or Tailscale name. Chrome ignores a certificate's Common Name and matches only `subjectAltName`, so browsing to an address that is not listed makes Chrome **reject** the certificate outright rather than offer a click-through. After changing it, delete the cert to reissue:

```bash
docker compose exec claude-desktop rm -rf /home/claude/.vnc-tls
docker compose restart
```

For a remote deployment also set `BIND_ADDR=0.0.0.0` so the port publishes off-loopback. Only do that with `VNC_TLS=1`.

If you would rather not deal with certificates, set `VNC_TLS=0` and tunnel instead — `localhost` on your end is a secure context, so the clipboard works:

```bash
ssh -N -L 6080:127.0.0.1:6080 you@your-server
```

**For files, use the `./workspace` bind mount.** Anything you drop in `./workspace` on your Mac appears instantly at `/workspace` in the container, both directions, no size limit. That is better than any remote-desktop file transfer, and it is already set up.

The web UI can also download files the desktop places in `~/Downloads`. There is no upload through the web UI: that is a Kasm Workspaces (commercial) feature, absent from the open-source KasmVNC. Use the bind mount instead.

## Exposing it beyond localhost

`BIND_ADDR` controls the host interface for **both** ports; it defaults to `127.0.0.1` so a careless `up` never publishes the desktop.

The best option is an encrypted overlay — ZeroTier or Tailscale — rather than a LAN address. Only network members can route to it, the traffic is already encrypted, and nothing is exposed to the LAN:

```bash
BIND_ADDR=192.168.195.247       # your ZeroTier/Tailscale address
VNC_TLS_SAN=192.168.195.247     # must match, or Chrome hard-rejects the cert
KASMVNC_TLS=1
X11VNC_TLS=0                    # the overlay already encrypts it
```

`BIND_ADDR` must be an address that exists on the host, or Docker refuses to start with `Can't assign requested address`. And after changing `VNC_TLS_SAN`, reissue the certificate — the old one is kept otherwise:

```bash
docker compose exec claude-desktop rm -rf /home/claude/.vnc-tls && docker compose restart
```

## Configuration

Everything is set through `.env`. See `.env.example` for the full list; the ones you are most likely to touch:

- `NTFY_TOPIC` / `NTFY_SERVER` / `NTFY_TOKEN` — push notification target.
- `VNC_USER` / `VNC_PASSWORD` — web UI credentials. This is real basic auth, so there is no 8-character ceiling; leave the password blank to get a random one printed at boot.
- `KASMVNC_TLS` / `X11VNC_TLS` / `VNC_TLS_SAN` / `BIND_ADDR` — see above; these decide whether copy/paste works remotely and which VNC clients can connect.
- `VNC_USER` / `VNC_PASSWORD` / `X11VNC_PASSWORD` — credentials; see the limits table.
- `SESSION_USER` — who the desktop runs as, `root` by default.
- `VNC_RESOLUTION` — defaults to `1920x1080`.
- `VNC_FRAMERATE` — updates per second sent to the browser; defaults to `30`.
- `CHROMIUM_START_URL` — the page Chromium opens on launch.

MCP servers are registered in `~/.config/Claude/claude_desktop_config.json`, seeded from `/opt/skel` on first boot. Edit that file in the container to add more; it survives restarts.

## Running as root

By default the whole desktop session runs as **root** — KasmVNC, XFCE, and therefore Chromium and Claude Desktop. `SESSION_USER=claude` in `.env` switches it to unprivileged; that user has passwordless sudo either way.

`HOME` stays `/home/claude` in both modes, because that is the mounted volume, so logins, browser profiles and the TLS cert persist regardless.

**Do not launch a single app under `sudo` while the session runs as `claude`.** It leaves root-owned files in `/home/claude` and the next non-root start fails on its own config, with an error that points nowhere near the cause. Change `SESSION_USER` instead, which chowns the home directory to match.

## Resource limits

Docker runs containers unbounded by default, and on a small host that matters: on a 6.4 GB machine this container was the largest consumer by far and coincided with whole-machine I/O stalls.

`docker-compose.override.yml` therefore ships with conservative ceilings, and Compose picks it up automatically:

```yaml
services:
  claude-desktop:
    mem_limit: 3g
    memswap_limit: 4g
    cpus: 2.0
    # Must fit inside mem_limit: /dev/shm is tmpfs and counts as RAM.
    shm_size: 1gb
```

Raise them on a larger host — these suit roughly 6–8 GB of RAM.

### What the image does to stay small

Measured idle, no client connected, before and after:

| | Memory | Idle CPU |
| --- | --- | --- |
| Chromium autostarted, compositing on | 715.8 MiB | 2.12% |
| Current defaults | **488.2 MiB** | **0.19%** |

- **Chromium does not autostart.** It was 417 MiB and nearly all the idle CPU, purely to keep a CDP endpoint warm. Launch it from the panel menu when you want it; the wrapper still exposes CDP on 9222 for Playwright MCP.
- **Compositing is off.** Shadows and transparency rendered on the CPU, then discarded by VNC encoding.
- **No `xfdesktop`.** Saves ~37 MB of wallpaper and desktop icons. You lose the desktop right-click menu; the panel menu is unaffected.
- **Chromium is capped** when it does run: two renderers, one process per site, 512 MB V8 heap.
- **`shm_size: 512m`, and `--disable-dev-shm-usage` is not used.** That flag saves no memory — it moves shared buffers to `/tmp`, which is the container overlay, i.e. disk.

Two things deliberately not trimmed, because apt says they take the applications with them: `xdg-desktop-portal` is a dependency of `claude-desktop`, and `gcr` of `github-desktop`.

That `shm_size` comment is the trap worth knowing: `/dev/shm` is tmpfs, so it counts against `mem_limit`. Setting `shm_size` larger than the memory limit means Chromium can fill shared memory and trigger the container's own OOM killer.

Verify with `docker inspect claude-vnc-desktop --format '{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}} {{.HostConfig.ShmSize}}'`.

## Caveats, honestly

**Claude Desktop is the official Linux build.** Anthropic publishes an apt repository at `downloads.claude.ai/claude-desktop/apt/stable` covering amd64 and arm64.

This replaced an unofficial repack of the Windows installer ([`aaddrick/claude-desktop-debian`](https://github.com/aaddrick/claude-desktop-debian)), which stopped building once Anthropic reshaped the Electron bundle and that project's patch anchors no longer matched. Pinning it did not help: the artifact being patched is downloaded fresh on every build.

The `.deb` is pulled from the pool URL and checksum-verified rather than added as an apt source — the repository publishes a signed `InRelease` but no public key at any discoverable URL, so apt could not verify it. The SHA256 comes from the repository's own `Packages` index at build time. Pin a version with `CLAUDE_DESKTOP_VERSION`.

**Sandboxes are disabled.** Both Chromium and Electron run with `--no-sandbox`, because their sandboxes need privileges a default container does not have. The container is your isolation boundary, not the browser. Treat anything running inside as having the container's full access.

**The web desktop is plain HTTP behind basic auth.** Compose binds it to `127.0.0.1`, which is load-bearing twice over: it is what keeps an unencrypted session off the network, and it is what makes the browser treat the page as a secure context so the clipboard works at all. Do not republish it on a LAN address — tunnel over SSH instead. There is no raw RFB port: web basic auth takes a real password, where classic VNC auth caps at 8 characters.

**Public ntfy topics are readable by anyone who knows the name.** There is no account and no access control on `ntfy.sh`. Use a random topic, or self-host and set `NTFY_TOKEN`.

**It is not small.** The built arm64 image measures **3.41 GB** (my pre-build estimate of 2.2–2.6 GB was low). XFCE, Electron, and Chromium set the floor, and the Claude Desktop payload alone is a 162 MB `.deb` that unpacks larger. Dropping XFCE for Openbox saves roughly 400 MB.

## Layout

```
Dockerfile                                    single stage; Claude Desktop comes from Anthropic's apt pool
docker-compose.yml                            ports, volume, shm_size, healthcheck
.env.example                                  all configuration
rootfs/etc/supervisor/conf.d/supervisord.conf KasmVNC, XFCE
rootfs/usr/local/bin/entrypoint.sh            seeds the home volume, writes the web UI credentials
rootfs/usr/local/bin/start-*.sh               one wrapper per service; also the target of the menu .desktop entries
rootfs/usr/local/bin/start-x11vnc.sh          native VNC onto the same :1 display
rootfs/usr/local/bin/start-antigravity.sh     Antigravity (amd64 only)
rootfs/usr/share/applications/                menu entries this image adds
rootfs/usr/local/bin/gen-tls-cert.sh          self-signed cert, generated once into the home volume
rootfs/usr/local/bin/healthcheck.sh           scheme-aware (http vs https) container healthcheck
rootfs/usr/local/bin/restart-browser          restarts Chromium (autostarted, so not under supervisord)
rootfs/opt/ntfy-mcp/server.py                 the notification MCP server (env, then ~/.config/ntfy-mcp.env)
rootfs/opt/skel/                              seeded into /home/claude on first boot
rootfs/usr/local/bin/xfce-defaults.sh         first-run XFCE corrections (zoom, dock autohide)
workspace/                                    bind-mounted to /workspace
```

## Troubleshooting

**Black screen in the web desktop.** XFCE takes a few seconds after the X server. Check `docker compose logs claude-desktop` for the `xfce` program failing to start.

**Copy/paste does nothing.** Check the secure context first — open DevTools on the KasmVNC page and run:

```javascript
console.log(window.isSecureContext, typeof navigator.clipboard)
```

`false undefined` means you are on plain HTTP at a non-localhost address. Set `VNC_TLS=1` (the default) and put your address in `VNC_TLS_SAN`, or tunnel over SSH.

`true object` means the context is fine, so it is the browser: Firefox does not implement `navigator.clipboard.readText()` for page content and Safari is restricted — use Chrome, Chromium, or Edge. Also check the padlock icon → Site settings → Clipboard, in case the permission prompt was dismissed.

Note that `primary_clipboard_enabled` is off by default, so X middle-click PRIMARY selection does not sync. Ordinary copy/paste is unaffected.

**Chrome rejects the certificate outright instead of warning.** The address you are browsing to is not in the cert's `subjectAltName`. Put it in `VNC_TLS_SAN`, delete `/home/claude/.vnc-tls` in the container, and restart.

**An app launches from autostart but not from the XFCE application menu.** Fixed in the image, but worth knowing if you add another app. The `.desktop` files shipped by the Claude and Chromium packages `Exec` the raw binaries with no `--no-sandbox`, and both Electron and Chromium refuse to start as root without it — they die with a trace trap. Autostart worked because it goes through the wrappers in `/usr/local/bin`. The Dockerfile now rewrites every `Exec=` line in those desktop files, including the Desktop Action entries ("New Window" and friends), to point at the same wrappers. Any new GUI app you add needs the same treatment.

**A VNC client connects but nothing happens.** `X11VNC_TLS=1` and the client does not speak VNC-over-SSL. The server is waiting for a TLS ClientHello, which looks exactly like a hang. Use bVNC Secure or SSVNC, or set `X11VNC_TLS=0`.

**Port 5901 accepts the connection but never responds.** Restart just that service; the web UI is unaffected:

```bash
docker compose exec -u 0 claude-desktop supervisorctl restart nativevnc
```

This image used x11vnc until it proved unusable on some hosts. Debian ships 0.9.16 (2019) against libvncserver 0.9.14, and on Ubuntu 25.04 that pairing accepts connections into the kernel backlog and never calls `accept()` — they sit in `CLOSE_WAIT` with inode 0 while the process idles in `do_select`. It reproduced with a minimal `x11vnc -display :1 -rfbport 5905 -nopw`, ruling out flags and AppArmor. TigerVNC's `x0vncserver` does the same job and is maintained.

**A service dies immediately with `Permission denied` (exit 126).** The scripts in `rootfs/usr/local/bin/` need mode `0755`, not just the execute bit — a `#!/bin/bash` script has to be *readable* by the user running it. The Dockerfile sets the mode absolutely for this reason. If you add a script, `chmod 0755` it.

**Chromium tabs crash immediately.** `/dev/shm` is too small. `shm_size: "2gb"` is already in `docker-compose.yml`; if you run the image with plain `docker run`, pass `--shm-size=2g`.

**Playwright MCP cannot connect.** Chromium may not be up yet, or crashed. Check from inside the container: `curl -s http://127.0.0.1:9222/json/version`. If that fails, run `restart-browser`.

**Notification tool reports "Not configured".** Neither the MCP server's environment nor `~/.config/ntfy-mcp.env` has `NTFY_TOPIC`. Set it in `.env` and run `docker compose up -d` — no rebuild needed. The error message names both paths and the no-restart fix.

Do not be misled by `docker compose exec ... env | grep NTFY` showing the variable: an interactive shell gets the container environment directly, while the MCP server sits at the end of a long spawn chain that may have dropped it. `notification_status` reports which source it actually used.

**You have to log into Claude Desktop again after every restart, and a "Choose password for new keyring" dialog blocks the desktop on first login.** `gnome-keyring` is present — it arrives as a dependency of `gcr`, which `github-desktop` needs — but no keyring exists and nothing would unlock it on the next start, so the prompt achieves nothing.

To skip both, add `--password-store=basic` to the `exec` line in `start-claude-desktop.sh`. The token then persists, stored on disk in the home volume with weak protection. Off by default because it is a security trade worth making deliberately.

**Chromium shows a yellow "unsupported command-line flag: --no-sandbox" bar.** Expected and cosmetic. See the sandbox caveat above.

**`Failed to connect to the bus: /run/dbus/system_bus_socket`, repeatedly, in the logs.** Expected. There is no system D-Bus in the container, only the per-session bus that `start-xfce.sh` creates. XFCE, Chromium, and Electron all complain and all work anyway. Same for the missing `pulseaudio` and `power-manager` panel plugins.

**The build fails in the `claude-builder` stage.** Upstream changed something, or Anthropic did. Check the [`aaddrick/claude-desktop-debian`](https://github.com/aaddrick/claude-desktop-debian) issues, then bump `CLAUDE_DEB_REF`.
