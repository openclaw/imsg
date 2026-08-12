---
title: JSON-RPC
description: "Long-running JSON-RPC 2.0 over stdio for chats, history, watch, and send — same surfaces as the CLI, one process."
---

`imsg rpc` exposes the read and send surfaces over JSON-RPC 2.0 on stdin/stdout. It's designed for agents and gateways that want a single long-lived process for chats, history, send, and watch — without a TCP port, daemon, or system service.

## Transport

- One JSON object per line on stdin (request) and stdout (response/notification).
- JSON-RPC 2.0 framing: `jsonrpc` must be exactly `"2.0"`; `id` may be a string,
  number, or `null`; and `method` must be a non-empty string.
- `params` may be omitted or provided as a named JSON object. Arrays, scalars,
  and `null` are invalid params.
- Notifications omit `id`. They never receive a response, including when the
  method is unknown or its params are invalid.
- Stderr is reserved for human-readable diagnostics.
- The child starts even when the configured Messages database is absent or
  unreadable. `initialize` and `status` remain available, and stdout stays
  JSON-only. Database-backed requests return a typed, retryable error.

Each method accepts only the keys documented for it. Unknown keys are rejected
with `-32602` instead of being ignored. Values are type-strict: strings are not
parsed as numbers or booleans, numbers are not converted to strings or
booleans, booleans are not accepted as integers, and string arrays must contain
only strings. This is deliberate fail-closed behavior for long-running agents.

Supported compatibility aliases are explicit and method-specific:

- `chats.list`: `unreadOnly` for `unread_only`.
- `watch.subscribe`: `debounceMs` for `debounce_ms`.
- `send`: `textFormatting` or `formatting` for `text_formatting`; `replyTo`,
  `reply_to_guid`, or `message_guid` for `reply_to`; and `allowSMSFallback` for
  `allow_sms_fallback`.
- `send.rich`: `message` for `text`; camelCase forms for `part_index`,
  `dd_scan`, `effect_id`, and `text_formatting`; `effect` for `effect_id`; and
  the same reply aliases as `send`.
- `send.attachment`: `path` for `file`; `is_audio` or `as_voice` for `audio`;
  `partIndex` for `part_index`; and the same reply aliases as `send`.
- Poll methods accept their documented `messages.poll.*`/`polls.unvote` method
  aliases plus camelCase parameter forms such as `creatorHandle`, `pollGuid`,
  `optionId`, `optionIdentifier`, `optionIndex`, and `suppressComment`.
- Message mutations accept the existing `messageId`, `messageGuid`, and
  `message` target aliases, plus their documented text and part-index aliases.
- `send.multipart`: camelCase forms for `effect_id` and per-part
  `text_formatting`; `effect` is also accepted for `effect_id`.

Other spellings, including `chatId`, are not aliases and are rejected.

Protocol/framing failures use the JSON-RPC codes `-32700` (parse error),
`-32600` (invalid request), and `-32601` (unknown method). Caller-caused value,
selector, date, or supported-operation errors use `-32602` (invalid params).
Other runtime and permission failures use `-32603` (internal error).
`-32002` means the configured database is currently unavailable and can be
retried after the path or Full Disk Access is fixed. `-32003` means a read-only
bridge operation was requested while no already-running bridge was usable.
Delivery failures add two server codes: `-32001` means the
operation may have completed or remains in flight, and `-32004` means the
mutation lane is blocked by an earlier in-flight operation. Their `data` is an
object rather than the ordinary string and contains `retry_safe`,
`disposition`, `transport`, `operation`, and a redacted `detail`. Parse errors and invalid requests whose ID cannot be
established return the required `null` response ID.

The server admits at most 128 outstanding requests (running plus queued).
An identified request beyond that bound receives `-32000` (`Server busy`);
notifications beyond the bound are discarded without a response. Every stdout
record remains one complete JSON line even when concurrent reads finish at the
same time.

## Lifecycle

- The host process spawns one `imsg rpc` child.
- The child stays alive across many requests and one-or-more watch subscriptions.
- No TCP port. No launch agent. No `imsg` daemon to install.

The configured database is an optional, retryable RPC resource. Startup does
not open it. `initialize`, `status`, and every database-required request retry
after an earlier open failure. A successful open is cached only while the
configured path still identifies the same database file. Replacing or restoring
that path rotates new requests and status snapshots to a new database/watcher
generation; removing it makes new database-backed requests fail with `-32002`
until a readable replacement appears. A watch subscription keeps the exact
database and watcher bundle it started with, so rotation never swaps a live
subscription underneath its stream. Cursors from that subscription still belong
to its starting generation and must be discarded before reading from the
replacement. Chat metadata and participants are read from the subscription's
SQLite connection for each emission, while new requests use the current
generation.

