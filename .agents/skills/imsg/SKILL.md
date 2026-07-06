---
name: imsg
description: "iMessage/SMS: local history, contacts, live watch, and requested sends."
---

# imsg

`imsg` reads `~/Library/Messages/chat.db` directly and sends through Messages.app automation. Reading is local and safe. **Sending, reacting, marking read, typing indicators, and any chat mutation require an explicit user request** — confirm recipient, service, and content in your final summary.

## Ground rules

- Every read command supports `--json` and emits **NDJSON** (one object per line). Pipe to `jq -s` to get an array. Stdout carries only JSON; progress and warnings go to stderr.
- Two capability tiers:
  - **Standard** (normal permissions): `chats`, `group`, `history`, `watch`, `search`, `send`, `react`, `nickname --local`, `account --local`, `whois --local`.
  - **Bridge** (SIP disabled + `imsg launch` dylib injection): `send-rich`, `send-multipart`, `send-attachment`, `tapback`, `poll`, `edit`, `unsend`, `delete-message`, `read`, `typing`, `notify-anyways`, `chat-*`, and default-mode `account`/`whois`/`nickname`.
- Check availability with `imsg status --json` before using bridge commands. If the bridge is down, use a standard command only when it preserves the requested semantics; otherwise stop and explain. Never turn a reply/effect/subject into a plain send or a GUID-targeted tapback into `react`, and never suggest disabling SIP unprompted.
- Full command and flag reference: `imsg completions llm`.

## Preconditions

```bash
imsg status --json                                        # feature availability + setup hints
sqlite3 ~/Library/Messages/chat.db 'pragma quick_check;'  # fails => terminal lacks Full Disk Access
```

## Reading

Resolve a person visible in the Messages.app UI from `chats`, not `search`. The UI name usually surfaces as `contact_name` (Contacts permission); it does not appear in `imsg search` results, raw `message.text`, or the DB `handle` table. **No search hits is not proof the contact doesn't exist.**

```bash
imsg chats --limit 200 --json | jq -s '.[] | select((.contact_name // .display_name // .name // .identifier // "" | ascii_downcase) | contains("beatrix"))'
```

Then inspect and read the chat by rowid:

```bash
imsg group --chat-id ID --json                 # identity + participants; check before automating
imsg history --chat-id ID --limit 50 --json | jq -s
imsg history --chat-id ID --start 2025-01-01T00:00:00Z --end 2025-02-01T00:00:00Z --json
```

- Chat `id` is the `chat.db` rowid: stable on one machine, the preferred `--chat-id` handle. `identifier` and `guid` are portable across machines.
- `--start` is inclusive, `--end` exclusive; both take ISO8601. Use absolute timestamps for date-scoped questions.
- `--attachments` adds attachment metadata; `--convert-attachments` converts CAF→M4A / GIF→PNG for model consumption.
- `imsg search --query "pizza tonight" --json` searches message bodies only (`--match contains` default, `exact` available).
- SIP-free lookups: `imsg whois --address "+15551234567" --type phone --local`, `imsg nickname --address "+15551234567" --local --json`, `imsg account --local --json`. Note `nickname --local` returns *your* AddressBook label for the handle; the iMessage-shared nickname needs default-mode `nickname` via the bridge.
- Direct `sqlite3` queries are a last resort; the `handle` table lacks the resolved names `imsg chats` provides.

## Streaming

```bash
imsg watch --chat-id ID --json                 # filesystem events with polling fallback
imsg watch --since-rowid N --json              # resume from a message id cursor
```

Message `id` doubles as the watch cursor: persist the last-seen id and pass it back via `--since-rowid`. Add `--reactions` for tapback add/remove events and `--attachments` for attachment metadata.

## Sending (explicit request only)

```bash
imsg send --to "+15551234567" --text "message" --service auto
imsg send --chat-id ID --text "message"        # prefer for groups: no address ambiguity
imsg send --to "+15551234567" --file ~/Desktop/pic.jpg
```

- `--service auto` prefers iMessage and falls back to SMS for text-only phone sends; `--no-sms-fallback` disables that.
- `imsg react --chat-id ID --reaction like` (AppleScript) only targets the **most recent incoming message** and needs Accessibility permission. To react to a specific message by GUID, use bridge `tapback`.

## Bridge extras

Only after `imsg status` confirms the bridge is loaded (`imsg launch` injects it; refuses when SIP is on; macOS 26 entitlement gates can block features even with SIP off):

```bash
imsg send-rich --chat 'iMessage;-;+15551234567' --text 'hi' --reply-to MSG_GUID   # replies, effects, subjects
imsg poll send --chat GUID --question 'Dinner?' --option 'Pizza' --option 'Sushi' --comment 'Vote by 5pm'
imsg edit --chat GUID --message MSG_GUID --new-text 'updated'                     # macOS 13+
imsg chat-create --addresses '+15551234567,+15559876543' --name 'Crew'
```

`poll send` echoes `--question` as a best-effort plain caption after the Polls balloon; `--comment` overrides that caption. Do not retry automatically when only the caption fails: the poll may already be delivered. `history` and `watch` backfill a title-less inbound native poll's `poll.question` from its clean caption row.

Destructive bridge commands — `unsend`, `delete-message`, `chat-delete`, `chat-leave`, `chat-remove-member` — need per-action user confirmation.

## Verification

For repo edits:

```bash
make test
make build
./bin/imsg chats --limit 3 --json | jq -s      # live read proof against the local DB
```
