---
title: Statistics
description: "Aggregate logical message counts and optional media totals from the local Messages database."
---

`imsg stats` reads `chat.db` without launching Messages.app or the IMCore bridge. It reports
logical messages rather than raw database rows: tapback add/remove rows are excluded, and a
matching text plus Apple URL-preview companion counts once.

```bash
imsg stats
imsg stats --time-zone Europe/Vienna --json
imsg stats --chat-id 42 --media --json
```

The default timezone is the process's local timezone. Pass an IANA identifier with
`--time-zone`; the resolved identifier is always returned as `time_zone`. Date buckets use that
timezone and the `YYYY-MM-DD` format.

`--chat-id` scopes every message and media dimension. The rowid must be positive and exist in the
selected database. An existing chat with no messages returns zero totals; an invalid or missing
row fails instead of silently returning whole-database statistics.

## JSON shape

The command emits one NDJSON object with:

- `total_messages`, `sent_messages`, and `received_messages`
- `chats`, `senders` (inbound authors), `services`, and `dates`
- `time_zone`
- `media` only when `--media` is requested

Media totals count each attachment row once even if Messages has duplicate join rows. Type groups
use UTI plus MIME type; chat groups count each attachment once per chat. Missing/negative byte
sizes contribute zero bytes.

All dimensions come from one deferred SQLite read transaction, so a busy Messages.app cannot make
the total and breakdowns observe different database snapshots.