`initialize`, `status`, and bridge capability probes never launch, kill, or
relaunch Messages.app. Bridge-only RPC methods first check the existing ready
lock and use the already-running v2 inbox directly; run `imsg launch`
separately before using them. The shipped `typing` and `read` methods are
exceptions: typing retains its bridge-first, delivery-safe direct-IMCore
fallback, while read retains IMCore bridge activation. Either may activate
Messages.app. Direct AppleScript `send` may activate it too. Bridge-oriented
CLI commands retain their documented launch behavior.

The pattern intentionally mirrors language servers and the way `imsg`'s parent gateway (Clawdis) supervises subprocesses — a single signal-style child that exits cleanly when stdin closes.

Request execution uses three independent lanes:

- Message, chat, group, poll, contact-sharing, typing, and read-state mutations
  run through one FIFO worker. A mutation includes validation, staging, bridge
  work, its response, and any post-send verification before the next mutation
  starts.
- Read-only status, history, chat, statistics, cursor, scheduled-message, send-status,
  handle-check, and contact-sharing inspection requests run with up to four in
  flight. Their responses may complete out of input order.
- Initialize, parse errors, unknown methods, and watch subscribe/unsubscribe control are
  independent of both work lanes, so unsubscribe does not wait for a send or a
  saturated read lane.

Closing stdin stops admission, cancels and awaits every watch subscription,
then drains all already accepted requests and flushes stdout before `run()`
returns. Parent-task cancellation cancels subscriptions plus read/control work,
but never cancels an already-started mutation or claims it did not execute.
Accepted mutations, including those not yet started, conservatively drain in
FIFO order during normal EOF or parent cancellation; the server never invents
a retry-safe result for work it already admitted.

Bridge and AppleScript transports do expose a delivery disposition for failed
mutations:

- `not_started` proves the transport never dispatched the operation;
  `retry_safe` is `true`.
- `may_have_completed` means no operation remains observable, but delivery
  cannot be proved either way. Do not retry automatically.
- `still_in_flight` means the operation can continue after the response. The
  server poisons only the mutation lane: queued and future mutations receive
  `-32004`, while reads, watch subscriptions, and unsubscribe remain healthy.

The poison is intentionally process-local. Restart the `imsg rpc` child to
clear it after independently resolving the uncertain operation. Notifications
remain silent when rejected, as required by JSON-RPC.

A `watch.subscribe` request already queued when EOF closes subscription
admission receives `-32000` (`Server busy`) with `server is shutting down`; it
never receives a successful subscription ID for a stream that cannot activate.

## Methods

### `initialize`

Returns the same readiness snapshot as `status`. It is optional, idempotent,
and may be called at any time; it does not establish session state.

Params:

- `protocol_version` (int, optional) — when supplied, must be `1`.

Unknown params and unsupported versions return invalid params.

### `status`

Accepts no params (an explicit empty object is allowed). It retries the
database open, probes only an already-running bridge, and returns no setup
prose or message content:

```json
{
  "version": "0.x.y",
  "protocol_version": 1,
  "database": {
    "path": "/Users/me/Library/Messages/chat.db",
    "ready": true,
    "features": {
      "unread_state": true,
      "scheduled_messages": true,
      "reactions": true,
      "reply_context": true,
      "routing_metadata": true,
      "balloon_payloads": true
    }
  },
  "bridge": {
    "ready": false,
    "error": "The bridge is not started. Run imsg launch explicitly before using bridge methods."
  },
  "contacts": { "available": true },
  "methods": ["initialize", "status", "watch.unsubscribe", "chats.list", "send", "typing", "read"],
  "supported_methods": ["initialize", "status", "watch.unsubscribe", "..."]
}
```

`methods` is the structurally usable surface at that instant. Database reads
appear only while the database is ready; `messages.scheduled` also requires
detected scheduling columns. On macOS, `typing` and `read` remain usable
independently of bridge readiness because they retain their shipped
fallback/activation behavior. Bridge-only methods require a successful
non-launching v2 status probe and are conservatively gated by the selectors the
bridge reports (for example stickers, polls, editing, unsend, chat deletion,
and Name & Photo). Aliases appear together. `supported_methods` is the compiled
union for protocol negotiation and does not claim current readiness.

When the database is ready, `database.features` exposes feature-level booleans,
not raw SQLite column names. When it is down, `database.error` is redacted and
actionable. `contacts.available` is refreshed during the child lifetime; a
permission grant can become usable without restarting, while revocation clears
cached contact data. Contact-backed sends normalize phone numbers using that
request's `region`. A successful bridge probe additionally reports
`bridge_version`, `v2_ready`, `registry_available`, and `selectors` supplied by
the helper.

