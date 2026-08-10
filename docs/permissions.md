---
title: Permissions
description: "Full Disk Access, Automation, Contacts — what imsg needs and why."
---

`imsg` is local-only, but Messages.app data sits behind macOS privacy gates. Three permissions cover every feature. Full Disk Access is required for database-backed reads, but a supervised `imsg rpc` child can start in degraded mode without it.

## Full Disk Access — required for database methods

`imsg` reads `~/Library/Messages/chat.db` directly. macOS denies that path to every process that hasn't been added to **Full Disk Access**.

Grant it under **System Settings → Privacy & Security → Full Disk Access**.

You almost always need to add at least two entries:

- The terminal app you'll launch `imsg` from (Terminal.app, iTerm2, Ghostty, WezTerm, Alacritty, …).
- The built-in Terminal at `/System/Applications/Utilities/Terminal.app`. macOS sometimes consults this default grant even when you're using a different terminal.

If `imsg` is launched indirectly — by an editor's task runner, a Node script, an SSH session, an automation gateway — the *parent* process needs the grant, not the terminal you opened. Add that parent app too.

After changing entries, quit and relaunch the parent process. macOS only re-reads Full Disk Access on launch.

`imsg` opens `chat.db` read-only. It does not pass SQLite's `immutable=1` flag because immutable handles can miss WAL-backed updates that Messages writes during normal use.

`imsg rpc` does not treat a missing grant as a process-startup failure.
`initialize` / `status`, direct sends, explicit GUID bridge methods, and watch
unsubscribe remain available according to their other prerequisites. The same
child retries the database on each status or database-backed request and
recovers once the grant/path becomes readable.

## Automation — required for sends and tapbacks

`imsg send`, `imsg react`, `imsg typing`, and `imsg read` drive Messages.app via AppleScript. macOS gates that under **Automation**.

The first time you run a send, macOS prompts:

> "Terminal" wants to control "Messages".

Approve it, or pre-approve under **System Settings → Privacy & Security → Automation → Messages**. Toggle the terminal (or wrapper app) on.

If you previously denied the prompt, the toggle will appear here and you can re-enable it without re-prompting.

## Contacts — optional

When granted, `imsg` resolves names from your Address Book and includes them as `contact_name` / `display_name` / `sender_name` in JSON output. Raw `handle` and `sender` values are always preserved, so automation that keys on phone numbers or email addresses is unaffected.

Grant it under **System Settings → Privacy & Security → Contacts**.

If you skip this, JSON output simply leaves the resolved name fields empty. Nothing else changes.

On Macs with CardDAV accounts such as Google or Yahoo, Apple's Contacts framework may periodically write `Could not fetch group … :ABGroup` reconciliation messages to stderr. These messages are benign and do not come from `imsg`; a parent process that captures `imsg rpc --json` stderr should not report this specific framework message as an `imsg` error.

## Why these grants live in three different places

macOS treats each gate as a separate consent decision:

| Gate | What it protects | Triggered by |
|------|------------------|--------------|
| Full Disk Access | `~/Library/Messages/`, Mail, Safari history, … | `imsg chats`, `history`, `watch`, `group`, anything that opens `chat.db`. |
| Automation | One app driving another via Apple Events | `imsg send`, `react`, `read`, `typing`. |
| Contacts | Address Book entries | Name resolution in any read or send command. |

Full Disk Access is mandatory for history, chats, watch subscriptions, send-status inspection, and other database-backed methods. Skip Automation if you don't send. Skip Contacts if you don't need name resolution. The CLI and RPC status snapshots identify the missing gate instead of silently failing.

## Stale grants after updates

After Homebrew, terminal, or macOS updates, Full Disk Access entries can go stale. The symptom is `unable to open database file` or empty output even though the entry looks toggled on.

Fix it by toggling the entry **off**, then **on** again. macOS regenerates the underlying TCC record. Do the same after replacing the parent app (e.g. updating Ghostty).

See [Troubleshooting](troubleshooting.md) for the full diagnosis loop.
