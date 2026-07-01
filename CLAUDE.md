# CLAUDE.md — Understudy

This file is the authoritative spec for **Understudy**, an autonomous,
file-based project queue driven by an LLM agent. It is read by the headless
worker on every run, so it doubles as the agent's operating manual. (If you run
the worker with a Claude Code-style harness, that harness loads this file
automatically; otherwise the worker prompt points the agent at it.)

## What this is

An **autonomous project queue**. Active ("running") projects each live as a
subfolder of **`Projects/`** (a folder at the queue root, parallel to `Archive/`
and `Future/`). Folder names are free-form — some are named after a person, some
after a topic; the name carries no semantic weight to the system. The owner
creates a folder per project **inside `Projects/`**, drops an `instructions.md`
file inside (plus any supporting documents — correspondence, Word docs, PDFs),
and the orchestrator (`orchestrator.sh`) scans `Projects/` for folders containing
an `instructions.md` and invokes the LLM headlessly to process them.

The queue root holds only infrastructure (`CLAUDE.md`, `dashboard/`, `.logs/`,
the orchestrator and worker prompt) and the three category dirs: `Projects/`
(active), `Future/` (parked), `Archive/` (wrapped).

> **Terminology.** The system is named **Understudy** (it does the prep and
> stands in for you). The units of work are **projects** (each subfolder of
> `Projects/` is one); the system is the **project queue**.

This is **not a code repository**. There is no build, no test suite, no lint.
Work happens in human-language artifacts (drafts, research, document analysis).

## The project-folder convention

**The trigger for processing is the presence of `instructions.md` inside a
project folder under `Projects/`** (case-insensitive — `Instructions.md`,
`INSTRUCTIONS.md` all work; any filename *ending* in `instructions.md` counts as a
live trigger). Nothing else triggers a run. A folder with no `instructions.md` is
idle, regardless of its name or contents.

After a successful run, the orchestrator renames the instructions file to
`instructions.processed-YYYYMMDD-HHMM.md`, so the same instructions don't
re-trigger on the next run.

**"Processed at least once" is signalled by the presence of `SUMMARY.md`** in the
folder — not by the folder name. The dashboard's project-health light is the
at-a-glance state signal (see the Dashboard section).

### The full lifecycle

- **New project.** Create `Projects/<name>/` and drop `instructions.md` inside.
  The next run picks it up → produces `SUMMARY.md` + `results.html` → the
  instructions file is archived. The folder now has a `SUMMARY.md` (= processed)
  and shows under "In your court" on the dashboard.
  - **Via the dashboard.** The "+ New project" button creates the folder and
    `instructions.md` for you.
  - **Via Slack** (optional `slack-to-queue` skill). A top-level message you type
    in your dedicated channel opens a fresh `Projects/<folder>/` with the message
    as the ask. See the Slack section below.
- **Next round of work.** Drop a fresh `instructions.md` into the (already
  processed) folder. The next run reads the existing `SUMMARY.md` first to ground
  itself, then the new instructions, then **appends** a `## Round N — YYYY-MM-DD`
  section to the existing `SUMMARY.md` and updates `results.html`. The new
  instructions file is archived the same way.
  - **Round numbering.** Scan the existing `SUMMARY.md` for `## Round X — ...`
    headers and use the next integer. If `SUMMARY.md` exists with no `## Round`
    headers at all, the original processing was implicitly Round 1, so this run is
    Round 2.
  - **Via Slack.** A reply you post inside a worker summary's thread becomes a new
    round on that matched project.
- **Action debrief.** After acting on a deliverable in the real world, record
  *what you did* via the dashboard's "Record action" button. That appends a dated
  entry to `ACTIONS.md` in the project folder (dashboard-written input — the
  worker never modifies it) and generates an `instructions.md` whose first line is
  the marker `<!-- action-debrief -->`. The next run recognizes the marker and,
  instead of normal work, appends a dated lessons section to a cumulative
  `LESSONS.md`, adds only a one-line `## Round N — date (action debrief)` stub to
  `SUMMARY.md`, and updates the frontmatter. The full analysis lives in
  `LESSONS.md`.
- **Dismissal.** Delete, archive, or park the folder when the project is done.
- **Fully reprocess from scratch** (rare): delete `SUMMARY.md` (and
  `results.html`) and drop a fresh `instructions.md` — with no `SUMMARY.md`, the
  run treats it as first-time processing.

**Read order for any run on a folder that already has `SUMMARY.md`:** existing
`SUMMARY.md` first (to ground yourself in prior rounds and decisions), then the
new `instructions.md`, then any other inputs in the folder. **Append, don't
rewrite** — earlier rounds are durable history.

When you process a project folder, produce:

