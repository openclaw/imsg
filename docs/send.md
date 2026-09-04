---
title: Send
description: "Send text and files to direct chats and groups through Messages.app automation, plus standard tapbacks."
---

`imsg send` rides Messages' published AppleScript surface — no private send APIs, no IMCore injection. Production sends run in a bounded `/usr/bin/osascript` child so a stuck Messages automation call can be terminated and reaped. Sending requires Automation permission for Messages (see [Permissions](permissions.md)).

## Direct sends

```bash
imsg send --to "+14155551212" --text "hi"
imsg send --to "jane@example.com" --text "hi"
imsg send --to "Jane Appleseed" --text "hi"
```

`--to` accepts:

- An E.164 phone number (`+14155551212`) — best.
- A locally-formatted phone number (`415-555-1212`). Pair with `--region US` if you need to override the default.
- An iMessage email address.
- A contact name. Resolved through Address Book; requires Contacts permission.

For unambiguous routing, prefer phone numbers in E.164 form.

When `chat.db` is readable and the recipient already has a direct chat, `imsg`
targets a compatible chat's GUID instead of constructing a new buddy send. Explicit `sms` and `imessage` selection never reuse a chat on the opposite service. New
recipients still use the existing buddy-send behavior.

If that GUID is absent from Messages.app's live chats, `imsg` recovers from
the pre-dispatch `-1728` lookup error by resolving the participant on the
chat's original account. This requires a direct-chat GUID, exactly one matching
database participant, and a known account with the same service. It also works
for direct conversations selected with `--chat-id`, `--chat-guid`, or
`--chat-identifier`. Groups and unverified targets never use this recovery.
Errors during `send` still have an uncertain outcome and are never retried.
This account-scoped recovery does not change service and is independent of
`--no-sms-fallback`.

## Group sends

You'll typically want `--chat-id`:

```bash
imsg send --chat-id 42 --text "same thread"
```

Use `--chat-identifier` or `--chat-guid` when only the portable handles are available:

```bash
imsg send --chat-identifier "iMessage;+;chat1234567890" --text "hi"
imsg send --chat-guid "iMessage;+;chat1234567890" --text "hi"
```

See [Groups](groups.md) for how Messages encodes group handles.

## Files and audio

```bash
imsg send --to "+14155551212" --text "see attached" --file ~/Desktop/note.pdf
imsg send --to "Jane Appleseed" --file ~/Desktop/voice.m4a
imsg send --chat-id 42 --file ~/Desktop/screenshot.png
```

Both `--text` and `--file` can be supplied together.

Before handing the file to Messages, `imsg` stages it under `~/Library/Messages/Attachments/imsg/`. Messages reads attachments from there reliably across macOS versions; sending directly from `~/Desktop` or `~/Downloads` can hit sandbox-related send failures.

Audio files (`.m4a`, `.caf`, `.aiff`, etc.) send the same way as any other file. Messages exposes them as audio messages on the receiving side.

## Service selection

```bash
imsg send --to "+14155551212" --text "hi" --service auto       # default
imsg send --to "+14155551212" --text "hi" --service imessage
imsg send --to "+14155551212" --text "hi" --service sms
imsg send --to "+14155551212" --text "hi" --no-sms-fallback
```

- `auto` — `imsg` first checks local Messages history for the handle's observed service when `chat.db` is readable. Existing SMS-only phone threads use SMS; known iMessage handles use iMessage; unknown handles, or sessions without Full Disk Access, try iMessage. For text-only direct phone sends, an iMessage attempt retries once over SMS only when the AppleScript transport proves that target/service resolution failed before the first `send` began. A timeout, signal, lost result, nonzero exit, or error during/after `send` has an uncertain outcome and never falls back.
- `imessage` — force iMessage. Fails fast if the recipient isn't on iMessage.
- `sms` — force SMS relay. Requires Text Message Forwarding enabled on your iPhone for this Mac.

