# Understudy

*A calm, file-based autonomous task queue for an LLM agent.*

Drop a folder with an `instructions.md` into the queue. A headless agent picks it
up, does the work — research, drafting, document analysis, real actions — and
leaves behind a `SUMMARY.md` and a rendered `results.html` you can open in your
file previewer (e.g. Finder Quick Look). A local web dashboard shows the state of
every project at a glance. That's the whole idea.

![The Understudy dashboard](docs/dashboard.png)

*The dashboard, on demo data: every project at a glance — whose court the ball is in (health dot), how stale it is, the next step, and quick actions. Queued projects run next; processed ones wait for your input.*

It is deliberately **not** a framework. There is no database, no message broker,
no web service to keep running, no DSL. The unit of work is a folder; the state
lives in Markdown and HTML files you can read, edit, diff, and back up with the
tools you already have. The agent is whatever LLM CLI you point it at (this was
built around [Claude Code](https://claude.com/claude-code)'s headless mode, but
the orchestrator just shells out to a binary — point it elsewhere via
`CLAUDE_BIN`).

## How it works

```
$QUEUE_ROOT/
├── orchestrator.sh        ← scans Projects/, invokes the agent once, headlessly
├── worker-prompt.md       ← the spec the headless agent reads
├── CLAUDE.md              ← architecture + the agent's operating manual
├── dashboard/            ← local web UI (Python stdlib, localhost only)
├── skills/slack-to-queue/← optional: turn Slack messages into queued projects
├── Projects/             ← ALL active projects live here (the only dir scanned)
│   ├── My first project/
│   │   ├── instructions.md   ← you write this. its presence = "process me"
│   │   ├── SUMMARY.md        ← agent writes this. its presence = "processed"
│   │   ├── results.html      ← agent writes this. the actual deliverable
│   │   └── (any inputs you drop in: PDFs, .docx, notes…)
│   └── _example/             ← a synthetic example to copy from
├── Future/               ← parked / someday projects (never scanned)
└── Archive/              ← wrapped-up projects (never scanned)
```

1. **You** create a folder under `Projects/` and drop an `instructions.md`
   describing what you want.
2. The **orchestrator** (`orchestrator.sh`) scans `Projects/` for folders with a
   live `instructions.md`, assembles a worker prompt, and invokes the LLM
   **once, headlessly**, with the queue directory mounted.
3. The **worker** processes each queued folder: reads prior work if any, does the
   task, writes `SUMMARY.md` + `results.html`, optionally posts a notification.
4. On a clean run the orchestrator **archives** the instructions file
   (`instructions.processed-<timestamp>.md`) so the same ask doesn't re-trigger.
5. A **dashboard** (`dashboard/`, a dependency-free Python stdlib server bound to
   localhost) renders the queue: a health light per project, the latest summary,
   the deliverable, and buttons to queue follow-up rounds.

Re-engaging a project is the same gesture: drop a fresh `instructions.md` into a
folder that already has a `SUMMARY.md`, and the agent appends a new "Round N"
section instead of starting over.

## Design principles

- **Files are the database.** Everything is human-readable Markdown/HTML on disk.
  No hidden state. If the tooling vanished, your work would still be there.
- **The folder is the API.** Creating work is `mkdir` + write a file. No commands
  to learn.
- **Proportional, not enterprise.** Plain shell + Python stdlib + Markdown. No
  dependencies to chase.
- **Safe by default, powerful when you mean it.** A kill switch, optional
  per-project policy files, and a discipline of logging every external action.
  See [SECURITY.md](SECURITY.md).

## Safety model (read this before pointing it at a real account)

The worker can take **real actions** (send messages, write files, run web
research) because that's the point. Three controls sit on top:

1. **`.pause`** — a file at the queue root. If present, the orchestrator exits
   without doing anything. The kill switch.
2. **`POLICY.md`** — drop one into any project folder to narrow the agent's
   autonomy for that project ("draft only, never send", "read-only", etc.).
3. **Side-effect logging** — every action with consequences outside the folder
   must be recorded in `SUMMARY.md`. If it isn't logged, treat it as not done.

> ⚠️ The reference orchestrator runs the agent with permission prompts disabled
> (`--dangerously-skip-permissions`) so it can work unattended. That means **the
> agent acts with the full authority of whatever accounts you connect.** Connect
> least-privilege credentials, start with `POLICY.md: read-only` on new projects,
> and watch the logs until you trust it. Full details in
> [SECURITY.md](SECURITY.md).

## Quick start

```bash
git clone <this repo> && cd understudy
cp .env.example .env             # then edit it
# Set at least QUEUE_ROOT to an absolute path. The simplest setup is to use the
# repo itself as the queue root:
export QUEUE_ROOT="$(pwd)"

mkdir -p "$QUEUE_ROOT/Projects/My first project"
echo "Summarize the attached PDF and list three open questions." \
    > "$QUEUE_ROOT/Projects/My first project/instructions.md"

./orchestrator.sh --dry-run      # see what's queued
./orchestrator.sh                # process it
./dashboard/start.sh             # inspect results at http://127.0.0.1:8765
```

`orchestrator.sh` requires `QUEUE_ROOT` and an LLM CLI on `CLAUDE_BIN` (defaults
to `~/.local/bin/claude`). The dashboard reads `QUEUE_ROOT` too, or falls back to
its own parent directory if the `dashboard/` folder lives inside the queue root.

### Scheduling (optional)

Nothing runs on its own by default. To process on a schedule, point cron or a
launchd/systemd timer at `orchestrator.sh`, or use a session-only recurring
command in your LLM CLI. The `.pause` file neutralizes any scheduled run without
unscheduling it. If your queue lives under a synced/cloud folder, the scheduling
interpreter may need filesystem permission to read it (e.g. Full Disk Access on
macOS).

### Slack intake (optional)

`skills/slack-to-queue/` turns messages in a dedicated, single-member Slack
channel into queued projects (top-level message → new project; thread reply →
new round). Set `SLACK_CHANNEL_ID` and `SLACK_USER_ID` (see `.env.example`) and
wire the skill to your Slack MCP. Delete the folder if you don't want it.

## Related work / how this differs

Understudy is a deliberately *small, local-first, file-native* take on autonomous
agents. Compared to:

- **Heavier autonomous-agent frameworks** (AutoGPT/BabyAGI-style) — those keep
  state in their own runtime and chase a goal in a loop. Understudy keeps state in
  plain files on disk and runs the agent **once per drain**, so every result is a
  durable artifact you can read, diff, and back up.
- **Cron + a script** — that's essentially the engine here, but Understudy adds a
  durable project model (rounds, action debriefs, lessons), a safety posture
  (kill switch + per-project policy + side-effect logging), and a dashboard.
- **Hosted "custom agents" inside SaaS tools** — Understudy runs entirely on your
  machine against credentials you control; nothing leaves localhost except the
  agent's own web/MCP calls.

The pitch: if "a folder is a task and Markdown is the database" sounds right to
you, this is a complete, dependency-light implementation of that idea.

## License & attribution

MIT — see [LICENSE](LICENSE). **Fill in `<YOUR NAME>` in `LICENSE`** before
publishing.

## Status

A personal tool, shared in case the pattern is useful. No warranty; expect to
read the code before trusting it with anything that can send messages.
