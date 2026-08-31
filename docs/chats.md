---
title: Chats
description: "List recent conversations and inspect a single chat's identifiers, participants, and routing hints."
---

`imsg chats` lists conversations sorted by most recent activity. `imsg group` zooms in on one chat. Both work for direct chats and group threads.

## List recent chats

```bash
imsg chats --limit 20
imsg chats --limit 20 --json | jq -s
```

Columns (text mode): `id`, `name`, `service`, `last_message_at`.

Text output prefers a resolved contact name for direct chats, then the Messages
display name or raw chat identifier.

Empty and missing Messages display names fall back to the raw chat identifier,
including when Contacts is unavailable over SSH. JSON exposes a resolved Contacts
match separately as `contact_name` in both `chats` and RPC `chats.list`.
The presentation fallback belongs to `name`: an empty stored title remains empty
in JSON `display_name` and chat-detail metadata.

## Inspect one chat

```bash
imsg group --chat-id 42
imsg group --chat-id 42 --json
```

Use this before scripting a send. It returns identifier, GUID, service, participants, group/direct flag, and account routing hints in one shot.

`imsg group` works for direct chats too, despite the name. Treat it as "chat detail," not "groups only."

## Chat list object

Objects returned by `imsg chats --json` and JSON-RPC `chats.list` include:

| Field | Type | Notes |
|-------|------|-------|
| `id` | int | `chat.ROWID`. Stable within one Messages database. Preferred routing handle. |
| `name` | string | Messages display name or raw chat identifier fallback. |
| `display_name` | string | Chat title metadata. An empty stored title remains empty. |
| `contact_name` | string | Resolved Contacts name when permission granted. |
| `identifier` | string | `chat.chat_identifier` — Messages' portable handle. |
| `guid` | string | `chat.guid` — Messages' portable GUID. |
| `service` | string | `iMessage`, `SMS`, etc. |
| `last_message_at` | ISO8601 | Newest activity in the chat. |
| `is_group` | bool | True when `identifier` or `guid` contains `;+;`. See [Groups](groups.md). |
| `participants` | array | External handles only. The local user is implicit; see below. |
| `account_id` | string | Routing diagnostic. Read-only. |
| `account_login` | string | Routing diagnostic. Read-only. |
| `last_addressed_handle` | string | Routing diagnostic. Read-only. |
| `unread_count` | int | Count of unread inbound messages in the chat. Omitted on older database schemas without read state. |

## Routing identifiers — which one to use

Three handles can identify a chat. Pick by use case:

- **`chat_id`** (rowid): preferred. Fastest, most stable within one database. Use this whenever both reader and sender are on the same machine.
- **`chat_identifier`**: portable across DBs/installs. Use when you store handles externally and need to tolerate a Messages reset.
- **`chat_guid`**: also portable. Same use cases as `chat_identifier`.

For sends, `imsg send --chat-id` is preferred. `--chat-identifier` and `--chat-guid` are fallbacks for callers that only have the portable handle.

## Participants vs. local identity

`participants` lists external handles only. The local user is intentionally absent because Messages stores it implicitly per-message rather than on the chat row.

To distinguish your own messages from others':

- Use `is_from_me` on each message.
- For multi-number Apple IDs, check `destination_caller_id` on outgoing messages — it tells you which of your numbers Messages routed through.

`account_id`, `account_login`, and `last_addressed_handle` are diagnostic *reads* from Messages. AppleScript's `send` does not let `imsg` force a specific outbound number when several phone numbers share one Apple ID. The fields are there so you can audit what Messages picked, not steer it.

## Filtering tips

`imsg chats` takes one filter flag, `--unread-only`, which returns only chats with unread inbound messages:

```bash
imsg chats --unread-only --json
```

On an older Messages database without a read-state column, `--unread-only` fails clearly instead of reporting an empty inbox.

For anything else, pipe through `jq` or `grep` for ad-hoc filtering:

```bash
imsg chats --json | jq -s 'map(select(.is_group == true))'
imsg chats --json | jq -s 'map(select(.service == "SMS"))'
```

For more targeted history queries with date and participant filters, use [`imsg history`](history.md).
