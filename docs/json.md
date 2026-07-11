---
title: JSON output
description: "The stable JSON schema imsg emits for chats, messages, attachments, and reaction events."
---

Every read command supports `--json`. Output is **newline-delimited JSON (NDJSON)**: one self-contained JSON object per line. This shape works equally well for streaming consumers and for batch readers that pipe through `jq -s` to materialize an array.

```bash
imsg chats --json | jq -s
imsg history --chat-id 42 --json | jq -s
imsg watch --chat-id 42 --json
```

Human progress, prompts, and warnings are written to **stderr**, not stdout. Stdout is reserved for parseable JSON so pipelines stay clean.

## Chat list item

Returned by `imsg chats --json` and JSON-RPC `chats.list`.

| Field | Type | Notes |
|-------|------|-------|
| `id` | int | `chat.ROWID`. Stable within one DB. Preferred routing handle. |
| `name` | string | Display name, contact match, or raw handle fallback. |
| `display_name` | string | Group title from `chat.display_name`. Empty for direct chats without a custom name. |
| `contact_name` | string | Resolved Contacts name (when permission granted). |
| `identifier` | string | `chat.chat_identifier`. Portable. |
| `guid` | string | `chat.guid`. Portable. |
| `service` | string | `iMessage`, `SMS`, etc. |
| `last_message_at` | ISO8601 | Newest activity time. |
| `is_group` | bool | True when identifier or guid contains `;+;`. |
| `participants` | array of strings | External handles only; local user implicit. |
| `account_id` | string | Routing diagnostic. Read-only. |
| `account_login` | string | Routing diagnostic. Read-only. |
| `last_addressed_handle` | string | Routing diagnostic. Read-only. |
| `unread_count` | int | Count of unread inbound messages in the chat. Omitted on older database schemas without read state. |

## Message

Returned by `imsg history`, `imsg search`, `imsg watch`, and the JSON-RPC `messages.history` and `watch.subscribe` notifications.

| Field | Type | Notes |
|-------|------|-------|
| `id` | int | rowid. Use as the `--since-rowid` cursor in watch. |
| `chat_id` | int | Always present. Preferred routing handle. |
| `chat_identifier` | string | Portable handle. |
| `chat_guid` | string | Portable GUID. |
| `chat_name` | string | Display name for the chat. |
| `participants` | array | External handles. |
| `is_group` | bool | True for group threads. |
| `guid` | string | Message GUID. Stable across machines. |
| `reply_to_guid` | string | When set, this message is an inline reply to that GUID. |
| `destination_caller_id` | string | Outgoing only — which of your numbers Messages routed through. |
| `balloon_bundle_id` | string | Raw Messages `message.balloon_bundle_id`, when present. URL preview rows use `com.apple.messages.URLBalloonProvider`, which lets consumers recognize link-preview payload rows without inferring from message text. |
| `url_preview` | object | Present when imsg folds an Apple URL-preview balloon row into its originating text row. The outer message keeps the text row's `id`, `guid`, `text`, and `created_at`. |
| `sender` | string | Raw handle. Empty for some self-sent messages. |
| `sender_name` | string | Resolved Contacts name when permission granted. |
| `is_from_me` | bool | True for outbound. |
| `text` | string | Plain text. Recovered from `attributedBody` when `text` column is empty. |
| `created_at` | ISO8601 | Message timestamp. |
| `attachments` | array | Present when `--attachments` is set. See below. |
| `thread_originator_guid` | string | For inline-reply threads. |
| `poll` | object | Present for native Apple Messages Polls creation and vote rows. See below. |
| `is_read` | bool | Inbound only — omitted when `is_from_me` is true. |
| `date_read` | ISO8601 | Inbound only — present when `is_read` is true. |

Read state is a database snapshot. A watch notification includes the state present when that message row is emitted; reading it later does not generate a second message notification.

## Scheduled message

Returned by `imsg scheduled list --json` and in the JSON-RPC `messages.scheduled` result. Only future outbound rows with native scheduling state are included.

| Field | Type | Notes |
|-------|------|-------|
| `id` | int | Scheduled message rowid. |
| `guid` | string | Native message GUID. |
| `chat_id` | int | Local chat rowid. |
| `chat_identifier` | string | Portable chat identifier. |
| `chat_guid` | string | Portable chat GUID. |
| `chat_name` | string | Display name or identifier fallback. |
| `text` | string | Scheduled message body. |
| `service` | string | Message service, normally `iMessage`. |
| `scheduled_at` | ISO8601 | Requested delivery time. |
| `schedule_type` | int | Raw Messages scheduling type. |
| `schedule_state` | int | Raw Messages scheduling state. |

## Chat background status

Returned by `imsg chat-background status --chat-id <id> --json`. This surface is read-only and does not require the IMCore bridge.

| Field | Type | Notes |
|-------|------|-------|
| `chat_id` | int | Local chat rowid. |
| `chat_guid` | string | Portable chat GUID. |
| `background_set` | bool | Whether the chat properties contain a background channel. |
| `background_channel_guid` | string | Background channel identifier; omitted when no background is set. |
| `asset_url` | string | Raw background asset URL when present. |
| `asset_id` | string | Raw background asset identifier when present. |
| `object_id` | string | Raw background object identifier when present. |
| `file_size` | int | Raw asset size when present. |
| `poster_version` | int | Raw PosterKit version when present. |
| `communication_safety_state` | int | Raw communication-safety state when present. |
| `version` | int | Raw background metadata version when present. |
| `cache_path` | string | Cache path next to the selected Messages database. |
| `cache_exists` | bool | Whether `cache_path` exists. |
| `watch_background_path` | string | Watch-background cache path when a background channel exists. |
| `watch_background_exists` | bool | Whether `watch_background_path` exists. |
| `latest_event` | object | Newest background set/clear event by message date, with `row_id`, `guid`, `action`, and `date`. |

