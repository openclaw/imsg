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
`initialize` / `status`, direct sends, `typing` / `read` requests using `to`,
`chat_identifier`, or `chat_guid`, eligible explicit-GUID bridge-only methods,
and watch unsubscribe remain available according to their other prerequisites.
The same child retries the database on each status or database-backed request
and recovers once the grant/path becomes readable. A `chat_id` target still
requires the database.

## Automation — required for AppleScript sends and tapbacks

Direct `imsg send` and `imsg react` operations drive Messages.app via
AppleScript. macOS gates that under **Automation**. Typing indicators and read
receipts use the advanced IMCore paths instead; they do not use AppleScript,
but their shipped bridge fallback/activation behavior may activate
Messages.app.

The first time you run a send, macOS prompts:

> "Terminal" wants to control "Messages".

Approve it, or pre-approve under **System Settings → Privacy & Security → Automation → Messages**. Toggle the terminal (or wrapper app) on.

If you previously denied the prompt, the toggle will appear here and you can re-enable it without re-prompting.

## Contacts — optional

When granted, `imsg` resolves names from your Address Book and includes them as `contact_name` / `display_name` / `sender_name` in JSON output. Raw `handle` and `sender` values are always preserved, so automation that keys on phone numbers or email addresses is unaffected.

Grant it under **System Settings → Privacy & Security → Contacts**.

`imsg nickname --local` distinguishes `(Contacts unavailable)` from `(none)` in
text output; JSON exposes the same distinction as `contacts_unavailable`. An
unavailable result means imsg could not read Contacts, not that the handle has no
matching contact. For indirect launches, check the grant for the app or process
running imsg. Full Disk Access does not grant access through Contacts.framework;
SSH sessions can use the read-only database path described below.

When neither Contacts source is readable, JSON output leaves resolved name fields empty. A long-running `imsg rpc` child observes Contacts changes and periodically rechecks authorization, so grants and contact edits become visible without restarting. Revocation clears cached names; a transient Contacts read failure retains the last successful catalog until the next refresh.

On Macs with CardDAV accounts such as Google or Yahoo, Apple's Contacts framework may periodically write `Could not fetch group … :ABGroup` reconciliation messages to stderr. These messages are benign and do not come from `imsg`; a parent process that captures `imsg rpc --json` stderr should not report this specific framework message as an `imsg` error.

## Contacts over SSH

SSH sessions prefer Contacts.framework when its permission is available. Otherwise, imsg automatically reads the local AddressBook SQLite stores using the SSH service's existing Full Disk Access. This applies to phone/email lookup, `nickname --local`, chat and message name fields, and `imsg rpc`. It requires no SIP change or separate Contacts prompt, including when SSH allocates a TTY.

```bash
ssh your-mac 'imsg nickname --local --address friend@example.com --json'
ssh your-mac 'imsg chats --limit 10 --json'
```

Give the SSH service Full Disk Access on the Mac, then reconnect. Depending on the macOS version, the relevant control is [**System Settings → General → Sharing → Remote Login → Allow full disk access for remote users**](https://support.apple.com/guide/mac-help/mchlp1066/mac), or the SSH service's Full Disk Access entry. A Contacts restriction imposed by the system remains unavailable.

The contact data must already be synced to that Mac. The reader supports `AddressBook-v22.abcddb` in `~/Library/Application Support/AddressBook/` and its account `Sources` directories. A newer unsupported database version is reported as unavailable instead of reading a retired older copy. It opens existing databases read-only and includes WAL updates; it never edits Contacts, changes permission grants, or copies the database elsewhere. Outside SSH (detected through `SSH_CONNECTION` or `SSH_CLIENT`), Contacts.framework remains the only source.

Long-running processes refresh the database catalog every 30 seconds on use, or sooner after a Contacts change notification. Changes to Contacts authorization re-evaluate the source immediately before returning cached names. Missing access, a removed database, or an unsupported schema clears cached names on that refresh and reports Contacts unavailable. A transient SQLite lock retains the last successful catalog. An empty, readable store is a valid no-match result, so check that Contacts has finished syncing before diagnosing permissions.

## Why these grants live in three different places

macOS treats each gate as a separate consent decision:

| Gate | What it protects | Triggered by |
|------|------------------|--------------|
| Full Disk Access | `~/Library/Messages/`, Mail, Safari history, … | `imsg chats`, `history`, `watch`, `group`, anything that opens `chat.db`. |
| Automation | One app driving another via Apple Events | Direct `imsg send` and `react`. |
| Contacts | Address Book entries | Name resolution in any read or send command. |

Full Disk Access is mandatory for history, chats, watch subscriptions, send-status inspection, and other database-backed methods. Skip Automation if you don't send. Skip Contacts if you don't need name resolution. The CLI and RPC status snapshots identify the missing gate instead of silently failing.

## Stale grants after updates

After Homebrew, terminal, or macOS updates, Full Disk Access entries can go stale. The symptom is `unable to open database file` or empty output even though the entry looks toggled on.

Fix it by toggling the entry **off**, then **on** again. macOS regenerates the underlying TCC record. Do the same after replacing the parent app (e.g. updating Ghostty).

See [Troubleshooting](troubleshooting.md) for the full diagnosis loop.
