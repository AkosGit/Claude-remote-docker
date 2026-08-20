#!/usr/bin/env python3
"""An MCP server that lets Claude push a notification to your phone via ntfy.

Configuration comes from the environment, read at call time rather than at
import time, so changing NTFY_TOPIC and restarting the container is enough --
no need to rebuild the image.

    NTFY_TOPIC   (required) the topic your phone is subscribed to
    NTFY_SERVER  (optional) defaults to https://ntfy.sh
    NTFY_TOKEN   (optional) bearer token, for self-hosted servers with auth

Note that on the public ntfy.sh, topics are unauthenticated: anyone who knows
or guesses the topic name can read your notifications and publish to them. Use
a long random topic, or self-host.
"""

from __future__ import annotations

import json
import os
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


def _config() -> tuple[str, str, str | None]:
    topic = os.environ.get("NTFY_TOPIC", "").strip()
    if not topic:
        raise ValueError(
            "NTFY_TOPIC is not set in the container environment. "
            "Set it in .env and restart the container."
        )
    server = os.environ.get("NTFY_SERVER", "https://ntfy.sh").rstrip("/")
    token = os.environ.get("NTFY_TOKEN", "").strip() or None
    return topic, server, token


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
        topic, server, token = _config()
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
        topic, server, token = _config()
    except ValueError as exc:
        return f"Not configured: {exc}"
    auth = "with auth token" if token else "no auth token"
    return f"Configured: server {server}, topic {topic}, {auth}."


if __name__ == "__main__":
    mcp.run(transport="stdio")
