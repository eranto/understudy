#!/usr/bin/env python3
"""
Understudy — stalled-project nudge digest.

Reuses the dashboard's own health model (server.compute_health, via
server.all_projects) to find projects where the ball is in your court and going
stale — light 'slipping' (5–10d) or 'stalled' (≥10d) — and posts a single
concise digest to your chat channel, most-stalled first, with each project's
next step.

A standalone script can't call MCP tools directly; only a `claude -p` session has
the chat MCP tooling the worker uses. So we shell out to `claude -p` the same way
orchestrator.sh does (with --dangerously-skip-permissions so the chat tool isn't
gated on a prompt). If `claude` isn't found or the post fails, the digest is
printed to stdout instead.

Configuration (environment):
    QUEUE_ROOT          (required by server.py) absolute path to the queue root
    NUDGE_CHANNEL       chat channel to post to (default: #general)
    CLAUDE_BIN          path to your LLM CLI (default: ~/.local/bin/claude)
    NUDGE_CLAUDE_MODEL  model for the throwaway posting session (default: sonnet)

Usage:
    python3 dashboard/nudge_digest.py            # build digest, post (stdout fallback)
    python3 dashboard/nudge_digest.py --dry-run  # build and print only, never post

Scheduling (NOT installed — wire one up yourself if you want it recurring):
  • A session-only recurring command in your LLM CLI (re-arm each session).
  • A cron job / launchd agent that runs this script on a schedule. Note the
    interpreter may need filesystem permission to read your queue root (e.g.
    Full Disk Access on macOS if the queue lives under a synced/cloud folder).
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys

# server.py lives next to this file; sys.path[0] is this script's dir when run
# as `python3 dashboard/nudge_digest.py`, so this import works from any CWD.
import server

CHANNEL = os.environ.get("NUDGE_CHANNEL", "#general")
# Lights (from server.compute_health) that mean "in your court and going stale".
NUDGE_LIGHTS = ("slipping", "stalled")
# Model for the throwaway chat-posting session; opus is overkill for one message.
CLAUDE_MODEL = os.environ.get("NUDGE_CLAUDE_MODEL", "sonnet")


def stalled_projects() -> list[dict]:
    """Active projects in your court whose light is slipping/stalled, worst first."""
    out = [
        p for p in server.all_projects()
        if not p.get("is_archived")
        and (p.get("health") or {}).get("court") == "you"
        and (p.get("health") or {}).get("light") in NUDGE_LIGHTS
    ]
    out.sort(key=lambda p: -((p.get("health") or {}).get("stale_days") or 0))
    return out


def build_digest(projects: list[dict]) -> str:
    n = len(projects)
    header = f"🔔 Project nudge — {n} project{'s' if n != 1 else ''} waiting on you (most stale first):"
    lines = [header]
    for p in projects:
        h = p.get("health") or {}
        light = h.get("light")
        days = h.get("stale_days")
        status = p.get("status") or "?"
        days_str = f"{days}d idle" if days is not None else "idle"
        lines.append(f"• *{p['display_name']}* — {light}, {days_str} (status: {status})")
        nxt = p.get("next_step")
        if nxt:
            lines.append(f"    ↳ Next: {nxt}")
    return "\n".join(lines)


def resolve_claude_bin() -> str | None:
    """Mirror orchestrator.sh: $CLAUDE_BIN, then ~/.local/bin/claude, then PATH."""
    env_bin = os.environ.get("CLAUDE_BIN")
    if env_bin and os.path.isfile(env_bin) and os.access(env_bin, os.X_OK):
        return env_bin
    default = os.path.expanduser("~/.local/bin/claude")
    if os.path.isfile(default) and os.access(default, os.X_OK):
        return default
    return shutil.which("claude")


def post_to_chat(digest: str) -> bool:
    """Post the digest via a headless `claude -p` session. True on success."""
    claude_bin = resolve_claude_bin()
    if not claude_bin:
        print("nudge: `claude` binary not found — falling back to stdout.", file=sys.stderr)
        return False

    prompt = (
        f"Post the following message verbatim to the chat channel {CHANNEL} "
        "using the chat MCP tool (e.g. a Slack tool whose name starts "
        "mcp__..._Slack__ such as slack_send_message; if unsure, search your "
        "tools for 'slack'). Do not summarize, rephrase, or add commentary — "
        "send it exactly as-is. If no chat tool is available, reply with the "
        "single line 'CHAT_UNAVAILABLE' and do nothing else.\n\n"
        "--- MESSAGE START ---\n"
        f"{digest}\n"
        "--- MESSAGE END ---"
    )
    try:
        result = subprocess.run(
            [claude_bin, "-p", prompt, "--dangerously-skip-permissions", "--model", CLAUDE_MODEL],
            capture_output=True, text=True, timeout=240,
        )
    except (subprocess.TimeoutExpired, OSError) as e:
        print(f"nudge: claude invocation failed ({e}) — falling back to stdout.", file=sys.stderr)
        return False

    if result.returncode != 0:
        print(f"nudge: claude exited {result.returncode} — falling back to stdout.", file=sys.stderr)
        if result.stderr.strip():
            print(result.stderr.strip(), file=sys.stderr)
        return False
    if "CHAT_UNAVAILABLE" in (result.stdout or ""):
        print("nudge: chat MCP tool unavailable in the headless session — falling back to stdout.",
              file=sys.stderr)
        return False
    return True


def main() -> int:
    dry_run = "--dry-run" in sys.argv[1:]

    projects = stalled_projects()
    if not projects:
        print("No projects need nudging.")
        return 0

    digest = build_digest(projects)

    if dry_run:
        print(digest)
        return 0

    if post_to_chat(digest):
        print(f"Posted nudge digest ({len(projects)} project(s)) to {CHANNEL}.")
    else:
        print(digest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
