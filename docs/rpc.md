---
title: JSON-RPC
description: "Long-running JSON-RPC 2.0 over stdio for chats, history, watch, and send — same surfaces as the CLI, one process."
---

`imsg rpc` exposes the read and send surfaces over JSON-RPC 2.0 on stdin/stdout. It's designed for agents and gateways that want a single long-lived process for chats, history, send, and watch — without a TCP port, daemon, or system service.

## Transport

- One JSON object per line on stdin (request) and stdout (response/notification).
- JSON-RPC 2.0 framing: `jsonrpc`, `id`, `method`, `params`.
- Notifications omit `id`.
- Stderr is reserved for human-readable diagnostics.
- Startup failures such as missing Full Disk Access are returned as JSON-RPC
  errors on the first request instead of human-readable stdout banners.

## Lifecycle

- The host process spawns one `imsg rpc` child.
- The child stays alive across many requests and one-or-more watch subscriptions.
- No TCP port. No launch agent. No `imsg` daemon to install.

The pattern intentionally mirrors language servers and the way `imsg`'s parent gateway (Clawdis) supervises subprocesses — a single signal-style child that exits cleanly when stdin closes.

## Methods

### `chats.list`

Params:

- `limit` (int, default 20)
- `unread_only` (bool, default `false`) — when true, return only chats with `unread_count > 0`; unavailable database schemas return an invalid-params error rather than an empty list

Result:

```json
{ "chats": [Chat] }
```

### `messages.stats`

Params:

- `chat_id` (int, optional)
- `time_zone` (IANA identifier, optional; defaults to the local timezone)
- `include_media` (bool, default `false`)

Result:

```json
{
  "total_messages": 123,
  "sent_messages": 60,
  "received_messages": 63,
  "time_zone": "Europe/Vienna",
  "chats": [],
  "senders": [],
  "services": [],
  "dates": []
}
```

When media is requested, `media` includes distinct attachment totals and bytes grouped by
UTI/MIME and chat. Otherwise the `media` key is omitted. Invalid, non-positive, or nonexistent
`chat_id` values return invalid params rather than widening to all chats.

### `messages.history`

Params:

- `chat_id` (int, required) — preferred identifier.
- `limit` (int, default 50)
- `participants` (array of handle strings, optional)
- `start` / `end` (ISO 8601, optional)
- `attachments` (bool, default `false`)

Result:

```json
{ "messages": [Message] }
```

### `messages.scheduled`

Reads future outbound Send Later rows from `chat.db`. This method is read-only and does not require the IMCore bridge.

Params:

- `limit` (positive int, default 50)

Result:

```json
{ "messages": [ScheduledMessage] }
```

Older Messages database schemas without scheduling columns return an invalid-params error rather than an ambiguous empty list.

### `watch.subscribe`

Params:

- `chat_id` (int, optional) — omit for all-chat stream.
- `since_rowid` (int, optional) — exclusive cursor.
- `participants` (array, optional)
- `start` / `end` (ISO 8601, optional)
- `attachments` (bool, default `false`)
- `include_reactions` (bool, default `false`)
- `debounce_ms` (int, default `500`)

Result:

```json
{ "subscription": 1 }
```

Notifications (one per emitted message):

```json
{
  "jsonrpc": "2.0",
  "method": "message",
  "params": {
    "subscription": 1,
    "message": { ... }
  }
}
```

The RPC default debounce (`500ms`) is intentionally higher than the CLI default (`250ms`). RPC's typical caller is an agent that just sent a message and is waiting for the inbound echo to settle (`is_from_me` correction, attachment metadata, …). 500ms is enough for those follow-ups to land before the message is emitted.

Like the CLI watch, RPC watch backs filesystem events with a low-frequency poll so a missed event or a rotated SQLite sidecar doesn't leave the subscription silent.

If a live all-chat row appears before Messages has joined it to a chat, RPC watch retries it briefly and then drops it fail-closed instead of emitting an empty `chat_id=0` direct-message-shaped payload.

### `watch.unsubscribe`

Params:

- `subscription` (int, required)

Result:

```json
{ "ok": true }
```

### `send`

Params (direct send):

- `to` (string, required)
- `text` (string, optional)
- `file` (string, optional)
- `service` (`imessage` | `sms` | `auto`, optional)
- `region` (string, optional)

