#!/usr/bin/env python3
"""An MCP server that lets Claude push a notification to your phone via ntfy.

Configuration is read at call time, not import time, and from two sources in
order: the process environment first, then a config file.

    NTFY_TOPIC   (required) the topic your phone is subscribed to
    NTFY_SERVER  (optional) defaults to https://ntfy.sh
    NTFY_TOKEN   (optional) bearer token, for self-hosted servers with auth

The file fallback exists because this server is not started by the container.
It is spawned by Claude Desktop, which is itself started by XFCE autostart,
under xfce4-session, under dbus-launch, under supervisord. Every link in that
chain has to pass the environment along, and Electron in particular does not
reliably do so. When it breaks, the failure is invisible: the variables are
plainly present in a shell you open in the container, yet absent in this
process, which makes it look like the container was misconfigured when it was
not.

So the entrypoint also writes the values to CONFIG_FILE, and this server reads
that when the environment is empty. That path does not depend on any process
inheriting anything. Editing that file takes effect on the next tool call --
no container restart, since config is read per call.

Note that on the public ntfy.sh, topics are unauthenticated: anyone who knows
or guesses the topic name can read your notifications and publish to them. Use
a long random topic, or self-host.
"""

from __future__ import annotations

import json
import os
import pathlib
import urllib.error
import urllib.request

from mcp.server.mcpserver import MCPServer

# MCP Python SDK 2.x. In 1.x this class was called FastMCP and lived at
# mcp.server.fastmcp; the Dockerfile pins the major version accordingly.
mcp = MCPServer(
    name="ntfy",
    instructions=(
        "Push notifications to the user's phone via ntfy. Use send_notification "
        "when the user is likely away from the desktop: a long task finished, "
        "a decision is needed, or an error needs attention."
    ),
)

PRIORITY_NAMES = {1: "min", 2: "low", 3: "default", 4: "high", 5: "urgent"}


CONFIG_FILE = pathlib.Path.home() / ".config" / "ntfy-mcp.env"


def _read_config_file() -> dict[str, str]:
    """Parse the KEY=value fallback file. Missing or unreadable is not fatal."""
    values: dict[str, str] = {}
    try:
        text = CONFIG_FILE.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return values
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip("'\"")
    return values


def _config() -> tuple[str, str, str | None, str]:
    """Return (topic, server, token, source). Environment wins over the file."""
    file_values = _read_config_file()

    def pick(key: str, default: str = "") -> tuple[str, str]:
        env_value = os.environ.get(key, "").strip()
        if env_value:
            return env_value, "environment"
        file_value = file_values.get(key, "").strip()
        if file_value:
            return file_value, "config file"
        return default, "default"

    topic, source = pick("NTFY_TOPIC")
    if not topic:
        raise ValueError(
            "NTFY_TOPIC is set neither in this process's environment nor in "
            f"{CONFIG_FILE}. Set NTFY_TOPIC in the .env file next to "
            "docker-compose.yml and restart the container, which writes the "
            f"fallback file. To fix it right now without a restart, create "
            f"{CONFIG_FILE} containing a line reading NTFY_TOPIC=<your-topic> "
            "-- it takes effect on the next call."
        )
    server, _ = pick("NTFY_SERVER", "https://ntfy.sh")
    token, _ = pick("NTFY_TOKEN")
    return topic, server.rstrip("/"), (token or None), source


@mcp.tool()
def send_notification(
    message: str,
    title: str = "Claude",
    priority: int = 3,
    tags: str = "robot",
    click_url: str = "",
) -> str:
    """Push a notification to the user's phone.

    Use this to reach the user when they are away from the desktop -- a long
    task finished, something needs a decision, or an error needs attention.

    Args:
        message: The notification body. Keep it to a sentence or two.
        title: Short notification title.
        priority: 1 (min) to 5 (urgent). 5 bypasses the phone's quiet hours.
        tags: Comma-separated ntfy tags/emoji, e.g. "warning,skull" or "tada".
        click_url: Optional URL to open when the notification is tapped.

    Returns:
        A short confirmation, or an error description if the push failed.
    """
    if not message.strip():
        return "Refused: message was empty."
    if priority not in PRIORITY_NAMES:
        return f"Refused: priority must be 1-5, got {priority}."

    try:
        topic, server, token, _ = _config()
    except ValueError as exc:
        return f"Not configured: {exc}"

    headers = {
        "Title": title,
        "Priority": str(priority),
        "Tags": tags,
        "Content-Type": "text/plain; charset=utf-8",
    }
    if click_url.strip():
        headers["Click"] = click_url.strip()
    if token:
        headers["Authorization"] = f"Bearer {token}"

    request = urllib.request.Request(
        url=f"{server}/{topic}",
        data=message.encode("utf-8"),
        headers=headers,
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            body = response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:400]
        return f"Push failed: HTTP {exc.code} from {server}. {detail}"
    except urllib.error.URLError as exc:
        return f"Push failed: could not reach {server}. {exc.reason}"

    try:
        message_id = json.loads(body).get("id", "?")
    except (ValueError, AttributeError):
        message_id = "?"

    return (
        f"Sent to {server}/{topic} "
        f"(priority {PRIORITY_NAMES[priority]}, id {message_id})."
    )


@mcp.tool()
def notification_status() -> str:
    """Report whether push notifications are configured, without sending one."""
    try:
        topic, server, token, source = _config()
    except ValueError as exc:
        return f"Not configured: {exc}"
    auth = "with auth token" if token else "no auth token"
    return (
        f"Configured from {source}: server {server}, topic {topic}, {auth}. "
        f"(Fallback file: {CONFIG_FILE}, "
        f"{'present' if CONFIG_FILE.exists() else 'absent'}.)"
    )


if __name__ == "__main__":
    mcp.run(transport="stdio")