### URL preview coalescing

Messages may store a link send as two rows: the user's text row and a later `com.apple.messages.URLBalloonProvider` preview row. `history`, `search`, `watch`, `messages.history`, and `watch.subscribe` coalesce those rows into one logical message when the preview immediately follows a same-chat/same-sender text row containing the preview URL. In batch reads the coalesced message includes:

| Field | Type | Notes |
|-------|------|-------|
| `id` | int | Preview rowid that was folded into the outer text message. |
| `guid` | string | Preview row GUID. |
| `balloon_bundle_id` | string | `com.apple.messages.URLBalloonProvider`. |
| `created_at` | ISO8601 | Preview row timestamp. |

Live watch calls do not delay the text message waiting for a preview. If the preview row arrives in a later poll after the text row was already emitted, imsg suppresses the preview row so consumers still receive one notification.

### Reaction extensions

Present on `imsg watch --reactions` events:

| Field | Type | Notes |
|-------|------|-------|
| `is_reaction` | bool | `true` for tapback events. |
| `reaction_type` | string | `love`, `like`, `dislike`, `laugh`, `emphasis`, `question`, or a custom emoji marker. |
| `reaction_emoji` | string | Custom emoji, when present. |
| `is_reaction_add` | bool | `true` for add, `false` for remove. |
| `reacted_to_guid` | string | The message guid this tapback targets. |

`history` deliberately hides reaction rows so they don't duplicate the reacted message. Reaction events only surface in the live watch stream.

### Native poll extension

Native Apple Messages polls are emitted as normal messages with a `poll` object. Existing message fields stay present and unchanged; poll rows often have an empty `text` field because the useful data is stored in the Messages extension payload. When a native created-poll payload has no title, imsg may backfill `poll.question` from the earliest clean caption row that replies to the poll.

| Field | Type | Notes |
|-------|------|-------|
| `kind` | string | `created`, `vote`, or `unknown`. |
| `event` | string | Route-friendly value: `imessage.poll.created`, `imessage.poll.voted`, or `imessage.poll.unknown`. |
| `poll_guid` | string | The poll's source message GUID when known. |
| `question` | string | Poll title or question when decoded. For native created polls with an empty payload title, this may be backfilled from the poll's plain caption row. |
| `options` | array | Poll options, each with `id` and `text`. |
| `vote` | object | First decoded vote update, with `option_id`, `participant`, and `event_type` when present. |
| `votes` | array | All decoded vote entries when the payload carries more than one. |
| `original_guid` | string | For vote rows, the original poll message GUID from `associated_message_guid`. |
| `creator` | string | Creator handle when the payload includes it. Creation rows may fall back to the sender handle. |
| `participants` | array | Handles seen in decoded poll metadata. |
| `metadata` | object | Raw-safe diagnostics only: bundle id, payload byte counts, URL scheme/host, query keys, and associated message type. Raw private payload bytes are never emitted. |

Example:

```json
{
  "poll": {
    "kind": "created",
    "event": "imessage.poll.created",
    "poll_guid": "A1B2",
    "question": "Dinner?",
    "options": [
      { "id": "opt-1", "text": "Pizza" },
      { "id": "opt-2", "text": "Sushi" }
    ]
  }
}
```

## Attachment

Inside the `attachments` array on a message:

| Field | Type | Notes |
|-------|------|-------|
| `filename` | string | Stored filename. |
| `transfer_name` | string | Original filename as sent. |
| `uti` | string | Apple UTI. |
| `mime_type` | string | Best-effort MIME. |
| `byte_size` | int | Size in bytes. |
| `is_sticker` | bool | Sticker-pack attachments. |
| `missing` | bool | Underlying file not on disk. |
| `path` | string | Resolved absolute path. |
| `converted_path` | string | Present with `--convert-attachments`. |
| `converted_mime_type` | string | Present with `--convert-attachments`. |

## Statistics aggregate

Returned as one object by `imsg stats --json` and as the result of JSON-RPC `messages.stats`.

| Field | Type | Notes |
|-------|------|-------|
| `total_messages` | int | Logical messages after reaction exclusion and URL-preview coalescing. |
| `sent_messages` | int | Outbound logical messages. |
| `received_messages` | int | Inbound logical messages. |
| `time_zone` | string | Resolved timezone used for `dates`. |
| `chats` | array | Counts grouped by chat. |
| `senders` | array | Inbound counts grouped by sender handle. |
| `services` | array | Counts grouped by message service. |
| `dates` | array | Counts grouped by local `YYYY-MM-DD` date. |
| `media` | object | Present only when `--media` / `include_media` is requested. Distinct attachment totals plus type/chat groups. |

See [Statistics](stats.md) for filtering, ordering, and timezone behavior.

## Conventions

- Every numeric field is a JSON number. `id`, `chat_id`, and `byte_size` are integers; nothing requires 64-bit JSON-string encoding.
- Times are ISO 8601 with explicit timezone (typically `Z`).
- Strings that aren't applicable are omitted, not set to `null`. Test with `field in obj`, not `obj.field === null`.
- Booleans are explicit `true` / `false`, never 0/1.
- Arrays are always present when documented (possibly empty).

## Stability

The JSON schema is treated as a public API. Field renames or removals are tracked in `CHANGELOG.md` with a "change" or "deprecation" note and gated to a minor release.

The 0.2.0 → 0.3.0 cycle did one large rename (camelCase → snake_case). Since 0.3.0 the schema has been additive only.