### `chats.list`

Params:

- `limit` (positive int, default 20)
- `unread_only` (bool, default `false`) — when true, return only chats with `unread_count > 0`; unavailable database schemas return an invalid-params error rather than an empty list

Result:

```json
{ "chats": [Chat] }
```

### `chats.create`

Params:

- `addresses` (non-empty array of phone/email strings, required)
- `service` (`iMessage`, optional) — matched case-insensitively and normalized
  to `iMessage`; other services are rejected
- `name` (string, optional)
- `text` (string, optional initial message)

This bridge-backed method is iMessage-only, matching `imsg chat-create`.

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
- `limit` (positive int, default 50)
- `participants` (array of handle strings, optional)
- `start` / `end` (ISO 8601, optional)
- `attachments` (bool, default `false`)

Result:

```json
{ "messages": [Message] }
```

The `attachments` array remains present on every message and is populated only
when `attachments` is true.

### `messages.search`

Searches local `chat.db` through the same logical-message and JSON payload
pipeline as `imsg search`; it never invokes the bridge.

Params:

- `query` (non-empty string, required)
- `match` (`contains` | `exact`, default `contains`)
- `limit` (positive int, default 50, maximum 100)

Result:

```json
{ "messages": [Message] }
```

Search results always contain an empty `attachments` array.

### `messages.after`

Reads a bounded page in stable message ROWID order. This is the resumable
history surface for message catchup; unlike `messages.history`, it does not
order by timestamp or return the newest rows first.

Params:

- `since_rowid` (int, required) — exclusive, non-negative cursor.
- `chat_id` (int, optional) — omit to page across all chats.
- `limit` (int, default 100, maximum 500)
- `attachments` (bool, default `false`)
- `convert_attachments` (bool, default `false`)
- `include_reactions` (bool, default `false`) — include standalone reaction
  events in the ordered scan.

Result:

```json
{
  "messages": [Message],
  "next_rowid": 500,
  "has_more": true
}
```

Messages are ordered by `message.ROWID ASC`, including when timestamps are
equal. `limit` bounds the returned user-visible messages; the scan can consume
additional URL-preview rows while coalescing or suppressing them. `next_rowid`
is the authoritative physical scan cursor and may therefore advance past the
final returned message. A page can be empty when only suppressed preview rows
remain. Persist `next_rowid` after every response, then request another page
while `has_more` is true. Do not infer pagination state from the message count
or final message id. Set `include_reactions` to `true` when the cursor must also
cover reaction events; with the default, the cursor tracks user-visible message
catchup only.

ROWID cursors are scoped to the exact Messages database instance that produced
them. They are not portable between machines, accounts, or database files, and
they are not durable across replacement, restoration, or recreation of
`chat.db`. After any database replacement, discard the saved cursor and start a
new scan from a cursor appropriate for that database instance.

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
- `buffer_limit` (int, default `256`, range `1...4096`) — maximum eligible
  messages waiting for this subscriber; `bufferLimit` is the explicit
  camelCase compatibility alias.

Result:

