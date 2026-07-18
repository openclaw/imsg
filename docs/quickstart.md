---
title: Quickstart
description: "Five minutes from brew install to streaming Messages over stdout."
---

Goal: install `imsg`, grant the two permissions it needs, and walk through the read → watch → send loop.

## 1. Install

```bash
brew install steipete/tap/imsg
imsg --version
```

If you'd rather build from source, follow [Install](install.md).

On Linux, use the [read-only preview](linux.md) with an existing Messages
database copied from macOS. The rest of this quickstart is macOS-focused because
watching the live database and sending require Messages.app.

## 2. Grant Full Disk Access

`imsg` reads `~/Library/Messages/chat.db` directly. macOS protects that file behind Full Disk Access.

1. **System Settings → Privacy & Security → Full Disk Access.**
2. Add the terminal you'll run `imsg` from (Terminal.app, iTerm2, Ghostty, WezTerm, …).
3. If your shell launches `imsg` from another app — an editor, a Node process, an SSH server — grant Full Disk Access to that parent process too.
4. Quit and re-open the terminal so the new grant takes effect.

Sanity-check:

```bash
imsg chats --limit 3
```

You should see the three most recent conversations. If not, see [Permissions](permissions.md).

## 3. Read history

```bash
# Pick a chat from `imsg chats`, then:
imsg history --chat-id 42 --limit 10
imsg history --chat-id 42 --limit 10 --json | jq -s
```

`--json` is one JSON object per line. Pipe it to `jq -s` to materialize an array, or stream it to whatever consumer you're wiring up.

Filter by date or participant:

```bash
imsg history --chat-id 42 \
  --start 2026-05-01T00:00:00Z \
  --end   2026-05-06T00:00:00Z \
  --json
```

## 4. Stream new messages

```bash
imsg watch --chat-id 42 --json
```

Leave it running. Send yourself a message from another device — you'll see the row arrive within a second or so. To include tapbacks:

```bash
imsg watch --chat-id 42 --reactions --json
```

To resume from a saved cursor (useful for agents that store the last seen `cursor` field):

```bash
imsg watch --chat-id 42 --since-rowid 9000 --json
```

See [Watch](watch.md) for debounce tuning, the polling fallback, and the full event schema.

## 5. Send a message

Sending requires one more permission:

1. **System Settings → Privacy & Security → Automation → Messages.**
2. Toggle on the terminal (and any wrapper app) so it can drive Messages.app.

Then:

```bash
imsg send --to "+14155551212" --text "hi"
imsg send --to "Jane Appleseed" --text "see attached" --file ~/Desktop/note.pdf
imsg send --chat-id 42 --text "same thread"
```

`send --to` accepts a phone number, an iMessage email, or a contact name (resolved via Contacts). For groups, prefer `--chat-id`. See [Send](send.md) for service selection (`imessage`, `sms`, `auto`) and the Tahoe ghost-row failure check.

## 6. Where to go next

- [Chats](chats.md) — what each field in a chat object means.
- [JSON output](json.md) — the stable schema agents should consume.
- [JSON-RPC](rpc.md) — same surfaces, but over stdio with a single long-running process.
- [Attachments](attachments.md) — metadata, original paths, and CAF/GIF conversion.
- [Linux read-only preview](linux.md) — inspect a copied macOS Messages database on Linux.
- [Troubleshooting](troubleshooting.md) — when reads silently return nothing.
