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

- **`QUEUE_ROOT`** *(required)* — where the queue's data lives (`Projects/`,
  `Archive/`, `Future/`). Ask the user which they want:
    - **Create a new queue folder** *(default)* — suggest a path like `~/Understudy`
      (or the cloned repo dir, `pwd`); it's created if missing.
    - **Connect to an existing queue folder** — take their path (e.g. a folder
      already holding `Projects/`, or a Drive-synced location). Missing
      `Projects/`/`Archive/`/`Future/` are auto-created on first run, so pointing
      at an existing directory just works.

  Write the chosen absolute path to `QUEUE_ROOT`.
- **`CLAUDE_BIN`** *(optional)* — path to the LLM CLI. Default `~/.local/bin/claude`;
  set it if `command -v claude` shows a different path.
- **`DASHBOARD_PORT`** *(optional)* — default `8765`. Only ask if they want a
  different port.

(Slack intake vars exist in `.env.example` but are optional — only set them if
the user wants Slack intake; skip otherwise.)

## Step 2 — Preferences → `config.json`

Copy `config.example.json` to `config.json`, then ask about **staleness
thresholds** — how many days a project can sit waiting on the user before the
dashboard escalates its status light. Defaults: **your-move at 2 days, slipping
at 5, stalled at 10**. Offer the defaults; accept custom numbers. Write to
`health_days.{move, slip, stalled}`.

> Explain: a project < `move` days idle shows green, < `slip` amber, < `stalled`
> orange, and ≥ `stalled` red. These same cutoffs drive the dashboard's "Needs
> attention" filter (slipping + stalled). The "in your court" list has a single
> fixed order — newest / just-drained first — so there's no sort setting to pick.

## Step 3 — Create the queue structure

The category dirs (`Projects/`, `Future/`, `Archive/`) hold your queue's data and
are gitignored, so a fresh clone won't contain them. **You don't need to create
them by hand** — both the orchestrator (`orchestrator.sh`) and the dashboard
(`dashboard/server.py`) create any that are missing under `QUEUE_ROOT` on startup
(and `.logs/` too). To pre-create them explicitly anyway:

```bash
mkdir -p "$QUEUE_ROOT/Projects" "$QUEUE_ROOT/Future" "$QUEUE_ROOT/Archive" "$QUEUE_ROOT/.logs"
```

## Step 4 — How often to run the queue

Ask **how often the queue should be drained**, offering four choices:

| Choice | cron | launchd `StartInterval` (sec) |
|--------|------|-------------------------------|
| Every 15 minutes | `*/15 * * * *` | 900 |
| Every 30 minutes | `*/30 * * * *` | 1800 |
| Every hour *(sensible default)* | `0 * * * *` | 3600 |
| Every 2 hours | `0 */2 * * *` | 7200 |

Nothing runs on its own until this is set up. Once they pick a cadence, **offer**
to install a schedule that runs `orchestrator.sh` at that interval — and only do
it after they say yes (it touches the OS scheduler):

- **macOS (launchd)** — write a plist to `~/Library/LaunchAgents/` and
  `launchctl load` it (use the `StartInterval` seconds from the table):

  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0"><dict>
    <key>Label</key><string>com.understudy.drain</string>
    <key>ProgramArguments</key>
    <array>
      <string>/bin/bash</string><string>-lc</string>
      <string>QUEUE_ROOT="<QUEUE_ROOT>" "<QUEUE_ROOT>/orchestrator.sh"</string>
    </array>
    <key>StartInterval</key><integer><SECONDS></integer>
    <key>StandardOutPath</key><string><QUEUE_ROOT>/.logs/drain.out</string>
    <key>StandardErrorPath</key><string><QUEUE_ROOT>/.logs/drain.err</string>
  </dict></plist>
  ```
  Note: a cloud-synced `QUEUE_ROOT` may require Full Disk Access for `/bin/bash`.

- **Linux (cron)** — add a crontab line (cron expression from the table):

  ```cron
  */30 * * * *  QUEUE_ROOT="<QUEUE_ROOT>" "<QUEUE_ROOT>/orchestrator.sh" >> "<QUEUE_ROOT>/.logs/drain.log" 2>&1
  ```

- **Session-only** — if the user keeps an LLM CLI session open, they can instead
  arm a recurring in-session command at the chosen interval (re-armed each
  session) rather than an OS job.

(If Slack/email intake is enabled, run those intake steps on the same schedule,
just before the drain.)

## Step 5 — Launch and verify

```bash
./dashboard/start.sh            # opens http://127.0.0.1:<port>
QUEUE_ROOT="$QUEUE_ROOT" ./orchestrator.sh --dry-run   # should print "Queue empty" on a fresh install
```

Confirm with the user that the dashboard opens and the header looks right. The
"in your court" list shows newest / just-drained first, with a **Needs attention**
toggle that filters to the slipping + stalled projects.

## Done

Recap what you wrote (`.env`, `config.json`, dirs, and the schedule + its
interval). Point them at `README.md` (day-to-day use) and `CLAUDE.md` (how the
agent operates). They can re-run this flow any time to change preferences.