- **`SUMMARY.md`** at the folder root, with YAML frontmatter:
  ```yaml
  ---
  status: done | in-progress | needs-input
  last_processed: 2026-01-01T14:00:00+00:00
  processed_by_claude: true
  ---
  ```
  Body sections: *What was asked*, *What I did*, *Side effects* (any external
  actions — messages sent, files created outside this folder), *What's left /
  blockers*, *Next stages*.
  - `done` — **the default.** Use this whenever the owner can act on the
    deliverable as-is, even if a follow-up round could refine it.
  - `needs-input` — you got as far as you could; the owner must decide or respond
    before more progress is possible.
  - `in-progress` — partial work, will be resumed next run. Avoid this for the
    final write unless you genuinely intend the next run to pick up where you left
    off; otherwise prefer `needs-input`.

- **`results.html`** — the actual deliverable, rendered for a file previewer (no
  Word/PDF round-trip needed to skim). If the task is multi-part, lay it out
  side-by-side here.

- **`LESSONS.md`** (only on action-debrief rounds) — cumulative, **append-only**
  lessons file. Dated sections `## YYYY-MM-DD — <short label>`, each with *Action
  taken*, *Lessons*, *Implications for future rounds*. Never rewrite or reorder
  prior sections.

- **`drafts/`** (optional) — any document drafts you produced.

- **Notification** (optional) — if a chat MCP is available, post a per-project
  summary to your channel: folder name, final `status`, one-sentence restatement
  of the ask, 1–2 sentences on what you did, and any side effects worth flagging.
  For re-engagements, lead with `Round N — <folder>`. Log the post itself under
  *Side effects* in `SUMMARY.md`. If no chat tool is available, log `Notification
  skipped` and continue — don't fail the project over it.

**Never modify or move existing input files** in a project folder. Ignore Word
lock files (`~$*.docx`). The archived `instructions.processed-*.md` files are
off-limits — they're history. So is `ACTIONS.md` — it's written exclusively by
the dashboard.

## Autonomy and guardrails

Default posture: **full execution**. The worker may take real actions (send
messages via a connected MCP, create files, run research). Three constraints sit
on top:

1. **`.pause` file** at the queue root → the orchestrator exits without invoking
   the worker. This is the kill switch.
2. **`POLICY.md` inside a project folder** → the worker reads it before acting. It
   can narrow autonomy for that project ("draft only, don't send", "read-only",
   etc.). A per-project policy always wins over the default.
3. **Side effects** — any action with consequences outside the project folder
   (message sent, file written elsewhere) must be logged in `SUMMARY.md` under
   *Side effects*. If it's not logged, it didn't happen.

## Reading inputs

- `.docx` → `textutil -convert txt -stdout "file.docx"` (macOS) or an equivalent.
- `.pdf` → `pdftotext -layout "file.pdf" -`.

## What "done" looks like

Project state is read from folder contents (the **dashboard** renders it as a
health light per project):
- **Has `SUMMARY.md`, no live `instructions.md`** — processed at least once,
  currently idle, waiting on the owner's next move. The dashboard puts these
  under "In your court".
- **Has a live `instructions.md`** — queued for the next run.
- **No `instructions.md` and no `SUMMARY.md`** — under assembly; the owner is
  still preparing it.

## Operating the queue

- **First-run setup.** For a new install, follow **`SETUP.md`** — a short guided
  flow that asks the user a few preferences and writes `.env` + `config.json`.
