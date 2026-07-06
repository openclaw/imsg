---
title: Watch
description: "Stream new iMessage and SMS rows live, with filesystem-event triggers and a poll-based fallback."
---

`imsg watch` follows `chat.db` and emits each new message as soon as Messages writes it. It's the right primitive for agents, dashboards, notifiers, and anything that wants near-real-time inbound.

## Stream all chats

```bash
imsg watch --json
```

You'll see every new inbound and outbound message across every chat the database covers.

## Stream one chat

```bash
imsg watch --chat-id 42 --json
```

`--chat-id` is the simplest filter. For more advanced filtering use `--participants`, `--start`, `--end`, all of which mirror [`history`](history.md).

## Resuming from a cursor

For long-lived consumers — agents, sync jobs — store the last `id` (rowid) you successfully processed and resume:

```bash
imsg watch --chat-id 42 --since-rowid 9000 --json
```

`--since-rowid` is exclusive: `9000` means "everything strictly after rowid 9000."

If you don't pass `--since-rowid`, watch starts at the newest message at the moment of launch. Messages written before then are not replayed; use [`history`](history.md) for that.

## Reactions

By default, tapback events are excluded so the stream stays focused on actual messages. Opt in with `--reactions`:

```bash
imsg watch --chat-id 42 --reactions --json
```

Reaction events extend the message object with:

- `is_reaction` — `true` for tapback events.
- `reaction_type` — `love`, `like`, `dislike`, `laugh`, `emphasis`, `question`, or a custom emoji string.
- `reaction_emoji` — for custom emoji tapbacks.
- `is_reaction_add` — `true` when added, `false` when removed.
- `reacted_to_guid` — the message guid this tapback targets.

## Attachments

```bash
imsg watch --chat-id 42 --attachments --json
imsg watch --chat-id 42 --attachments --convert-attachments --json
```

Attachment metadata is reported the same way as [`history`](history.md). `--convert-attachments` requires `ffmpeg` on `PATH`; see [Attachments](attachments.md).

## Native polls

Native Apple Messages poll creation and vote updates are emitted without a separate flag. Poll vote rows are not tapbacks, so they do not require `--reactions`. When a native created poll has no payload title, watch output uses the same caption backfill as history so `poll.question` can still contain the visible poll question.

```bash
imsg watch --chat-id 42 --json \
  | jq -c 'select(.poll != null) | {id, guid, poll}'
```

Poll rows carry `poll.event` values suitable for routing:

- `imessage.poll.created`
- `imessage.poll.voted`
- `imessage.poll.unknown`

## Debounce

```bash
imsg watch --chat-id 42 --debounce 250ms --json
```

When Messages writes a message, it often follows up with WAL flushes, attachment metadata updates, and `is_from_me` corrections within a few milliseconds. The debouncer collapses those into one stable emission per row.
If a row appears before its chat metadata resolves, watch retries it briefly and
then drops it fail-closed instead of emitting an empty `chat_id=0` payload that
could look like a direct message.

- CLI default: `250ms`.
- RPC default: `500ms` (RPC's typical caller is an agent more sensitive to outbound echo races).

Lower the debounce if you need lower latency and can tolerate occasional duplicate emissions during database churn. Raise it if downstream consumers can't keep up.

`--debounce` accepts Go-style durations: `100ms`, `1s`, `2s500ms`.

## How it knows when to read

The watcher listens for `kqueue` filesystem events on:

- `~/Library/Messages/chat.db`
- `~/Library/Messages/chat.db-wal`
- `~/Library/Messages/chat.db-shm`
- `~/Library/Messages/`

Whenever any of those files change, the watcher checks for new rows past the cursor.
The directory watch lets it detect WAL sidecar creation, deletion, and replacement after
SQLite checkpoints.

## Polling fallback

macOS sometimes drops or coalesces filesystem events — especially under heavy I/O, after sleep/wake, or when Messages rotates the WAL sidecars. Without intervention, a watch session can go silent while the database keeps changing.

`imsg watch` runs a low-frequency poll alongside the event watcher. If the cursor falls behind the actual rowid, the poller catches up and emits the missed rows. You don't configure this — it's always on.
Each fallback poll also refreshes the file watches, so a rotated `chat.db-wal` or
`chat.db-shm` is reopened without needing an external `touch chat.db`.

This is the fix for the long-standing "watch goes silent after a while" class of bug. See `CHANGELOG.md` 0.6.0 entry.

## URL preview deduplication

When you send a link, Messages writes a "balloon" placeholder row first, then later replaces it once the preview metadata is fetched. Without dedup, watch would emit both. `imsg watch` deduplicates these without dropping unrelated messages from other chats — the dedup is keyed precisely on the balloon update path, not on text similarity.

## Output schema

Each line is a complete JSON object. See [JSON output → Message](json.md#message) for the full field list. For tapback events also see the reaction fields above. For native polls, see [JSON output → Native poll extension](json.md#native-poll-extension).

Lines are flushed immediately when stdout is buffered (e.g. piped through `jq -c`), so downstream consumers don't experience batching artifacts.
