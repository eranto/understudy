# Understudy — guided first-run setup

**You are a coding agent (Claude Code, Codex, or similar) helping someone set up
Understudy.** Don't just run commands silently — *walk the user through a short
configuration*, ask the questions below conversationally (offer the recommended
default for each so they can just say "yes"), then write the files. Keep it to a
few minutes. Everything here is idempotent: safe to re-run.

Understudy needs two things on disk:
- **`.env`** — paths/secrets (read from the environment by `orchestrator.sh` and
  `dashboard/server.py`). Copy from `.env.example`.
- **`config.json`** — behavior preferences (read by the dashboard + nudge).
  Copy from `config.example.json`. Absent = built-in defaults.

Both are gitignored — they're per-install, never committed.

---

## Step 0 — Prerequisites

- `python3` available (`python3 --version`).
- An LLM CLI installed (e.g. `claude`). Find its path (`command -v claude` or
  `which claude`); the default assumed is `~/.local/bin/claude`.

If either is missing, tell the user how to install it and stop here.

## Step 1 — Required settings → `.env`

Copy `.env.example` to `.env`, then fill in (ask the user, suggest the default):

- **`QUEUE_ROOT`** *(required)* — absolute path to the queue root. **Default: the
  cloned repo directory itself** (`pwd`). Confirm or take their path.
- **`CLAUDE_BIN`** *(optional)* — path to the LLM CLI. Default `~/.local/bin/claude`;
  set it if `command -v claude` shows a different path.
- **`DASHBOARD_PORT`** *(optional)* — default `8765`. Only ask if they want a
  different port.

(Slack intake vars exist in `.env.example` but are optional — only set them if
the user wants Slack intake; skip otherwise.)

## Step 2 — Preferences → `config.json`

Copy `config.example.json` to `config.json`, then ask these two and write the
answers. Lead with the recommended default.

1. **Default project sort** — how the dashboard orders the "in your court"
   projects by default:
   - `smart` — **Best** *(recommended)*: floats the things that most need you
     (blocked / stale-but-actionable) to the top.
   - `new` — Newest activity first.
   - `old` — Oldest / most-stalled first (a strict "you're the bottleneck" view).
   Write to `default_sort`.

2. **Staleness thresholds** — how many days a project can sit waiting on the user
   before the dashboard escalates its status light (and, if nudges are on, before
   it gets nagged). Defaults: **your-move at 2 days, slipping at 5, stalled at 10**.
   Offer the defaults; accept custom numbers. Write to
   `health_days.{move, slip, stalled}`.

   > Explain: a project < `move` days idle shows green, < `slip` amber, <
   > `stalled` orange, and ≥ `stalled` red. These same cutoffs decide what the
   > nudge digest flags.

## Step 3 — Nudges (light touch)

A "nudge" is a digest of projects that have gone stale in the user's court,
posted to a chat channel (or printed). Ask:

- **Enable nudges?** (default: no). If no, leave `nudge.enabled = false` and skip
  to Step 4.
- If yes:
  - **Channel** — e.g. a Slack channel like `#understudy`. Write `nudge.channel`.
    (Requires a chat MCP tool available to the LLM CLI; otherwise the digest
    prints to stdout.)
  - **Cadence** — when to run it, as a cron expression. Suggest weekday mornings:
    `0 9 * * 1-5`. Write `nudge.cadence`.
  - Leave `nudge.lights` at `["slipping","stalled"]` unless they ask to also be
    nudged earlier (add `"move"`).

The digest reuses the Step 2 thresholds — no separate staleness config.

## Step 4 — Create the queue structure

The category dirs (`Projects/`, `Future/`, `Archive/`) hold your queue's data and
are gitignored, so a fresh clone won't contain them. **You don't need to create
them by hand** — both the orchestrator (`orchestrator.sh`) and the dashboard
(`dashboard/server.py`) create any that are missing under `QUEUE_ROOT` on startup
(and `.logs/` too). To pre-create them explicitly anyway:

```bash
mkdir -p "$QUEUE_ROOT/Projects" "$QUEUE_ROOT/Future" "$QUEUE_ROOT/Archive" "$QUEUE_ROOT/.logs"
```

## Step 5 — Offer to install a schedule

Nothing runs on its own by default. If the user enabled nudges (or wants the
queue drained automatically), **offer** to install a schedule — and only do it
after they say yes (it touches the OS scheduler).

- **macOS (launchd)** — write a plist to `~/Library/LaunchAgents/` and
  `launchctl load` it. Template (fill in `<…>`; use the cadence from Step 3):

  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0"><dict>
    <key>Label</key><string>com.understudy.nudge</string>
    <key>ProgramArguments</key>
    <array>
      <string>/bin/bash</string><string>-lc</string>
      <string>QUEUE_ROOT="<QUEUE_ROOT>" python3 "<QUEUE_ROOT>/dashboard/nudge_digest.py"</string>
    </array>
    <key>StartCalendarInterval</key><dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
    <key>StandardOutPath</key><string><QUEUE_ROOT>/.logs/nudge.out</string>
    <key>StandardErrorPath</key><string><QUEUE_ROOT>/.logs/nudge.err</string>
  </dict></plist>
  ```
  Note: a cloud-synced `QUEUE_ROOT` may require Full Disk Access for `/bin/bash`.

- **Linux (cron)** — add a crontab line (cadence from Step 3). To drain the queue
  instead of nudging, point at `orchestrator.sh`:

  ```cron
  0 9 * * 1-5  QUEUE_ROOT="<QUEUE_ROOT>" python3 "<QUEUE_ROOT>/dashboard/nudge_digest.py" >> "<QUEUE_ROOT>/.logs/nudge.log" 2>&1
  ```

- **Session-only** — if the user runs an LLM CLI session anyway, they can arm a
  recurring in-session command (re-armed each session) instead of an OS job.

## Step 6 — Launch and verify

```bash
./dashboard/start.sh            # opens http://127.0.0.1:<port>
QUEUE_ROOT="$QUEUE_ROOT" ./orchestrator.sh --dry-run   # should print "Queue empty" on a fresh install
```

Confirm with the user that the dashboard opens, the header looks right, and the
"in your court" list is sorted the way they chose. If they enabled nudges, run
`python3 dashboard/nudge_digest.py --dry-run` to show a sample (empty on a fresh
install).

## Done

Recap what you wrote (`.env`, `config.json`, dirs, any schedule). Point them at
`README.md` (day-to-day use) and `CLAUDE.md` (how the agent operates). They can
re-run this flow any time to change preferences — it just rewrites `config.json`.