- **Configuration.** Paths/secrets come from the environment — the orchestrator
  reads the queue root from `QUEUE_ROOT` and the LLM CLI path from `CLAUDE_BIN`
  (optional; defaults to `~/.local/bin/claude`); see `.env.example`. Behavior
  **preferences** (staleness thresholds that drive the health lights and the
  dashboard's "Needs attention" filter) come from an optional `config.json` at
  the queue root; see `config.example.json`. A missing `config.json` = built-in
  defaults (today's behavior).
- **Orchestrator:** `orchestrator.sh`
  - Manual drain: `QUEUE_ROOT=/path/to/queue ./orchestrator.sh`
  - `--dry-run` lists the queue without invoking the LLM.
  - Logs to `.logs/<timestamp>.log`; the last assembled prompt is in
    `.logs/last-prompt.md` (useful for debugging what the headless worker saw).
  - Every run invokes the LLM CLI as a fresh headless session with
    `--add-dir <queue root> --dangerously-skip-permissions --model opus`.
  - **Idempotent post-processing.** The `instructions.processed-<stamp>.md`
    archive only happens after a clean exit *and* if `SUMMARY.md` exists in the
    folder. If the worker no-ops (no `SUMMARY.md`), the folder stays queued and
    the same `instructions.md` re-triggers next run — partial/failed runs
    self-heal.
- **Worker prompt:** `worker-prompt.md` — the spec the headless worker reads. Edit
  this to change processing behavior across all projects.
- **Scheduling (optional).** Nothing runs on its own by default. To process on a
  schedule, run `orchestrator.sh` from cron or a launchd/systemd timer, or use a
  session-only recurring command in your LLM CLI. If the queue lives under a
  synced/cloud folder, the scheduling interpreter may need filesystem permission
  to read it (e.g. Full Disk Access on macOS).

## Slack intake (optional)

The `slack-to-queue` skill turns activity in a dedicated, single-member Slack
channel into queue work — a second intake surface alongside the dashboard. Two
modes:

- **Top-level message → NEW project.** A message you type directly in the channel
  opens a fresh `Projects/<folder>/` with the message as the ask.
- **Thread reply → NEW round.** A reply in a worker summary's thread becomes a
  round on that matched project. Replies on archived/parked projects are flagged,
  not auto-resurrected.

The trust boundary is *sole channel member + a footer on machine posts*: the
worker's own summary messages carry a `Sent using Claude` footer, so anything
**without** the footer is something you typed by hand. A ✅ reaction marks each
item ingested-once. Configure the channel id and your user id in
`skills/slack-to-queue/SKILL.md` (placeholders `<SLACK_CHANNEL_ID>` and
`<YOUR_SLACK_USER_ID>`). If you don't want a Slack surface, ignore or delete the
skill.

## Dashboard

A local web UI for inspecting and managing the queue lives in `dashboard/`.
Launch with `./dashboard/start.sh` — binds to `http://127.0.0.1:8765/` (loopback
only) and opens the browser. **`server.py` does not hot-reload** — after editing
it, kill the running server and relaunch. Free a stuck port with
`lsof -tiTCP:8765 -sTCP:LISTEN | xargs kill`, then re-run `start.sh`.

The server reads the queue live and exposes endpoints for listing projects,
viewing each project's `SUMMARY.md` / `results.html` / `ACTIONS.md` /
`LESSONS.md`, creating new projects, queuing follow-up rounds, recording
real-world actions (appends to `ACTIONS.md` and queues an action-debrief round),
renaming, and archiving/unarchiving/parking folders. The dashboard reads its
queue root from `QUEUE_ROOT`, or — if unset — assumes it lives inside the queue
root (`<queue-root>/dashboard/`).

**Project-health signal.** The dashboard shows a status light per project,
computed live from existing data. Two axes: *whose court the ball is in* (a
pending `instructions.md` = queued/the LLM's court; `done`/`needs-input` with no
pending instructions = your court) and *how stale* (days since the most recent of
`last_processed` / latest `ACTIONS.md` entry). In your court: active (<2d), your
move (2–5d), slipping (5–10d), stalled (≥10d). A momentum read (rounds + actions
in the trailing 28d) shows cadence. The "In your court" section has a Sort button
(Best / New first / Old first; choice persisted in `localStorage`).

**Archive & Future conventions.** "Archive a project" = move the folder from
`Projects/` into `Archive/` (use instead of deletion to preserve history).
**"Move to Future"** = move it into `Future/`, a parking lot for someday/maybe
projects. Both are siblings of `Projects/` at the queue root, and **neither is
ever scanned** by the orchestrator — nothing in them triggers a run.

Nudging is surfaced **in the dashboard**, not as a separate process: the "In your
court" section has a **Needs attention** toggle that filters to the projects
whose health light is `slipping` or `stalled`. (There is no standalone digest.)

## Layout

```
<queue root>/                                  ($QUEUE_ROOT)
├── CLAUDE.md                                  (this file)
├── orchestrator.sh                            (scans Projects/, invokes the worker)
├── worker-prompt.md                           (the headless worker's spec)
├── .env.example                               (config template: QUEUE_ROOT, CLAUDE_BIN, …)
├── .logs/                                     (run logs, pruned >30 days)
├── .pause                                     (optional kill switch; absent by default)
├── dashboard/                                 (local web UI; not a queue project)
│   ├── server.py                              (Python stdlib HTTP server, 127.0.0.1:8765)
│   ├── index.html                             (single-page UI)
│   └── start.sh                               (launcher)
├── skills/
│   └── slack-to-queue/                        (optional Slack intake)
│       ├── SKILL.md
│       └── create_queue_item.py
├── Projects/                                  (ALL active projects — the only dir scanned)
│   ├── <project>/
│   │   ├── instructions.md                    (input; presence = "process me")
│   │   ├── SUMMARY.md                         (produced; presence = "processed")
│   │   ├── results.html                       (produced; the deliverable)
│   │   ├── ACTIONS.md                         (dashboard-written; actions you took)
│   │   ├── LESSONS.md                         (produced on action-debrief rounds)
│   │   ├── POLICY.md                          (optional, per-project constraints)
│   │   └── drafts/                            (optional drafts)
│   └── _example/                              (synthetic example shipped with the repo)
├── Future/                                    (parked/someday projects; never scanned)
└── Archive/                                   (wrapped-up projects; never scanned)
```

To kick off another round on an already-processed folder, drop a fresh
`instructions.md` into it (inside `Projects/<folder>/`).
