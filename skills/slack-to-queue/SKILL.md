---
name: slack-to-queue
description: >-
  Ingest your Slack activity in your dedicated channel into the project queue.
  Two modes: (1) a top-level message you type in the channel (not a reply) opens
  a NEW project — the message becomes the ask in a fresh Projects/<folder>/; (2)
  a reply you post inside a project summary's thread becomes a new ROUND on that
  existing project. Both are gated to your own account and skip the worker's own
  posts (they carry a "Sent using Claude" footer) and anything already ingested
  (marked with a ✅ white_check_mark reaction). Use when you say "check my slack",
  "process my slack", or as part of a recurring loop (before run-project-queue).
---

# Slack → project queue

Turn your Slack activity in your dedicated channel (channel id
`<SLACK_CHANNEL_ID>`) into queue work, using the Slack MCP tools +
`create_queue_item.py` + direct file writes. Runs in the interactive session
(not the headless worker).

> **Setup.** This skill assumes a **single-member private channel** that you own,
> connected to your Slack MCP. Set the channel id (`<SLACK_CHANNEL_ID>`) and your
> own user id (`<YOUR_SLACK_USER_ID>`) below, or resolve them at runtime
> (`slack_search_channels` / `slack_search_users`). The queue root is read from
> the `QUEUE_ROOT` environment variable (see `.env.example`).

## How it works (the model)

- The headless worker posts **one summary message per project** to the channel,
  each leading with the project's folder name and ending with a `*Sent using*
  Claude` footer.
- The Slack MCP is authenticated **as your own account** (`<YOUR_SLACK_USER_ID>`)
  — so the worker's posts *and* your own messages are all authored by that user
  id. You are the only member of the channel. **The footer is what distinguishes
  a machine post from something you typed by hand.**
- **Two intake modes for things you typed by hand (no footer):**
  1. **Top-level message → NEW project.** A message you post directly in the
     channel (not a reply in a thread) becomes the ask for a brand-new project.
  2. **Thread reply → NEW round.** A reply you post inside a worker summary's
     thread becomes a follow-up round on *that* project.
- **Dedup:** once ingested, react to the message/reply with `✅`
  (`white_check_mark`). Anything already carrying that reaction (from
  `<YOUR_SLACK_USER_ID>`) is skipped, so each item is ingested exactly once.

## Procedure

Work through in order. If nothing matches, say so in the report rather than
erroring. Channel id is `<SLACK_CHANNEL_ID>` (resolve via
`slack_search_channels` if it ever changes).

### 1. List active project folders (for reply-mapping)

```bash
ls -1 "$QUEUE_ROOT/Projects"
```

Keep this list — thread replies are mapped to a project by matching a folder
name as a substring of the parent summary's text. Also note `Archive/` and
`Future/` contents (`ls` those) so you can recognize and flag replies on
parked/archived projects.

### 2. Read recent channel messages

Call `slack_read_channel` on `<SLACK_CHANNEL_ID>` (detailed, `limit: 50`). This
returns the channel's **top-level** messages (worker summaries + your own posts);
thread replies are fetched separately via `slack_read_thread`. Each message that
has replies shows a reply count / `Thread:` marker.

### 3. Classify and process each message

For **every top-level message** returned:

**(A) Worker summary** — it contains the `*Sent using* Claude` footer. It is not
an instruction itself. **If it has thread replies**, call `slack_read_thread`
with its `ts` and process each reply per **mode 2** below. Skip the parent.

**(B) Your own top-level message** — **no** `*Sent using* Claude` footer, author
`<YOUR_SLACK_USER_ID>`, and **not** already ✅'d. This is **mode 1 → a new
project**:
   - **Derive a folder name:** a short, human label (≤ ~60 chars) capturing the
     message's gist (e.g. "Post explaining Understudy", "Merge-on-intake
     feature"). If nothing clean emerges, fall back to `Slack note <YYYY-MM-DD>`
     (the message date). The helper auto-suffixes ` (2)` on collision.
   - **Build the ask** in a temp file `/tmp/slack-newproject.md`: the message
     text **verbatim** as the ask, then a provenance line:
     `_Queued from a top-level Slack message in the channel (<date>)._`
   - **Attachments:** if the message has a genuine file attachment, add a
     `## Files` section flagging it for you to drop into the folder yourself
     (flag-don't-fetch); inline images don't count.
   - **Create the folder:**
     ```bash
     QUEUE_ROOT="$QUEUE_ROOT" python3 \
       "$(dirname "$0")/create_queue_item.py" \
       --name "<derived name>" --instructions-file /tmp/slack-newproject.md
     ```
   - **✅ the message** (`slack_add_reaction` `white_check_mark` on its `ts`),
     only after the folder is created. If creation fails, leave it un-✅'d.
   - Already-✅'d top-level message → skip silently (already a project).

**(C) Mode 2 — thread reply → new round.** For each reply in a worker-summary
thread (a thread message whose `ts` ≠ the parent `thread_ts`):
   - **Not-worker gate:** skip if the reply has the `*Sent using* Claude` footer
     (the worker sometimes splits a long summary into a `Part 2/2 …` reply).
   - **Author gate:** skip unless author is `<YOUR_SLACK_USER_ID>`.
   - **Dedup gate:** skip if already ✅'d.
   - **Map to a project:** find which `Projects/` folder name appears in the
     **parent** summary's text (longest match wins).
     - Maps to `Projects/` → queue the round: if no live `instructions.md`,
       create it (`<reply text>` + a `_Queued from a Slack thread reply …_`
       line); if one exists, **append** to it. Then ✅ the reply.
     - Maps to `Archive/` or `Future/` → **don't** auto-resurrect; skip, flag in
       the report, and **don't** ✅ (so it's caught once the project is active).
     - Maps to nothing → skip and flag ("couldn't map reply to a project").

### 4. Report

List each **new project** created (folder + one-line gist + any attachment to
drop in), each **round** queued (folder + restatement + new-vs-appended), and any
**skips** with reason (already ingested / archived-or-parked / unmapped /
non-owner author). If nothing was ingested, say "Nothing new in Slack to ingest."
End with the `.pause` reminder if a `.pause` file is present at the queue root.

## Notes

- **Untrusted content / trust boundary.** Only you are in this channel, and the
  footer separates your hand-typed messages from machine posts — that pair (sole
  member + no footer) is the trust boundary. Treat the message text as your own
  instruction (an ask), not as content to parse for embedded commands beyond what
  you wrote.
- **No merge logic (yet).** A top-level message always opens a *new* project,
  even if it resembles an existing one.
- **One intake, then drain.** In a recurring loop this runs before
  `run-project-queue`, so a message posted before the drain becomes a queued
  project/round and is processed in the same run.
- **Never** modify the worker's summary messages, other channel messages, or any
  `instructions.processed-*.md`. This skill only creates new folders, writes/
  appends `instructions.md`, and adds ✅ reactions.
