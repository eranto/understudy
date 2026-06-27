#!/bin/bash
# Understudy — orchestrator for the autonomous project queue.
#
# The queue root holds infrastructure (this script, dashboard/, CLAUDE.md) plus
# three category dirs: Projects/ (active), Future/ (parked), Archive/ (wrapped).
# Only Projects/ is scanned. A folder is "queued" when it contains a live
# instructions.md.
#
# Configuration (environment):
#   QUEUE_ROOT   (required) absolute path to the queue root folder
#   CLAUDE_BIN   (optional) path to your LLM CLI; defaults to ~/.local/bin/claude
#
# Usage:
#   orchestrator.sh            scan queue, invoke headless worker, post-process
#   orchestrator.sh --dry-run  list queued project folders without invoking the LLM
set -u

if [ -z "${QUEUE_ROOT:-}" ]; then
  echo "error: QUEUE_ROOT is not set. Export it to the absolute path of your queue root, e.g.:" >&2
  echo "  export QUEUE_ROOT=\"/path/to/your/queue\"" >&2
  echo "(see .env.example)" >&2
  exit 1
fi

PROJECTS_ROOT="$QUEUE_ROOT"
# Active ("running") projects live under Projects/, parallel to Archive/ and Future/.
ACTIVE_ROOT="$PROJECTS_ROOT/Projects"
# The worker prompt ships next to this script by default; override if you move it.
PROMPT_FILE="${WORKER_PROMPT:-$(cd "$(dirname "$0")" && pwd)/worker-prompt.md}"
LOG_DIR="$PROJECTS_ROOT/.logs"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"

ts() { # ISO-8601 with colon in offset, e.g. 2026-06-11T18:08:13+03:00
  local t; t=$(date +%Y-%m-%dT%H:%M:%S%z)
  echo "${t:0:22}:${t:22}"
}

[ -d "$PROJECTS_ROOT" ] || { echo "[$(ts)] Queue root not readable: $PROJECTS_ROOT"; exit 1; }
[ -f "$PROMPT_FILE" ] || { echo "[$(ts)] Worker prompt not found: $PROMPT_FILE (set WORKER_PROMPT)"; exit 1; }
# The three category dirs hold the queue's data and are gitignored, so a fresh
# clone / new queue root won't have them — create them on first run.
mkdir -p "$ACTIVE_ROOT" "$PROJECTS_ROOT/Archive" "$PROJECTS_ROOT/Future"
mkdir -p "$LOG_DIR"
find "$LOG_DIR" -name "*.log" -mtime +30 -delete 2>/dev/null

if [ -e "$PROJECTS_ROOT/.pause" ]; then
  echo "[$(ts)] .pause file present — exiting without running."
  exit 0
fi

# A folder is queued if it directly contains a live instructions file:
# any name ending in "instructions.md" (case-insensitive), excluding archived
# *.processed-* records. We scan Projects/ (active projects only); Archive/ and
# Future/ are separate sibling dirs and are never scanned. Dot-folders skipped.
list_instructions() { # $1 = project dir
  find "$1" -maxdepth 1 -iname "*instructions.md" ! -iname "*processed*" 2>/dev/null
}

candidates=()
if [ -d "$ACTIVE_ROOT" ]; then
  while IFS= read -r -d '' dir; do
    name=$(basename "$dir")
    case "$name" in .*) continue ;; esac
    if [ -n "$(list_instructions "$dir" | head -1)" ]; then
      candidates+=("$name")
    fi
  done < <(find "$ACTIVE_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
fi

if [ ${#candidates[@]} -eq 0 ]; then
  echo "[$(ts)] Queue empty — nothing to process."
  exit 0
fi

echo "[$(ts)] Unprocessed (${#candidates[@]}):"
for name in "${candidates[@]}"; do echo "  - $name"; done

if [ "${1:-}" = "--dry-run" ]; then
  echo "[$(ts)] Dry run — not invoking the LLM."
  exit 0
fi

# Assemble the worker prompt: static spec + queue section.
PROMPT_OUT="$LOG_DIR/last-prompt.md"
{
  cat "$PROMPT_FILE"
  echo
  echo "## Projects to process (each contains instructions.md)"
  echo
  for name in "${candidates[@]}"; do echo "- Projects/$name"; done
} > "$PROMPT_OUT"

RUN_LOG="$LOG_DIR/$(date +%Y-%m-%d_%H-%M-%S).log"
echo "[$(ts)] Invoking the LLM — log: $RUN_LOG"

cd "$PROJECTS_ROOT" || exit 1
"$CLAUDE_BIN" -p "$(cat "$PROMPT_OUT")" \
  --add-dir "$PROJECTS_ROOT" \
  --dangerously-skip-permissions \
  --model opus >> "$RUN_LOG" 2>&1
status=$?
echo "[$(ts)] LLM exited with status $status" >> "$RUN_LOG"

if [ $status -ne 0 ]; then
  echo "[$(ts)] Worker failed (status $status) — skipping post-processing; queue will re-trigger." | tee -a "$RUN_LOG"
  exit $status
fi

# Post-process each candidate: only if the worker actually wrote SUMMARY.md
# (idempotent — a no-op folder stays queued and self-heals next run).
stamp=$(date +%Y%m%d-%H%M)
for name in "${candidates[@]}"; do
  dir="$ACTIVE_ROOT/$name"
  final="Projects/$name"
  [ -d "$dir" ] || { echo "[$(ts)] Folder vanished mid-run, skipping: $name" >> "$RUN_LOG"; continue; }
  [ -f "$dir/SUMMARY.md" ] || { echo "[$(ts)] No SUMMARY.md in $name — left queued." >> "$RUN_LOG"; continue; }

  # "Processed" is signalled by the presence of SUMMARY.md (written above).

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base=$(basename "$f")
    newname="${base%.md}.processed-$stamp.md"
    if mv "$f" "$dir/$newname"; then
      echo "[$(ts)] Archived instructions: $final/$newname" >> "$RUN_LOG"
    fi
  done < <(list_instructions "$dir")
done

exit 0
