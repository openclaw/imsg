---
title: History
description: "Read message history from one chat with optional date, participant, and attachment filters."
---

`imsg history` reads messages from a single chat in chronological order. It's the bread-and-butter command for one-shot reads — search, archive, summarize, transcribe.

## Basic read

```bash
imsg history --chat-id 42 --limit 50
imsg history --chat-id 42 --limit 50 --json | jq -s
```

`--limit` defaults to 50 and applies *after* filters. So `--limit 20 --start ...` returns up to 20 messages from inside the date window, not 20 messages globally then date-filtered.

## Date windows

```bash
imsg history --chat-id 42 \
  --start 2026-05-01T00:00:00Z \
  --end   2026-05-06T00:00:00Z \
  --json
```

Both bounds accept ISO 8601 with explicit timezone. Either bound is optional:

```bash
# Everything since May 1st.
imsg history --chat-id 42 --start 2026-05-01T00:00:00Z --json

# Everything before May 6th.
imsg history --chat-id 42 --end 2026-05-06T00:00:00Z --json
```

## Participant filters

For group chats, narrow to messages from specific people:

```bash
imsg history --chat-id 42 --participants "+14155551212,jane@example.com" --json
```

Match is on the message's `sender` (raw handle), not the resolved contact name. Pass a comma-separated list.

## Attachments

`--attachments` adds an `attachments` array to each message containing filename, UTI, MIME type, byte count, and resolved on-disk path:

```bash
imsg history --chat-id 42 --attachments --json
```

`--convert-attachments` additionally exposes model-friendly variants when `ffmpeg` is available — CAF audio → M4A, GIF → first-frame PNG. See [Attachments](attachments.md).

## Recovering text from attributed bodies

Some Messages rows store rich text in a binary `attributedBody` column with the plain `text` column empty. `imsg history` decodes the typed-stream payload (including UTF-16LE BOM bodies) and surfaces the recovered text in the standard `text` field. No flag needed; this is on by default.

If a message is still empty, the source row genuinely had no text — usually a sticker, link preview, or attachment-only message.

## Reactions in history

Tapback rows (`Liked "..."`, `Loved "..."`, etc.) are hidden from `history` output by design. They'd otherwise duplicate every reacted message. To see tapbacks, use [`imsg watch --reactions`](watch.md#reactions); the live stream surfaces add and remove events with `is_reaction`, `reaction_type`, and `reacted_to_guid`.

## Native polls

Native Apple Messages polls are decoded when Messages stores them as the Polls extension balloon (`com.apple.messages.Polls`). Creation rows include `poll.kind == "created"` with the question and options when available. Vote update rows include `poll.kind == "vote"` and `poll.original_guid` pointing back to the poll message.

```bash
imsg history --chat-id 42 --json \
  | jq -c 'select(.poll != null) | {id, guid, poll}'
```

Unknown or changed Polls payload variants are still emitted with `poll.kind == "unknown"` and raw-safe metadata. `imsg` does not emit the private raw payload bytes.

Native poll creation is available through the bridge:

```bash
imsg poll send --chat 'iMessage;-;+15551234567' \
  --question 'Dinner?' \
  --option 'Pizza' \
  --option 'Sushi'
```

You can also use `--chat-id <id>` from `imsg chats`.

Cast a vote using one selector. The index is 1-based; `imsg` resolves it to the
poll's stable option identifier before sending:

```bash
imsg poll vote --chat-id <id> --poll <poll-guid> --option-index 2
```

On macOS 26.4, use imsg 0.12.2 or later. Earlier builds could create a local
vote row without the Polls payload, so the recipient's poll did not update.

### Manual native poll test plan

1. Create a native poll in Messages from an iPhone or Mac.
2. Run `imsg history --chat-id <chat-id> --json | jq -c 'select(.poll != null) | {id, guid, poll}'` and verify the creation row has `poll.kind == "created"` with decoded question/options.
3. Vote on the poll from another participant/device.
4. Run `imsg watch --chat-id <chat-id> --json | jq -c 'select(.poll != null)'` while the vote happens, or re-run history, and verify the vote row has `poll.kind == "vote"`, `poll.original_guid` set to the original poll GUID, and `poll.vote.option_id` set.
5. Send a poll with `imsg poll send --chat-id <id> --question "..." --option "A" --option "B"` and verify it renders as a native Messages poll on iOS/macOS.
6. Vote with `imsg poll vote --chat-id <id> --poll <poll-guid> --option-index 2`, then verify the new row has `poll.kind == "vote"`, the original GUID, and the selected option.
7. If Apple changes the private Polls payload shape, verify the row still emits `poll.kind == "unknown"` with metadata and no raw payload bytes.

## Performance

JSON history batches attachment and reaction lookups in one pass per request, so large `--limit` values stay cheap. Reading 1000 messages with `--attachments --json` is bound by SQLite, not by per-row queries.

For very large reads, prefer streaming through `jq` rather than buffering the whole result:

```bash
imsg history --chat-id 42 --limit 5000 --json \
  | jq -c 'select(.is_from_me == false)' \
  > inbound.ndjson
```

## Message object

See [JSON output](json.md#message) for the canonical schema. Every history result has at minimum:

`id`, `chat_id`, `chat_identifier`, `chat_guid`, `chat_name`, `participants`, `is_group`, `guid`, `reply_to_guid`, `destination_caller_id`, `sender`, `sender_name`, `is_from_me`, `text`, `created_at`.

When `--attachments` is set, also: `attachments[]`. Native polls include `poll`. Reactions only appear in `watch --reactions` output.