```json
{ "subscription": 1, "buffer_limit": 256 }
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

The server permits at most 64 pending or active subscriptions. A 65th
identified subscribe request receives `-32000` (`Server busy`). The subscribe
response is written before that subscription can emit its first notification.
`watch.unsubscribe` cancels and awaits the subscription before returning
`{"ok":true}`, so no notification for that subscription can follow the
unsubscribe response.

Participant and date filters run before buffer admission. If the bounded
buffer fills, already accepted messages drain first and the subscription then
ends with one terminal notification:

```json
{
  "jsonrpc": "2.0",
  "method": "watch.overflow",
  "params": {
    "subscription": 1,
    "resume_after_rowid": 9000,
    "reason": "buffer_limit_exceeded",
    "terminal": true
  }
}
```

No generic `error` notification accompanies this overflow. Resume with
`messages.after` using `since_rowid` equal to `resume_after_rowid`, or create a
new watch subscription with that cursor. The cursor is at or before the first
dropped eligible message: duplicate replay is possible, but an eligible
message is never skipped.

If a live all-chat row appears before Messages has joined it to a chat, RPC watch retries it briefly and then drops it fail-closed instead of emitting an empty `chat_id=0` direct-message-shaped payload.

### `bridge.events.subscribe`

macOS only. Subscribes to typing and alias-removal events from an existing v2
bridge without launching Messages. The method appears in status `methods` only
when the non-launching bridge probe succeeds and the event path is a readable
regular file. It remains in `supported_methods` on macOS so callers can
distinguish a temporarily inactive bridge from an unsupported build.

Params:

- `buffer_limit` (int, default `256`, range `1...4096`)

Result:

```json
{ "subscription": 2, "buffer_limit": 256, "resumable": false }
```

Each event uses the normalized event-log shape:

```json
{
  "jsonrpc": "2.0",
  "method": "bridge.event",
  "params": {
    "subscription": 2,
    "event": {
      "event": "started-typing",
      "ts": "2026-08-10T00:00:00Z",
      "data": { "chatGuid": "iMessage;-;+15551234567" }
    }
  }
}
```

Bridge events begin at the current event-log EOF and are not replayed or
resumable. Rotation preserves the old log's remaining order before reading the
new file from offset zero. This ordering is independent of `watch.subscribe`;
no ordering between database messages and bridge events is promised.

The subscription shares the server-wide 64-subscription cap and ID space with
database watches. It deliberately reuses `watch.unsubscribe`; awaiting that
response guarantees no later notification for the shared subscription ID.
Process EOF performs the same source cleanup silently.

On the first event rejected by a full buffer, accepted events drain and the
stream emits one terminal notification with no ROWID or cursor:

```json
{
  "jsonrpc": "2.0",
  "method": "bridge.events.overflow",
  "params": {
    "subscription": 2,
    "reason": "buffer_limit_exceeded",
    "resumable": false,
    "terminal": true
  }
}
```

Open, read, and other source failures terminate with
`bridge.events.error`. Its `error` object contains a stable `code` and an
actionable `message`; cancellation does not emit an error.

### `watch.unsubscribe`

Params:

- `subscription` (int, required)

Result:

```json
{ "ok": true }
```

Cancellation is silent and does not produce a generic subscription error.

### `send`

Params (direct send):

- `to` (string, required)
- `text` (string, optional)
- `file` (string, optional)
- `service` (`imessage` | `sms` | `auto`, optional)
- `region` (string, optional)
- `allow_sms_fallback` (bool, default `true`) — gates only the narrow
  `service: auto`, direct-recipient, text-only retry described below; false
  leaves service selection on `auto` but disables that retry

Params (chat target):

- exactly one of `chat_id`, `chat_identifier`, or `chat_guid`.
- `text` / `file` as above.

`to` and chat selectors are mutually exclusive. Direct sends require `to` and
no chat selector; chat-target sends require exactly one selector and no `to`.

Result:

```json
{ "ok": true, "id": 1979, "guid": "8DF..." }
```

`id` and `guid` are best-effort. `send` returns them when the inserted row can be observed in `chat.db` after Messages accepts the send. Attachment-only sends, delayed database writes, or ambiguous direct sends may return only `{"ok": true}`.

### `send.tracked`

Sends exactly one text message through the already-running IMCore bridge with a
caller-owned message GUID. This method never falls back to AppleScript and never
retries after an uncertain bridge result.

Params are the text-send subset of `send`, plus:

- `attempt_id` (UUID string, required) — becomes the outgoing `IMMessage` GUID.

Attachments are rejected. The method is advertised by `imsg status --json`
only when the running injected helper reports caller-owned GUID preservation
and reservation support; the RPC method is usable only while the Messages
database is also readable. IDs already present in message history or reserved
by another tracked send are rejected
before dispatch. On success, `attempt_id`, `guid`, and `message_id` all identify
the exact same message. If the RPC response is lost, query `message.send_status`
with that UUID instead of matching message history by recipient, text, or
timestamp. The UUID is a correlation marker, not authorization to read or mutate
a message.

Direct `to` sends and explicit `chat_identifier` / `chat_guid` targets remain
usable while the database is down. In that state `send` skips history-based
service inference, direct-chat lookup, and post-send row verification, then
returns only fields observable from the chosen transport. A `chat_id` target
always requires the database and returns `-32002` while it is unavailable.

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

These methods require an already-running IMCore bridge and target an existing chat with
exactly one of `chat_id`, `chat_identifier`, or `chat_guid`. Supplying multiple
selectors is invalid and no bridge operation is attempted.

An explicit `chat_guid` or `chat_identifier` does not require `chat.db` merely
to reach the bridge. `chat_id` always does. Operations that validate local
membership or payload state—poll vote/unvote and stickers—still require the
database even with an explicit GUID. Strictly verified `send.rich` file/path
mode and `send.multipart` also require it. Rich-link mode requires a stored
existing iMessage chat; ordinary `send.rich` text does not.

- `send.rich` sends text with optional `effect`, `subject`, `reply_to`, `part_index`, `dd_scan`, and `text_formatting`. It also accepts `file` or `path` and securely stages the file before sending it through the attachment bridge while preserving those same caption/effect/subject/reply/part/formatting semantics. Attachment capability is checked before staging or publishing the send. Alternatively, pass only one chat target plus an HTTP(S) `url` to send an Apple URL-preview balloon. URL mode is iMessage-only and rejects text, file, and other send modifiers; metadata or image lookup failure falls back to a metadata-only card, never a plain-message send.
- `send.attachment` sends `file` or `path`, with optional `audio` / `is_audio` / `as_voice`. Pass `reply_to` (or `replyTo`, `reply_to_guid`, or `message_guid`) to reply to an existing message. An optional non-negative integer `part_index` / `partIndex` selects that message's part and is invalid without a reply target.
- `send.multipart` sends 1–20 text parts. `parts` is a required array of objects containing a non-empty `text` string and optional `text_formatting` array. Top-level `effect` / `effect_id` and `subject` match `imsg send-multipart`. File, attachment, and mention parts are rejected before bridge dispatch.
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

`send.rich` file/path mode and `send.multipart` return success only after a
matching outgoing row is observed in the resolved chat. Their successful
results include numeric `id`, `guid` / `message_id`, and `chat_guid`; an
unobserved result is reported as delivery outcome unknown (`-32001`) and must
not be retried automatically. Existing `send.rich` text/URL mode and
`send.attachment` return `guid` / `message_id` and `chat_guid` when available.
`send.multipart` additionally returns `parts_count`.

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

`poll.send` creates a native Apple Messages Polls extension balloon through the IMCore bridge. The bridge must be injected with `imsg launch`; the AppleScript transport cannot send native extension payloads. Messages does not render the poll payload title on the balloon, so `poll.send` also sends a best-effort plain caption message right after the poll. The caption defaults to `question`; pass `comment` when the visible caption should differ from the stored poll question, or set `suppress_comment` to `true` when the caller already sent its own visible context and needs only the poll balloon. `comment` and `suppress_comment: true` are mutually exclusive. The camelCase alias `suppressComment` is also accepted.

Request:

```json
{"jsonrpc":"2.0","id":"poll","method":"poll.send","params":{"chat_id":42,"question":"Dinner?","options":["Pizza","Sushi"]}}
```

With a caption override:

```json
{"jsonrpc":"2.0","id":"poll","method":"poll.send","params":{"chat_id":42,"question":"Dinner?","comment":"Vote by 5pm","options":["Pizza","Sushi"]}}
```

Without a caption:

```json
{"jsonrpc":"2.0","id":"poll","method":"poll.send","params":{"chat_id":42,"question":"Dinner?","suppress_comment":true,"options":["Pizza","Sushi"]}}
```

Response:

```json
{"ok":true,"event":"imessage.poll.created","guid":"...","message_id":"...","poll":{"kind":"created","event":"imessage.poll.created","question":"Dinner?","options":[{"id":"...","text":"Pizza"},{"id":"...","text":"Sushi"}]}}
```

`poll.vote` casts a native vote after validating the poll and option against local history.
`poll.unvote`, `polls.unvote`, and `messages.poll.unvote` remove a selection with the same poll/option parameters. Pass exactly one option selector: `option_id` (stable option ID), `option_index` (one-based option position), or `option` (case-insensitive option text). The camelCase aliases `optionId` / `optionIdentifier` and `optionIndex` are also accepted. Every selector is resolved against the decoded poll options; `option_text` remains response metadata and is not trusted as a resolved input selector.

Dynamic status advertises vote only when the database exposes readable balloon
payload columns. Unvote additionally requires reaction-linkage columns because
it must reconstruct the caller's currently selected options.

```json
{"jsonrpc":"2.0","id":"vote","method":"poll.vote","params":{"chat_id":42,"poll_guid":"POLL-GUID","option_id":"OPTION-UUID"}}
{"jsonrpc":"2.0","id":"vote-index","method":"poll.vote","params":{"chat_id":42,"poll_guid":"POLL-GUID","option_index":2}}
{"jsonrpc":"2.0","id":"unvote","method":"polls.unvote","params":{"chat_id":42,"poll_guid":"POLL-GUID","option":"Sushi"}}
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
uses the IMCore bridge for existing chats when it is running. It falls back to
AppleScript only when the bridge is not ready or returns authoritative
`not_started`; a timeout, cancellation, vanished request, claimed request,
malformed response, or other uncertain post-publication failure never falls
back. Use `bridge` when the caller requires private-API delivery and should
fail instead of falling back. Replies remain bridge-only.
