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
# How many project folders to process concurrently (each gets its own headless
# worker). Overridable via env; kept modest so a burst doesn't hit API rate limits.
CONCURRENCY="${UNDERSTUDY_CONCURRENCY:-3}"

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

# Clear any stale "processing" markers left by a crashed prior run.
rm -f "$LOG_DIR/active/"* 2>/dev/null
mkdir -p "$LOG_DIR/active"

# A folder is queued if it directly contains a live instructions file:
# any name ending in "instructions.md" (case-insensitive), excluding archived
# *.processed-* records. We scan Projects/ (active projects only); Archive/ and
# Future/ are separate sibling dirs and are never scanned. Dot-folders skipped.
list_instructions() { # $1 = project dir
  find "$1" -maxdepth 1 -iname "*instructions.md" ! -iname "*processed*" 2>/dev/null
}

# Run one headless worker for a SINGLE project folder, with a prompt scoped to
# just that folder and its own log file, so several can run concurrently without
# colliding. $1 = folder name, $2 = unique launch index (keeps filenames distinct).
run_worker() {
  local name="$1" n="$2"
  local slug; slug=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')
  local prompt_file="$LOG_DIR/last-prompt-$n-$slug.md"
  local run_log="$LOG_DIR/$(date +%Y-%m-%d_%H-%M-%S)-$n-$slug.log"
  {
    cat "$PROMPT_FILE"
    echo
    echo "## Projects to process (each contains instructions.md)"
    echo
    echo "- Projects/$name"
  } > "$prompt_file"
  echo "[$(ts)] [$name] invoking worker — log: $run_log"
  # Mark this folder as actively processing so the dashboard can show it; remove
  # the marker when the worker returns. The marker's contents are the exact folder
  # name (filename is $n-$slug, unique per launch).
  mkdir -p "$LOG_DIR/active"
  printf '%s' "$name" > "$LOG_DIR/active/$n-$slug"
  "$CLAUDE_BIN" -p "$(cat "$prompt_file")" \
    --add-dir "$PROJECTS_ROOT" \
    --dangerously-skip-permissions \
    --model opus >> "$run_log" 2>&1
  echo "[$(ts)] [$name] worker exited with status $?" >> "$run_log"
  rm -f "$LOG_DIR/active/$n-$slug"
}

# Drain in passes until a scan finds no fresh candidates. A project added while
# a pass is running (e.g. created from the dashboard during another drain, which
# the in-flight guard makes defer) is caught by the next pass instead of being
# orphaned until the next trigger. Guard: track folders attempted this
# invocation so a no-op folder (worker wrote no SUMMARY.md) isn't retried in an
# infinite loop; MAX_PASSES is a hard backstop.
# (Newline-delimited string, not an associative array — macOS /bin/bash is 3.2.)
attempted=$'\n'
MAX_PASSES=10
pass=0

while : ; do
  pass=$((pass + 1))

  candidates=()
  if [ -d "$ACTIVE_ROOT" ]; then
    while IFS= read -r -d '' dir; do
      name=$(basename "$dir")
      case "$name" in .*) continue ;; esac
      case "$attempted" in *$'\n'"$name"$'\n'*) continue ;; esac   # don't retry within this run
      if [ -n "$(list_instructions "$dir" | head -1)" ]; then
        candidates+=("$name")
      fi
    done < <(find "$ACTIVE_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
  fi

  if [ ${#candidates[@]} -eq 0 ]; then
    [ $pass -eq 1 ] && echo "[$(ts)] Queue empty — nothing to process."
    break
  fi

  echo "[$(ts)] Pass $pass — unprocessed (${#candidates[@]}):"
  for name in "${candidates[@]}"; do echo "  - $name"; done

  if [ "${1:-}" = "--dry-run" ]; then
    echo "[$(ts)] Dry run — not invoking the LLM."
    exit 0
  fi

  # Mark this pass's candidates attempted before running, so a no-op folder
  # (no SUMMARY.md written) isn't rescanned into an endless loop.
  for name in "${candidates[@]}"; do attempted="$attempted$name"$'\n'; done

  # Process the candidates in parallel, CONCURRENCY at a time: one headless worker
  # per folder. macOS /bin/bash is 3.2 (no `wait -n`), so we run fixed-size
  # batches — launch up to CONCURRENCY workers, wait for all, then the next batch.
  # An individual worker failing does NOT abort the others; its folder simply gets
  # no SUMMARY.md, stays queued, and self-heals on the next run.
  echo "[$(ts)] Processing ${#candidates[@]} project(s), up to $CONCURRENCY in parallel."
  cd "$PROJECTS_ROOT" || exit 1
  total=${#candidates[@]}
  idx=0
  launch=0
  while [ $idx -lt $total ]; do
    pids=()
    for name in "${candidates[@]:idx:CONCURRENCY}"; do
      launch=$((launch + 1))
      run_worker "$name" "$launch" &
      pids+=("$!")
    done
    wait "${pids[@]}"
    idx=$((idx + CONCURRENCY))
  done

  # Post-process each candidate: only if its worker actually wrote SUMMARY.md
  # (idempotent — a no-op folder stays queued and self-heals next run).
  stamp=$(date +%Y%m%d-%H%M)
  for name in "${candidates[@]}"; do
    dir="$ACTIVE_ROOT/$name"
    final="Projects/$name"
    [ -d "$dir" ] || { echo "[$(ts)] Folder vanished mid-run, skipping: $name"; continue; }
    [ -f "$dir/SUMMARY.md" ] || { echo "[$(ts)] No SUMMARY.md in $name — left queued (will re-trigger)."; continue; }

    # "Processed" is signalled by the presence of SUMMARY.md.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      base=$(basename "$f")
      newname="${base%.md}.processed-$stamp.md"
      if mv "$f" "$dir/$newname"; then
        echo "[$(ts)] Archived instructions: $final/$newname"
      fi
    done < <(list_instructions "$dir")
  done

  if [ $pass -ge $MAX_PASSES ]; then
    echo "[$(ts)] Reached max passes ($MAX_PASSES) — stopping; any remainder re-triggers next run."
    break
  fi
done

exit 0
