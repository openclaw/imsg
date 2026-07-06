# imsg

![imsg banner](docs/assets/readme-banner.jpg)

Read, watch, and send iMessage / SMS from the macOS terminal — with stable JSON
and JSON-RPC surfaces designed for agents, scripts, and long-running
integrations.

`imsg` reads `~/Library/Messages/chat.db` directly, streams new rows over
filesystem events (with a polling fallback), and drives Messages.app through
its public AppleScript automation surface. Advanced IMCore controls (read
receipts, typing indicators, edit/unsend, group management, rich sends) are
opt-in behind a SIP-disabled dylib injection. Linux builds are a read-only
preview against a `chat.db` copied from macOS.

Full docs: **[imsg.sh](https://imsg.sh)**.
[Quickstart](https://imsg.sh/quickstart) ·
[JSON schema](https://imsg.sh/json) ·
[JSON-RPC](https://imsg.sh/rpc) ·
[Changelog](CHANGELOG.md)

## Highlights

- **Local-first reads.** Chats, history, attachments, and search query
  `chat.db` directly — no daemon, no network round-trip.
- **Live streams.** `imsg watch` follows filesystem events on `chat.db` and
  falls back to a lightweight poll when macOS drops events or rotates SQLite
  WAL sidecars.
- **Send through Messages.app.** Text, files, and standard tapbacks ride the
  public AppleScript surface — no private send APIs required.
- **Group-aware.** Direct chats, group threads, participants, GUIDs, and
  per-chat account routing hints all show up in JSON.
- **Built for agents.** Stable JSON-RPC over stdio, deterministic JSON
  schemas, and `imsg completions llm` for in-context CLI help.
- **Contacts integration.** Resolves names from Address Book when permission
  is granted, while keeping raw handles in the output.
- **Attachment-aware.** Filenames, UTIs, byte counts, resolved paths, and
  optional CAF→M4A / GIF→PNG conversion for model consumers.
- **Advanced IMCore (opt-in).** Edit, unsend, delete, rich-text formatting,
  effects, reply threading, group create/rename/photo, member add/remove,
  read receipts, typing indicators, and live event streams via the bridge.
- **Linux read-only preview.** Inspect a copied Messages database from a Linux
  host. No sending, no Messages.app integration.

## Requirements

- macOS 14 or newer (macOS 26 / Tahoe supported, with caveats noted below).
- Messages.app signed in to iMessage and/or SMS relay.
- Full Disk Access for the terminal or parent app that launches `imsg`.
- Automation permission for Messages.app when using `send` or `react`.
- Optional Contacts permission for name resolution.
- Optional `ffmpeg` on `PATH` for receive-side attachment conversion.

For SMS, enable Text Message Forwarding on your iPhone for this Mac.

Linux support is read-only and requires an existing Messages database copied
from macOS. It does not send, react, mark read, show typing, launch
Messages.app, or access iMessage/SMS accounts on Linux.

## Install

```bash
brew install steipete/tap/imsg
imsg --version
```

Build from source:

```bash
make build
./bin/imsg --help
```

## Quickstart

```bash
# List recent chats.
imsg chats --limit 10 --json | jq -s

# Inspect one chat before automating against it.
imsg group --chat-id 42 --json

# Read history with attachment metadata.
imsg history --chat-id 42 --limit 20 --attachments --json

# Stream new messages, including tapbacks.
imsg watch --chat-id 42 --reactions --json

# Send a message — auto-pick iMessage or SMS.
imsg send --to "+14155551212" --text "on my way"

# Send a file (image, audio, document).
imsg send --to "Jane Appleseed" --file ~/Desktop/voice.m4a

# Send a standard tapback.
imsg react --chat-id 42 --reaction like

# Search local history.
imsg search --query "pizza" --match contains
```

`--json` emits one JSON object per line. Pipe to `jq -s` to materialize an
array, or stream it to whatever consumer you're wiring up. Human progress and
warnings always go to stderr so pipes stay parseable.

## Commands

Read, watch, and send (no special permissions beyond Full Disk Access and
Automation):

- `imsg chats [--limit 20] [--json]`
- `imsg group --chat-id <id> [--json]`
- `imsg history --chat-id <id> [--limit 50] [--attachments] [--convert-attachments] [--participants <handles>] [--start <iso>] [--end <iso>] [--json]`
- `imsg watch [--chat-id <id>] [--since-rowid <id>] [--debounce <duration>] [--attachments] [--convert-attachments] [--reactions] [--participants <handles>] [--start <iso>] [--end <iso>] [--json]`
- `imsg search --query <text> [--match contains|exact] [--limit 50] [--json]`
- `imsg send (--to <handle-or-contact-name> | --chat-id <id> | --chat-identifier <id> | --chat-guid <guid>) [--text <text>] [--file <path>] [--service imessage|sms|auto] [--no-sms-fallback] [--region US] [--json]`
- `imsg react --chat-id <id> --reaction love|like|dislike|laugh|emphasis|question`
- `imsg rpc`
- `imsg completions bash|zsh|fish|llm`

Advanced IMCore (require `imsg launch` with SIP off — see
[Advanced IMCore](#advanced-imcore-features)):

- `imsg read --to <handle> [--chat-id <id>]`
- `imsg typing --to <handle> [--duration 5s] [--stop true]`
- `imsg launch [--dylib <path>] [--kill-only] [--json]`
- `imsg status [--json]`
- `imsg send-rich [--reply-to <guid>] [--file <path>]`,
  `imsg send-multipart`, `imsg send-attachment [--reply-to <guid>]`,
  `imsg tapback`
- `imsg poll send (--chat <guid> | --chat-id <id>) --question <text> [--comment <text>] --option <text> --option <text> [--reply-to <guid>]`
- `imsg poll vote (--chat <guid> | --chat-id <id>) --poll <guid> (--option-id <id> | --option-index <n> | --option <text>)`
- `imsg edit`, `imsg unsend`, `imsg delete-message`, `imsg notify-anyways`
- `imsg chat-create`, `imsg chat-name`, `imsg chat-photo`,
  `imsg chat-add-member`, `imsg chat-remove-member`, `imsg chat-leave`,
  `imsg chat-delete`, `imsg chat-mark`
- `imsg account`, `imsg whois`, `imsg nickname`

`imsg status --json` reports native bridge selector capabilities. Poll creation
requires `selectors.pollPayloadMessage`; poll voting requires
`selectors.pollVoteMessage` plus `poll.vote` in `rpc_methods`.
Messages does not render the poll payload title on the balloon, so `poll send`
also sends a best-effort plain caption message right after the poll. The
caption defaults to `--question`; use `--comment` when the visible text should
be different from the stored question.

`react` intentionally sends only the standard tapbacks Messages.app exposes
reliably through automation. Custom emoji tapbacks can be read from
history/watch output, but are sent through the bridge `tapback` command.

## JSON Output

`--json` emits one JSON object per line, so consumers can stream it directly
or collect it with `jq -s`.

Chat objects include:

- `id`, `name`, `identifier`, `guid`, `service`, `last_message_at`
- `display_name`, `contact_name`
- `is_group`, `participants`
- `account_id`, `account_login`, `last_addressed_handle`

Message objects include:

- `id`, `chat_id`, `chat_identifier`, `chat_guid`, `chat_name`
- `participants`, `is_group`
- `guid`, `reply_to_guid`, `thread_originator_guid`, `destination_caller_id`
- `reply_to_text`, `reply_to_sender` (parent body + handle for threaded
  replies and non-reaction associations, when the parent row is still in
  chat.db)
- `balloon_bundle_id`, `url_preview`
- `sender`, `sender_name`, `is_from_me`, `text`, `created_at`
- `attachments`, `reactions`
- `poll` for native Apple Messages poll creation and vote rows

When `watch --reactions --json` sees a tapback event, the message object also
includes `is_reaction`, `reaction_type`, `reaction_emoji`, `is_reaction_add`,
and `reacted_to_guid`.

Routing fields such as `destination_caller_id`, `account_id`,
`account_login`, and `last_addressed_handle` are read-only diagnostics from
Messages. AppleScript does not expose a way for `imsg send` to force a
specific outgoing Apple ID phone number or inline reply target.

## JSON-RPC

`imsg rpc` speaks JSON-RPC 2.0 over stdin/stdout, one JSON object per line.
It is intended for agents and long-running integrations that want a single
process for chats, history, send, and watch.

Read methods: `chats.list`, `messages.history`, `watch.subscribe`,
`watch.unsubscribe`, `message.send_status`. Mutating: `send`, `poll.send`.
Bridge introspection: `handles.check`. See [docs/rpc.md](docs/rpc.md) for
request and response shapes.

## Attachments

`--attachments` reports metadata only. It does not copy or upload files.

Attachment metadata includes filename, transfer name, UTI, MIME type, byte
count, sticker flag, missing flag, and resolved original path.

`--convert-attachments` exposes cached, model-compatible receive-side
variants:

- CAF audio → M4A
- GIF image → first-frame PNG

Conversion requires `ffmpeg` on `PATH`. Original Messages attachments are
left unchanged. Converted metadata is reported with `converted_path` and
`converted_mime_type`.

`send --file` sends regular files, including audio, through Messages.app.
Before handing the file to Messages, `imsg` stages it under
`~/Library/Messages/Attachments/imsg/` so Messages can read it reliably.

## Watch Behavior

`imsg watch` starts at the newest message by default and streams messages
written after it starts. Use `--since-rowid <id>` to resume from a stored
cursor.

The watcher listens for filesystem events on `chat.db`, `chat.db-wal`,
`chat.db-shm`, and the containing Messages directory, then backs that up with
a lightweight poll. The poll also refreshes the file watches, keeping streams
alive when macOS drops file events or SQLite rotates sidecar files.

If Messages writes a row before its chat metadata is joined, watch retries that
row briefly and then drops it fail-closed instead of emitting an empty
`chat_id=0` payload that could be mistaken for a direct message.

RPC watch defaults to a 500ms debounce to reduce outbound echo races. CLI
watch can be tuned with `--debounce`.

## Permissions Troubleshooting

If reads fail with `unable to open database file`, empty output, or
`authorization denied`:

1. Open System Settings → Privacy & Security → Full Disk Access.
2. Add the terminal or parent app that launches `imsg`.
3. If launched from an editor, Node process, gateway, or shell wrapper, grant
   Full Disk Access to that parent app too.
4. Also add the built-in Terminal.app at
   `/System/Applications/Utilities/Terminal.app`; macOS can still consult the
   default terminal grant.
5. Toggle stale Full Disk Access entries off and on after terminal, Homebrew,
   Node, or app updates.
6. Confirm Messages.app is signed in and `~/Library/Messages/chat.db` exists.

For sends and tapbacks, allow the terminal or parent app under Privacy &
Security → Automation → Messages.

`imsg` opens `chat.db` read-only. It does not use SQLite `immutable=1` by
default because immutable reads can miss WAL-backed Messages updates.

## Advanced IMCore Features

Default `send`, `chats`, `history`, `watch`, `search`, and read-only `rpc`
workflows do not require IMCore injection.

Advanced features such as `read`, `typing`, `launch`, bridge-backed rich
send, message mutation, and chat management are opt-in. They require SIP to
be disabled and a helper dylib to be injected into Messages.app. Homebrew
installs the helper from macOS release archives; source builds can run
`make build-dylib` first.

```bash
imsg launch
imsg status
```

Important limits:

- `imsg launch` refuses to inject when SIP is enabled.
- `imsg status` is read-only and does not auto-launch or auto-inject.
- macOS 26 / Tahoe can block injection through library validation.
- macOS 26 / Tahoe can also reject direct IMCore clients through `imagent`
  private-entitlement checks.
- These limits affect advanced IMCore features such as typing indicators,
  not normal send/history/watch usage.

To revert after testing, re-enable SIP from Recovery mode with
`csrutil enable`.

### Bridge command surface

The bridge implements a manual port of the BlueBubbles private-API surface
(inspired by their Apache-2.0 helper) into our own dylib — no third-party
binary. Most commands take a `--chat` argument that is the chat GUID
(e.g. `iMessage;-;+15551234567` for direct, `iMessage;+;chat0000` for
groups). Get a chat GUID via `imsg chats --json`.

Messaging:

```bash
# Rich send with effect + reply
imsg send-rich --chat 'iMessage;-;+15551234567' --text "boom" \
  --effect com.apple.MobileSMS.expressivesend.impact \
  --reply-to <messageGuid>

# Threaded reply with an attachment in one message
imsg send-rich --chat 'iMessage;-;+15551234567' \
  --reply-to <messageGuid> --text "here it is" --file ~/Pictures/img.jpg

# Text formatting (macOS 15+ Sequoia): bold/italic/underline/strikethrough
# applied to specific ranges of the message body.
imsg send-rich --chat ... --text 'hello world' \
  --format '[{"start":0,"length":5,"styles":["bold"]},
             {"start":6,"length":5,"styles":["italic","underline"]}]'

# Multipart send (text-only in v1; per-part textFormatting also supported)
imsg send-multipart --chat 'iMessage;+;chat0000' \
  --parts '[{"text":"hi"},
            {"text":"there","textFormatting":[{"start":0,"length":5,"styles":["bold"]}]}]'

# Attachment (file or audio)
imsg send-attachment --chat ... --file ~/Pictures/img.jpg --transport auto
imsg send-attachment --chat ... --reply-to <messageGuid> --file ~/Pictures/img.jpg
imsg send-attachment --chat ... --file ~/audio.caf --audio

# Bridge tapback (custom emoji + remove supported here, unlike `imsg react`)
imsg tapback --chat ... --message <guid> --kind love
imsg tapback --chat ... --message <guid> --kind love --remove
```

Mutate (macOS 13+ — selector availability surfaced in `imsg status`):

```bash
imsg edit --chat ... --message <guid> --new-text "actually..."
imsg unsend --chat ... --message <guid>
imsg delete-message --chat ... --message <guid>
imsg notify-anyways --chat ... --message <guid>
```

Chat management:

```bash
imsg chat-create --addresses '+15551111111,+15552222222' --name 'Crew' --text 'gm'
imsg chat-name --chat ... --name 'Renamed'
imsg chat-photo --chat ... --file ~/Downloads/g.jpg     # set
imsg chat-photo --chat ...                              # clear
imsg chat-add-member --chat ... --address +15553333333
imsg chat-remove-member --chat ... --address +15553333333
imsg chat-leave --chat ...
imsg chat-delete --chat ...
imsg chat-mark --chat ... --read     # or --unread
```

`chat-create` currently creates iMessage chats only. SMS sending remains
available through `imsg send --service sms`.

Introspection:

```bash
imsg account                                            # active iMessage account + aliases
imsg account --local                                   # accounts observed in local history
imsg whois --address +15551234567 --type phone
imsg whois --address +15551234567 --local
imsg whois --address foo@bar.com --type email
imsg nickname --address +15551234567
imsg nickname --address +15551234567 --local
```

Live events (typing indicators surfaced through the dylib):

```bash
imsg watch --bb-events                                  # merge dylib events into stdout
imsg watch --bb-events --json                           # one JSON object per event
```

### v2 IPC under the hood

The dylib v1 used a single overwriting `.imsg-command.json` polled at 100ms,
which races when multiple CLI invocations run concurrently. v2 uses a
per-request UUID-keyed queue:

```
~/Library/Containers/com.apple.MobileSMS/Data/
  .imsg-bridge-ready          PID lock — set when injection is live
  .imsg-rpc/in/<uuid>.json    requests dropped here by the CLI (atomic rename)
  .imsg-rpc/out/<uuid>.json   responses written by the dylib (atomic rename)
  .imsg-events.jsonl          inbound async events (typing, alias-removed)
```

Set `IMSG_BRIDGE_LEGACY_IPC=1` to force the legacy single-file path for
debugging (existing v1 callers and un-rebuilt dylibs continue to work
without this).

## Development

```bash
make lint
make test
make build
```

`make test` applies the repository's SQLite.swift patch before running Swift
tests.

The reusable Swift core lives in `Sources/IMsgCore`; the CLI target lives in
`Sources/imsg`; the injected helper lives in `Sources/IMsgHelper`.

## License

MIT. Not affiliated with Apple. iMessage and SMS are trademarks of their
respective owners.
