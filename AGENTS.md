# Agent guide

Entry point for coding agents (Codex, Claude Code, and others) working with this
repo.

- **Setting it up for someone?** Follow **`SETUP.md`** — a short guided first-run
  flow: it has you ask the user a few questions (default project sort, staleness
  thresholds, optional nudges) and then write `.env` + `config.json`, create the
  queue folders, and optionally install a schedule. Walk the user through it
  conversationally; don't run it silently.

- **Operating or modifying it?** **`CLAUDE.md`** is the authoritative spec — the
  project-folder convention, the `SUMMARY.md`/`results.html` contract, the
  autonomy/guardrail model (`.pause`, per-project `POLICY.md`), and how the
  headless worker runs. It is also the prompt the worker reads on every run.

- **Using it day to day?** See **`README.md`**.

Configuration lives in two files at the queue root: `.env` (paths/secrets) and
`config.json` (preferences — see `config.example.json`). Both are gitignored.
