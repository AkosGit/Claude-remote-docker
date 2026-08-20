# Claude VNC Desktop

A Docker image containing a lightweight Linux desktop you reach from your browser, with Claude Desktop, a browser Claude can drive, a normal developer toolchain, and push notifications to your phone.

## What's inside

| Component | Notes |
| --- | --- |
| XFCE desktop | Minimal session: window manager, panel, terminal, file manager. No `xfce4-goodies`. |
| KasmVNC | `Xkasmvnc` is the X server, the websocket transport, and the web client in one process. Serves HTTPS at `https://localhost:6080/` behind basic auth. Chosen over noVNC for seamless clipboard — see below. |
| Claude Desktop | Unofficial Linux build (see caveat below). Launches automatically with the session. The installed binary is `claude-desktop-unofficial`, not `claude-desktop`. |
| Chromium | Visible in the desktop, exposing CDP on `127.0.0.1:9222`. This is what Claude drives. |
| Google Chrome | **amd64 only.** For the Claude in Chrome extension. On arm64, Chromium fills this role. |
| Playwright MCP | `@playwright/mcp` attached to the visible Chromium, so you watch Claude click. |
| ntfy MCP | `send_notification` and `notification_status` tools that push to your phone. |
| Toolchain | git, GitHub CLI (`gh`), Node.js 22 (`node`, `npm`, `npx`), Python 3, `uv`. |

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
2. **Install the Claude in Chrome extension.** Open Chrome (amd64) or Chromium (arm64) from the XFCE menu, go to the Chrome Web Store, and install it. Sign in.
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

## Configuration

Everything is set through `.env`. See `.env.example` for the full list; the ones you are most likely to touch:

- `NTFY_TOPIC` / `NTFY_SERVER` / `NTFY_TOKEN` — push notification target.
- `VNC_USER` / `VNC_PASSWORD` — web UI credentials. This is real basic auth, so there is no 8-character ceiling; leave the password blank to get a random one printed at boot.
- `VNC_TLS` / `VNC_TLS_SAN` / `BIND_ADDR` — see the clipboard section; these decide whether copy/paste works remotely.
- `VNC_RESOLUTION` — defaults to `1920x1080`.
- `VNC_FRAMERATE` — updates per second sent to the browser; defaults to `30`.
- `CHROMIUM_START_URL` — the page Chromium opens on launch.

MCP servers are registered in `~/.config/Claude/claude_desktop_config.json`, seeded from `/opt/skel` on first boot. Edit that file in the container to add more; it survives restarts.

## Running as root

By default the whole desktop session runs as **root** — KasmVNC, XFCE, and therefore Chromium and Claude Desktop. `SESSION_USER=claude` in `.env` switches it to unprivileged; that user has passwordless sudo either way.

`HOME` stays `/home/claude` in both modes, because that is the mounted volume, so logins, browser profiles and the TLS cert persist regardless.

**Do not launch a single app under `sudo` while the session runs as `claude`.** It leaves root-owned files in `/home/claude` and the next non-root start fails on its own config, with an error that points nowhere near the cause. Change `SESSION_USER` instead, which chowns the home directory to match.

## Caveats, honestly

