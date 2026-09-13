---
title: Groups
description: "How imsg detects group chats, the identifiers that route to them, and the Tahoe-era failure modes."
---

Messages encodes group chats with a different identifier shape than direct chats. `imsg` surfaces that distinction explicitly so callers don't have to parse handles themselves.

## What counts as a group

- `chat.chat_identifier` or `chat.guid` contains `;+;`, for example `iMessage;+;chat1234567890`.
- `SERVICE;-;TARGET` is a direct 1:1 chat, for example `iMessage;-;+15551234567`. Deliberately not flagged as a group.
- Direct chats typically use a single handle (phone or email) with no `;+;`.

The `is_group` boolean on every chat object encodes this for you.

## Where the identifiers live

| Field | Source | Notes |
|-------|--------|-------|
| `chat.ROWID` → `chat_id` | local rowid | Stable within one DB. Preferred routing handle. |
| `chat.chat_identifier` | Messages | Portable group handle. |
| `chat.guid` | Messages | Portable GUID. Often the same shape as `chat_identifier` for groups. |
| `chat.display_name` | Messages | Optional group name. |
| `chat.account_id` / `account_login` / `last_addressed_handle` | Messages | Read-only routing diagnostics. |
| `participants` | `chat_handle_join` + `handle` | External handles only. |

## Sending to a group

Pick the most stable identifier you have:

```bash
imsg send --chat-id 42 --text "hi"                                    # preferred (DB local)
imsg send --chat-identifier "iMessage;+;chat1234567890" --text "hi"   # portable
imsg send --chat-guid "iMessage;+;chat1234567890" --text "hi"         # portable
```

Group sends use AppleScript `chat id "<handle>"` (the "Jared pattern"). Attachments work the same as direct sends; see [Send](send.md).

### Tahoe ghost-row failure

On macOS 26 (Tahoe), Messages.app sometimes reports AppleScript success while writing an empty unjoined SMS row instead of delivering to the target group. `imsg send` detects that ghost row by inspecting `chat.db` after the AppleScript call and reports an error rather than success.

This check is automatic for chat-target sends, including direct `--to` sends that resolve to an existing chat. See [Send](send.md#tahoe-ghost-row-protection).

## Inbound metadata (JSON)

`imsg chats`, `imsg history`, and `imsg watch` — and the JSON-RPC equivalents — all include the same group fields:

- `chat_id`
- `chat_identifier`
- `chat_guid`
- `chat_name`
- `account_id`
- `account_login`
- `last_addressed_handle`
- `participants` (array of handles)
- `is_group`

Within one machine and one Messages database, `chat_id` is the preferred routing key. For sync across machines (or after a Messages reset), persist `chat_identifier` or `chat_guid` instead.

### Participants exclude the local user

`participants` is sourced from Messages' `chat_handle_join` table, which only stores external handles. Your own handle is implicit and message-specific.

When the distinction matters, combine these per-message fields:

- `is_from_me` — outbound vs. inbound.
- `destination_caller_id` (outbound only) — which of your numbers Messages routed through.

### Multiple local identities

Messages stores per-chat hints for which of your numbers should be used (`account_id`, `account_login`, `last_addressed_handle`). `imsg` exposes these as diagnostics, but its `send` cannot force a specific outbound number — AppleScript `send` has no `from` selector. To change the default for new outbound traffic, adjust Messages' Settings → iMessage section.

## Focused chat lookup

```bash
imsg group --chat-id 42
imsg group --chat-id 42 --json
```

`imsg group` prints id, identifier, GUID, name, service, `is_group`, participants, and routing hints for one chat. It works for direct chats too; treat it as a "chat detail" command rather than groups-only.

## Notes

- Group send uses the chat handle, not `buddy`.
- Outgoing messages from the local user can have an empty `sender` value. Prefer `sender_name` plus chat metadata when displaying who sent what.
