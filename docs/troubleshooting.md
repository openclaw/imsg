---
title: Troubleshooting
description: "Common reasons reads return nothing, sends silently fail, or watch goes quiet — and how to diagnose each one."
---

Most `imsg` issues come down to a permissions gate that hasn't taken effect yet, or a Messages.app behavior change on a recent macOS update. This page walks through the standard diagnoses.

## Reads return `unable to open database file`

The terminal (or its parent process) doesn't have Full Disk Access yet.

1. **System Settings → Privacy & Security → Full Disk Access.**
2. Add the terminal you're running `imsg` from.
3. Add `/System/Applications/Utilities/Terminal.app` even if you don't use it directly — macOS sometimes consults the default terminal grant.
4. If `imsg` is launched indirectly (editor task runner, Node script, SSH session, automation gateway), grant Full Disk Access to that *parent* app, not just the terminal you opened.
5. Quit and relaunch the parent process.

If reads still fail, **toggle the entry off and back on**. Full Disk Access entries can go stale after Homebrew, terminal, or macOS updates. The entry looks correct but no longer carries the underlying TCC grant.

Confirm:

```bash
sqlite3 ~/Library/Messages/chat.db 'pragma quick_check;'
```

If `sqlite3` works but `imsg` doesn't, the parent process of `imsg` is still missing the grant. If `sqlite3` also fails, fix Full Disk Access first.

## Reads succeed but return zero rows

Messages.app isn't signed in, or `chat.db` doesn't exist.

```bash
ls -la ~/Library/Messages/chat.db
```

If the file is missing, open Messages.app and complete iMessage / SMS Forwarding setup. The database is created lazily on first sign-in.

## Sends fail with `not authorized to send Apple events`

Automation permission is missing.

1. **System Settings → Privacy & Security → Automation → Messages.**
2. Toggle the terminal (or wrapper app) on.
3. Re-run the send.

If the toggle isn't visible, run a send once to trigger the prompt, then approve.

## Sends report success but never arrive

Current versions verify every AppleScript text send against `chat.db` when the
database is readable. If Messages returns success but no matching outgoing row
appears within eight seconds, the CLI exits nonzero and RPC returns `-32001`
with `may_have_completed`; do not retry automatically. Direct sends made while
the database is unavailable retain the older best-effort acknowledgment.

Other routing failures to check:

**Tahoe ghost-row failure.** On macOS 26, Messages.app sometimes reports AppleScript success while writing an empty unjoined SMS row instead of delivering. `imsg send` checks explicit chat targets and existing direct chats for this row and preserves the specific ghost-row diagnostic.

**Service mismatch.** A send to a phone number with `--service imessage` fails fast if the recipient isn't on iMessage. With `--service sms`, Text Message Forwarding must be enabled on your iPhone for this Mac. With `--service auto`, `imsg` checks local history first; text-only direct phone sends may retry once over SMS unless `--no-sms-fallback` is set.

**Uncertain delivery outcome.** Errors marked `may_have_completed` or
`still_in_flight` are deliberately not retried or downgraded: the first
transport may already have sent the message. Check Messages/history before
taking another action. Only `not_started` is retry-safe.

For JSON-RPC, `still_in_flight` also blocks queued and future mutations with
`-32004` while reads and watch control keep working. Resolve the outstanding
operation as best you can, then restart the supervised `imsg rpc` child to
clear the process-local mutation-lane poison. Do not repeatedly submit the
same send to the blocked child.

## `imsg watch` goes silent after a while

macOS occasionally drops or coalesces filesystem events, especially after sleep/wake or under heavy I/O. Older versions of `imsg watch` could go silent in that window.

`imsg` 0.6.0 added a low-frequency polling fallback that runs alongside the event watcher. If the cursor falls behind, the poll catches up. `imsg` 0.9.1 also re-arms watches when SQLite rotates `chat.db-wal` or `chat.db-shm`. Make sure you're on 0.9.1+ (`imsg --version`) before debugging stale-watch reports.

If you're already on 0.9.1+ and watch still misses messages, file an issue with:

- macOS version (`sw_vers`).
- `imsg --version`.
- A reproduction including the exact `imsg watch` flags.
- The output of `ls -la ~/Library/Messages/chat.db*` taken just after the silence.

## `react` fails with `unsupported reaction`

`imsg react` only sends the six standard tapbacks Messages.app exposes reliably through automation: `love`, `like`, `dislike`, `laugh`, `emphasis`, `question`.

Custom emoji tapbacks can be *read* in `watch --reactions` output, but `react` rejects them rather than taking a no-op AppleScript path. There's no automation surface that sends arbitrary emoji tapbacks reliably.

## `imsg` reports a different version than `brew`

Stale Homebrew install or a manually-built binary on `PATH` ahead of the formula:

```bash
which imsg
brew list --versions imsg
```

If `which imsg` doesn't point at the Homebrew prefix, remove the older binary or reorder your `PATH`.

## Contacts names are missing in JSON output

Contacts permission isn't granted, or the contact isn't matched.

1. Confirm under **System Settings → Privacy & Security → Contacts** that the terminal/wrapper app is enabled.
2. Raw handles are always preserved in `sender`, `chat_identifier`, etc. The optional `contact_name` / `sender_name` fields are simply omitted when no match is found.

If you want partial fallback names (initials, or formatted handles), do that in your consumer — `imsg` doesn't synthesize names that aren't in your Address Book.

## Advanced IMCore features fail

See [Advanced IMCore features](advanced-imcore.md). Most likely SIP is enabled (required to be off), library validation is rejecting the helper dylib, or macOS 26's `imagent` entitlement check is blocking the IMCore client. These are macOS-level gates `imsg` cannot work around.

## Filing issues

If you've worked through the relevant section above and are stuck, open an issue at <https://github.com/steipete/imsg/issues>.

Useful context:

- `imsg --version`.
- `sw_vers` (macOS version).
- The exact command you ran and the full output (with any sensitive content redacted).
- Whether `sqlite3 ~/Library/Messages/chat.db 'pragma quick_check;'` succeeds or fails.