SMS fallback is intentionally narrow: it does not run for explicit `--service imessage`, `--service sms`, explicit chat-target sends, email recipients, or attachment sends. For groups, omit `--service`. Group sends always use the chat's existing service.

Failed mutations report one of three delivery dispositions: `not_started`
(retry is safe), `may_have_completed` (outcome unknown; do not retry), or
`still_in_flight` (work may continue; do not retry). This is transport-owned
state, not wording inferred from an error message.

## Region for phone normalization

```bash
imsg send --to "415-555-1212" --text "hi" --region US
```

Defaults to `US`. Pass an ISO 3166-1 alpha-2 country code to normalize locally-formatted numbers. Chat selection, service detection, dispatch, and verification use the same normalized recipient, including local-format numbers outside the US.

## Confirming what was sent

Default text mode prints `sent` on success. JSON mode emits `{"status":"sent"}`.

When `chat.db` is readable, every AppleScript text send waits up to eight
seconds for the matching outgoing row. If Messages reports success but no row
appears, `imsg` returns `may_have_completed` with no-retry guidance instead of
reporting success. The lookup is scoped to the actual send route; after a safe SMS fallback, it verifies the SMS chat and reports that message's ID and service. A new recipient's chat must become visible before its text can be confirmed. Direct sends still retain the
previous accepted behavior when the database is unavailable. Attachment-only
verification is unchanged.

The [JSON-RPC `send` method](rpc.md#send) includes the rowid and GUID of the inserted message when available. RPC `send` also accepts `transport` (`auto`, `bridge`, or `applescript`) for callers that want to prefer or require the IMCore bridge.

## Tahoe ghost-row protection

On macOS 26 (Tahoe), Messages.app has a failure mode where AppleScript reports success but writes an empty outgoing SMS row that isn't joined to the target chat. The send looks fine to the caller but never reaches the recipient.

`imsg send` checks for this ghost row after AppleScript sends to an explicit
chat target or an existing direct chat resolved from `--to`. If it finds one,
the command reports the established ghost-row diagnostic before the generic
no-row uncertainty.

This check landed in 0.6.0; see `CHANGELOG.md` for the issue history.

## Standard tapbacks

```bash
imsg react --chat-id 42 --reaction love
imsg react --chat-id 42 --reaction like
imsg react --chat-id 42 --reaction dislike
imsg react --chat-id 42 --reaction laugh
imsg react --chat-id 42 --reaction emphasis
imsg react --chat-id 42 --reaction question
```

`react` sends only the six standard tapbacks Messages.app exposes reliably through automation. After the AppleScript call, `imsg` confirms the reaction selection in Messages' UI before reporting success — this guards against silent UI rejections.

Custom emoji tapbacks can be *read* in `watch --reactions` output, but `react` rejects them rather than taking a no-op AppleScript path. There is no published automation surface that sends arbitrary emoji tapbacks reliably.

## Outgoing routing — what you can and can't control

`imsg` reports per-chat routing diagnostics — `account_id`, `account_login`, `last_addressed_handle`, and per-message `destination_caller_id`. They tell you which Apple ID and which of your numbers Messages routed through.

You cannot use `send` to *force* a specific outgoing number when several phone numbers share one Apple ID. AppleScript's `send` has no `from` or account selector. The fields are diagnostic, not steering. If you need to force a specific number, change the default in Messages' settings.

## What requires what

| Send variant | Permission | macOS limits |
|--------------|------------|--------------|
| `send --to <handle>` | Automation → Messages | None unique to this command. |
| `send --chat-id` (groups) | Automation → Messages | Tahoe ghost-row check active. |
| `send --file` | Automation → Messages | Files are auto-staged in Messages' attachments dir. |
| `react` | Automation → Messages + UI scripting | Only the six standard tapbacks are sendable. |
| `read` (mark as read) | [Advanced IMCore](advanced-imcore.md) | SIP-disabled, dylib injection, increasingly limited on macOS 26. |
| `typing` (typing indicator) | [Advanced IMCore](advanced-imcore.md) | Same as `read`. |