Params (chat target):

- `chat_id` *or* `chat_identifier` *or* `chat_guid` — exactly one. `chat_id` is preferred.
- `text` / `file` as above.

Result:

```json
{ "ok": true, "id": 1979, "guid": "8DF..." }
```

`id` and `guid` are best-effort. `send` returns them when the inserted row can be observed in `chat.db` after Messages accepts the send. Attachment-only sends, delayed database writes, or ambiguous direct sends may return only `{"ok": true}`.

For chat-target sends, `send` also performs the [Tahoe ghost-row check](send.md#tahoe-ghost-row-protection): if Messages writes an empty unjoined SMS row instead of delivering, the call returns an error rather than `{"ok": true}`.

### `message.send_status`

Params:

- `guid` (string, required) — outgoing message GUID.

Result:

```json
{
  "ok": true,
  "guid": "8DF...",
  "send_state": "delivered",
  "service": "iMessage",
  "checked_at": "2026-05-28T20:43:00Z",
  "delivered_at": "2026-05-28T20:42:58Z",
  "status_fields": {
    "is_sent": true,
    "is_delivered": true,
    "is_finished": true,
    "error": 0,
    "date_delivered": "2026-05-28T20:42:58Z",
    "date_read": null,
    "is_delayed": false,
    "is_prepared": false,
    "is_pending_satellite_send": false,
    "was_downgraded": false
  }
}
```

`send_state` is normalized to `pending`, `sent`, `delivered`, or `failed`.
Missing rows return `pending` with `status_fields: null`.

### Bridge Message Actions

These methods require the IMCore bridge and target an existing chat with `chat_id`, `chat_identifier`, or `chat_guid`.

- `send.rich` sends text with optional `effect`, `subject`, `reply_to`, `part_index`, `dd_scan`, and `text_formatting`. Alternatively, pass only one chat target plus an HTTP(S) `url` to send an Apple URL-preview balloon. URL mode is iMessage-only and rejects text/send modifiers; metadata or image lookup failure falls back to a metadata-only card, never a plain-message send.
- `send.attachment` sends `file` or `path`, with optional `audio` / `is_audio` / `as_voice`.
- `tapback` sends or removes a reaction. Params: `message_id` or `message_guid`, plus `reaction` / `kind` / `emoji`, optional `remove`.
- `message.edit` edits `message_id` / `message_guid` with `text`.
- `message.unsend`, `message.delete`, and `message.notifyAnyways` target `message_id` / `message_guid`.
- `contacts.shouldShareContact` reads Apple Messages' advisory Name & Photo offer eligibility. The result includes `can_inspect_offer`, `can_share`, and tri-state `should_offer`.
- `contacts.shareContactCard` explicitly requests Apple Messages Name & Photo sharing. Despite the compatibility name, this does not send a vCard. Success reports `requested: true`, not delivery.

The two `contacts.*` compatibility methods accept `chat_id`, `chat_identifier`,
or `chat_guid`. Sharing discloses the local Messages profile to every chat
participant and must only be invoked after explicit user confirmation.

Result:

```json
{ "ok": true }
```

`send.rich` and `send.attachment` return `guid` / `message_id` when the bridge reports the sent message GUID.

### `handles.check`

Requires the IMCore bridge.

Params:

- `address` (string, required) — phone number or email address.
- `alias_type` (`phone` | `email`, optional) — inferred from `address` when omitted.
- `service` (`iMessage`, optional) — SMS checks are rejected.

Result:

```json
{
  "ok": true,
  "address": "+14155551212",
  "alias_type": "phone",
  "destination": "tel:+14155551212",
  "id_status": 1,
  "available": true,
  "service": "iMessage"
}
```

### Native polls

`poll.send` creates a native Apple Messages Polls extension balloon through the IMCore bridge. The bridge must be injected with `imsg launch`; the AppleScript transport cannot send native extension payloads. Messages does not render the poll payload title on the balloon, so `poll.send` also sends a best-effort plain caption message right after the poll. The caption defaults to `question`; pass `comment` when the visible caption should differ from the stored poll question.

Request:

```json
{"jsonrpc":"2.0","id":"poll","method":"poll.send","params":{"chat_id":42,"question":"Dinner?","options":["Pizza","Sushi"]}}
```

With a caption override:

```json
{"jsonrpc":"2.0","id":"poll","method":"poll.send","params":{"chat_id":42,"question":"Dinner?","comment":"Vote by 5pm","options":["Pizza","Sushi"]}}
```

Response:

```json
{"ok":true,"event":"imessage.poll.created","guid":"...","message_id":"...","poll":{"kind":"created","event":"imessage.poll.created","question":"Dinner?","options":[{"id":"...","text":"Pizza"},{"id":"...","text":"Sushi"}]}}
```

`poll.vote` casts a native vote after validating the poll and option against local history.
`polls.unvote` removes a selection with the same poll/option parameters:

```json
{"jsonrpc":"2.0","id":"vote","method":"poll.vote","params":{"chat_id":42,"poll_guid":"POLL-GUID","option_id":"OPTION-UUID"}}
{"jsonrpc":"2.0","id":"unvote","method":"polls.unvote","params":{"chat_id":42,"poll_guid":"POLL-GUID","option_id":"OPTION-UUID"}}
```

`messages.poll.send` is accepted as an alias for `poll.send`. The caption echo is deliberately best-effort: if the poll is created but the follow-up caption send fails, the RPC still returns the poll result to avoid retrying and creating a duplicate poll.

### Stickers

`send.sticker` sends a validated image file as a sticker-attributed IMCore
transfer. The bridge must be injected with `imsg launch`; AppleScript cannot
preserve sticker attribution. Stickers are iMessage-only. Accepted images are
PNG/APNG, GIF, or JPEG, at most 500 KiB, 618x618 pixels, 100 frames, and
25 million total decoded pixels.

Request:

```json
{"jsonrpc":"2.0","id":"sticker","method":"send.sticker","params":{"chat_id":42,"file":"~/Desktop/sticker.png","attach_to":"MESSAGE_GUID","part_index":0}}
```

Response:

```json
{"ok":true,"transfer_guid":"..."}
```

`guid` and `message_id` are included when Messages exposes the newly queued
message immediately; treat them as best-effort. `transfer_guid` is returned on
every successful bridge send.

Use exactly one of `chat_id`, `chat_identifier`, or `chat_guid`. `attach_to`
accepts a bare message GUID or `p:N/GUID`; `part_index` must agree with an
embedded part and is invalid without `attach_to`. Unknown parameters and
non-object params fail with invalid params rather than falling back.

## Objects

### Chat

See [JSON output → Chat list item](json.md#chat-list-item). Every field documented there appears in the RPC `chats.list` response.

### Message

See [JSON output → Message](json.md#message). When `include_reactions: true`, message notifications also include the reaction extension fields (`is_reaction`, `reaction_type`, `reaction_emoji`, `is_reaction_add`, `reacted_to_guid`).

Native Apple Messages polls are emitted by `messages.history` and `watch.subscribe` with the same `poll` object documented in [JSON output → Native poll extension](json.md#native-poll-extension). For inbound native polls whose payload title is empty, imsg backfills `poll.question` from the earliest clean caption row that replies to the poll.

`account_id`, `account_login`, `last_addressed_handle`, and outgoing `destination_caller_id` are read-only routing diagnostics; the AppleScript send API does not expose a `from` selector.

## Examples

Request `chats.list`:

```json
{"jsonrpc":"2.0","id":"1","method":"chats.list","params":{"limit":10}}
```

Response:

```json
{"jsonrpc":"2.0","id":"1","result":{"chats":[...]}}
```

Subscribe to a chat:

```json
{"jsonrpc":"2.0","id":"2","method":"watch.subscribe","params":{"chat_id":1}}
```

Notification on each new message:

```json
{"jsonrpc":"2.0","method":"message","params":{"subscription":2,"message":{...}}}
```

Send and receive verification:

```json
{"jsonrpc":"2.0","id":"3","method":"send","params":{"to":"+14155551212","text":"hi"}}
{"jsonrpc":"2.0","id":"3","result":{"ok":true,"transport":"applescript","id":1979,"guid":"8DF..."}}
```

`send` accepts `transport: "auto" | "bridge" | "applescript"`. `auto`
uses the IMCore bridge for existing chats when it is running, then falls back
to AppleScript. Use `bridge` when the caller requires private-API delivery and
should fail instead of falling back.