**Claude Desktop has no official Linux build.** Anthropic ships Mac and Windows only. This image uses [`aaddrick/claude-desktop-debian`](https://github.com/aaddrick/claude-desktop-debian), which repacks the official Windows installer against Linux Electron. It works well, but it is unofficial and unsupported: when Anthropic changes the installer format, builds break until upstream catches up. Bump `CLAUDE_DEB_REF` in `docker-compose.yml` to pick up their fixes. If reliability matters more than having the GUI, the Claude Code CLI is officially supported and installs with a single `npm i -g @anthropic-ai/claude-code`.

**Sandboxes are disabled.** Both Chromium and Electron run with `--no-sandbox`, because their sandboxes need privileges a default container does not have. The container is your isolation boundary, not the browser. Treat anything running inside as having the container's full access.

**The web desktop is plain HTTP behind basic auth.** Compose binds it to `127.0.0.1`, which is load-bearing twice over: it is what keeps an unencrypted session off the network, and it is what makes the browser treat the page as a secure context so the clipboard works at all. Do not republish it on a LAN address — tunnel over SSH instead. There is no raw RFB port: web basic auth takes a real password, where classic VNC auth caps at 8 characters.

**Public ntfy topics are readable by anyone who knows the name.** There is no account and no access control on `ntfy.sh`. Use a random topic, or self-host and set `NTFY_TOKEN`.

**It is not small.** The built arm64 image measures **3.41 GB** (my pre-build estimate of 2.2–2.6 GB was low). XFCE, Electron, and Chromium set the floor, and the Claude Desktop payload alone is a 162 MB `.deb` that unpacks larger. Dropping XFCE for Openbox saves roughly 400 MB. An amd64 build is larger still, since it also carries Google Chrome.

**Google Chrome is amd64-only.** There is no official Google Chrome build for Linux on arm64, so on Apple Silicon you get Chromium for both roles. The build prints which you got, and the container logs it at boot.

## Layout

```
Dockerfile                                    two stages: build the .deb, then the runtime image
docker-compose.yml                            ports, volume, shm_size, healthcheck
.env.example                                  all configuration
rootfs/etc/supervisor/conf.d/supervisord.conf KasmVNC, XFCE
rootfs/usr/local/bin/entrypoint.sh            seeds the home volume, writes the web UI credentials
rootfs/usr/local/bin/start-*.sh               one wrapper per service; also the target of the menu .desktop entries
rootfs/usr/local/bin/gen-tls-cert.sh          self-signed cert, generated once into the home volume
rootfs/usr/local/bin/healthcheck.sh           scheme-aware (http vs https) container healthcheck
rootfs/usr/local/bin/restart-browser          restarts Chromium (autostarted, so not under supervisord)
rootfs/opt/ntfy-mcp/server.py                 the notification MCP server (env, then ~/.config/ntfy-mcp.env)
rootfs/opt/skel/                              seeded into /home/claude on first boot
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

**A service dies immediately with `Permission denied` (exit 126).** The scripts in `rootfs/usr/local/bin/` need mode `0755`, not just the execute bit — a `#!/bin/bash` script has to be *readable* by the user running it. The Dockerfile sets the mode absolutely for this reason. If you add a script, `chmod 0755` it.

**Chromium tabs crash immediately.** `/dev/shm` is too small. `shm_size: "2gb"` is already in `docker-compose.yml`; if you run the image with plain `docker run`, pass `--shm-size=2g`.

**Playwright MCP cannot connect.** Chromium may not be up yet, or crashed. Check from inside the container: `curl -s http://127.0.0.1:9222/json/version`. If that fails, run `restart-browser`.

**Notification tool reports "Not configured".** Neither the MCP server's environment nor `~/.config/ntfy-mcp.env` has `NTFY_TOPIC`. Set it in `.env` and run `docker compose up -d` — no rebuild needed. The error message names both paths and the no-restart fix.

Do not be misled by `docker compose exec ... env | grep NTFY` showing the variable: an interactive shell gets the container environment directly, while the MCP server sits at the end of a long spawn chain that may have dropped it. `notification_status` reports which source it actually used.

**Claude Desktop shows nothing useful in `docker compose logs`.** Its launcher redirects app output to a file instead of stdout:

```bash
docker compose exec -u claude claude-desktop tail -50 /home/claude/.cache/claude-desktop-debian/launcher.log
```

There is also a built-in diagnostic:

```bash
docker compose exec -u claude claude-desktop claude-desktop-unofficial --doctor
```

**You have to log into Claude Desktop again after every restart.** Expected by default. The container has no keyring, so the app declines to persist the session token rather than store it weakly. Set `CLAUDE_PASSWORD_STORE=basic` in `.env` to keep the login, accepting that the token then sits on disk in the home volume with weak protection.

**Chromium shows a yellow "unsupported command-line flag: --no-sandbox" bar.** Expected and cosmetic. See the sandbox caveat above.

**`Failed to connect to the bus: /run/dbus/system_bus_socket`, repeatedly, in the logs.** Expected. There is no system D-Bus in the container, only the per-session bus that `start-xfce.sh` creates. XFCE, Chromium, and Electron all complain and all work anyway. Same for the missing `pulseaudio` and `power-manager` panel plugins.

**The build fails in the `claude-builder` stage.** Upstream changed something, or Anthropic did. Check the [`aaddrick/claude-desktop-debian`](https://github.com/aaddrick/claude-desktop-debian) issues, then bump `CLAUDE_DEB_REF`.
