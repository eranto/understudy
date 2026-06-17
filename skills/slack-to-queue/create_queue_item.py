#!/usr/bin/env python3
"""Create a new project folder in the Understudy project queue.

Mirrors the validation in dashboard/server.py (_handle_new_project) so a folder
created here is a valid queue entry, but is self-contained (no running server
required). Used by the `slack-to-queue` skill to drop a Slack message into the
queue as a new project, and usable standalone too.

The queue root is read from the QUEUE_ROOT environment variable (the absolute
path of your queue root folder; see .env.example).

Usage:
    QUEUE_ROOT=/path/to/queue create_queue_item.py \
        --name "Compare contracts" \
        --instructions-file /tmp/instr.md \
        [--attach /path/to/file.pdf ...]

On success, prints the absolute path of the created folder to stdout.
Folder name collisions auto-suffix " (2)", " (3)", ... — this always creates a
NEW project, so unlike the dashboard it never errors on an existing name.
"""
import argparse
import os
import shutil
import sys
from pathlib import Path

SKIP_DIRS = {"dashboard", ".logs", "Archive", "Future", "Projects"}


def tasks_root() -> Path:
    root = os.environ.get("QUEUE_ROOT")
    if not root:
        sys.exit("error: QUEUE_ROOT is not set (export it to your queue root path; see .env.example)")
    p = Path(root).expanduser()
    if not p.is_dir():
        sys.exit(f"error: QUEUE_ROOT is not a directory: {p}")
    return p


def sanitize_name(name: str) -> str:
    """Validate per server.py rules. Exits on hard violations."""
    name = name.strip()
    if not name:
        sys.exit("error: name is required")
    if any(c in name for c in ("/", "\\", "\x00")):
        sys.exit("error: name contains invalid characters (/, \\, NUL)")
    if name.startswith("."):
        sys.exit("error: name cannot start with '.'")
    if name in SKIP_DIRS:
        sys.exit(f"error: reserved name: {name}")
    return name


def pick_free_folder(root: Path, name: str) -> Path:
    """Return a folder Path under `root` that doesn't collide with <name> (nor
    its numbered variants). Auto-suffixes ' (N)'."""
    candidate = name
    n = 1
    while True:
        if not (root / candidate).exists():
            target = (root / candidate).resolve()
            # Path-traversal guard: must stay directly under `root`.
            if target.parent != root.resolve():
                sys.exit("error: resolved path escapes the active-projects dir")
            return target
        n += 1
        candidate = f"{name} ({n})"


def main() -> None:
    ap = argparse.ArgumentParser(description="Create a queued project folder.")
    ap.add_argument("--name", required=True, help="Project / folder name")
    ap.add_argument("--instructions-file", required=True,
                    help="Path to a UTF-8 file whose contents become instructions.md")
    ap.add_argument("--attach", action="append", default=[],
                    help="File to move into the folder (repeatable)")
    args = ap.parse_args()

    root = tasks_root()
    # Active projects live under Projects/ (parallel to Archive/ and Future/).
    active_root = root / "Projects"
    active_root.mkdir(parents=False, exist_ok=True)
    name = sanitize_name(args.name)

    instr_path = Path(args.instructions_file)
    if not instr_path.is_file():
        sys.exit(f"error: instructions file not found: {instr_path}")
    instructions = instr_path.read_text(encoding="utf-8")
    if not instructions.strip():
        sys.exit("error: instructions content is empty")

    # Validate attachments up front so we don't half-create.
    attach_paths = []
    for a in args.attach:
        p = Path(a)
        if not p.is_file():
            sys.exit(f"error: attachment not found: {p}")
        attach_paths.append(p)

    target = pick_free_folder(active_root, name)
    target.mkdir(parents=False, exist_ok=False)
    (target / "instructions.md").write_text(instructions, encoding="utf-8")

    for p in attach_paths:
        dest = target / p.name
        # Avoid clobbering an attachment with a duplicate basename.
        if dest.exists():
            stem, suffix = dest.stem, dest.suffix
            k = 2
            while (target / f"{stem} ({k}){suffix}").exists():
                k += 1
            dest = target / f"{stem} ({k}){suffix}"
        shutil.move(str(p), str(dest))

    print(str(target))


if __name__ == "__main__":
    main()
