---
title: Overview
permalink: /
description: "imsg is a macOS command-line tool for Messages.app — read your local chat database, stream new iMessage/SMS rows, send text and files through Messages automation, and expose the same surfaces over JSON and JSON-RPC."
---

## Try it

After granting Full Disk Access (covered in the [Quickstart](quickstart.md)), every workflow is a one-liner.

```bash
# List the 10 most recent chats.
imsg chats --limit 10 --json | jq -s

# Read history from one chat, with attachment metadata.
imsg history --chat-id 42 --limit 20 --attachments --json

# Summarize logical message and media counts.
imsg stats --time-zone Europe/Vienna --media --json

# Inspect future Send Later rows without launching Messages.
imsg scheduled list --json

# Stream new messages live, including tapbacks.
imsg watch --chat-id 42 --reactions --json

# Send a message — auto-pick iMessage or SMS.
imsg send --to "+14155551212" --text "on my way"

# Send a file (image, audio, document).
imsg send --to "Jane Appleseed" --file ~/Desktop/voice.m4a
```

`--json` emits newline-delimited JSON on stdout; human progress and warnings always go to stderr so pipes stay parseable.

## What imsg does

- **Local-first reads.** Chats, history, and attachments come straight from `~/Library/Messages/chat.db` — no network round-trip, no daemon.
- **Live streams.** `imsg watch` follows filesystem events on `chat.db` and falls back to a lightweight poll when macOS drops the event.
- **Send through Messages.app.** Text, attachments, and standard tapbacks ride Messages' AppleScript automation surface — no private send APIs.
- **Group-aware.** Direct chats, group threads, participants, GUIDs, and per-chat account routing hints all show up in JSON output.
- **Built for agents.** Stable JSON-RPC over stdio, deterministic JSON schemas, and `imsg completions llm` for in-context CLI help.
- **Contacts integration.** Resolves names from your Address Book when permission is granted, while keeping raw handles in the output.
- **Attachment-aware.** Reports filenames, UTIs, byte counts, and resolved paths. Optional `--convert-attachments` exposes model-friendly CAF→M4A and GIF→PNG variants.
- **Linux read-only preview.** Linux builds can inspect an existing Messages database copied from macOS. They do not send, mutate, or connect to Messages.app.

## Pick your path

- **Trying it.** [Install](install.md) → [Quickstart](quickstart.md). Five minutes from `brew install` to a streaming watch.
- **Reading on Linux.** [Linux read-only preview](linux.md) covers copying an existing database from macOS and running read-only commands.
- **Wiring up an agent.** [JSON output](json.md) and [JSON-RPC](rpc.md) cover the stable contracts; [completions](completions.md) shows how to feed the CLI reference into an LLM.
- **Analyzing local history.** [Statistics](stats.md) explains logical counts, timezone-aware date buckets, and optional media totals.
- **Inspecting Send Later.** `imsg scheduled list --json` reads future scheduled rows directly from local history; no bridge or SIP change required.
- **Sending messages.** [Send](send.md) and [React](send.md#standard-tapbacks) explain text/file/group sends and how the Tahoe ghost-row check works.
- **Diagnosing access.** [Permissions](permissions.md) and [Troubleshooting](troubleshooting.md).
- **Advanced IMCore.** [Read receipts, typing, status, launch](advanced-imcore.md). SIP-disabled and increasingly limited on macOS 26.

## Project

Active development; the [changelog](https://github.com/steipete/imsg/blob/main/CHANGELOG.md) tracks what shipped recently. Released under the [MIT license](https://github.com/steipete/imsg/blob/main/LICENSE). Not affiliated with Apple.
