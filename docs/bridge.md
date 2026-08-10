---
title: Bridge command reference
description: "CLI commands and IPC details for imsg's optional injected IMCore bridge."
---

This page is the command reference for `imsg` features that run through the injected IMCore bridge. Read [Advanced IMCore](advanced-imcore.md) first for the SIP, library-validation, entitlement, and privacy boundaries.

Most commands take `--chat <guid>`, where a direct chat looks like `iMessage;-;+15551234567` and a group looks like `iMessage;+;chat0000`. Get the exact GUID from `imsg chats --json`, and run `imsg status --json` to inspect the selectors and RPC methods available on the current macOS version.

## Messaging

Send an Apple URL preview. URL mode cannot be combined with text, effects, replies, or files.

```bash
imsg send-rich --chat 'iMessage;-;+15551234567' --url https://imsg.sh
```

Send rich text, a reply, or an attachment:

```bash
imsg send-rich --chat 'iMessage;-;+15551234567' --text "boom" \
  --effect com.apple.MobileSMS.expressivesend.impact \
  --reply-to <message-guid>

imsg send-rich --chat 'iMessage;-;+15551234567' \
  --reply-to <message-guid> --text "here it is" --file ~/Pictures/image.jpg

imsg send-rich --chat 'iMessage;-;+15551234567' --text 'hello world' \
  --format '[{"start":0,"length":5,"styles":["bold"]}]'
```

Formatting requires macOS 15 or newer. Multipart messages accept a JSON array of text parts:

```bash
imsg send-multipart --chat 'iMessage;+;chat0000' \
  --parts '[{"text":"hi"},{"text":"there"}]'
```

Send regular or audio attachments:

```bash
imsg send-attachment --chat 'iMessage;-;+15551234567' \
  --file ~/Pictures/image.jpg --transport auto
imsg send-attachment --chat 'iMessage;-;+15551234567' \
  --reply-to <message-guid> --file ~/Pictures/image.jpg
imsg send-attachment --chat 'iMessage;-;+15551234567' \
  --file ~/Desktop/audio.caf --audio
```

With `--transport auto`, a normal file can fall back to AppleScript only when
the bridge is unavailable or proves the request was `not_started`. It never
falls back after publication has an uncertain outcome, including timeout,
cancellation, a vanished or claimed request, or a malformed response.
`--audio` and `--reply-to` remain bridge-only.

Send a validated sticker on its own or attach it to an existing bubble part:

```bash
imsg send-sticker --chat 'iMessage;-;+15551234567' \
  --file ~/Pictures/sticker.png
imsg send-sticker --chat 'iMessage;-;+15551234567' \
  --file ~/Pictures/sticker.png --attach-to <message-guid> --target-part 0
```

Stickers are iMessage-only. They accept PNG/APNG, GIF, or JPEG images up to 500 KiB, 618×618 pixels, 100 frames, and 25 million decoded pixels. Standalone sends require `selectors.stickerSend`; attached stickers also require `selectors.stickerAttach`.

Bridge tapbacks support removal and custom emoji in addition to the standard reactions exposed by `imsg react`:

```bash
imsg tapback --chat 'iMessage;-;+15551234567' \
  --message <message-guid> --kind love
imsg tapback --chat 'iMessage;-;+15551234567' \
  --message <message-guid> --kind love --remove
```

## Native polls

Create a poll with a visible caption:

```bash
imsg poll send --chat 'iMessage;-;+15551234567' \
  --question 'Dinner?' --option 'Pizza' --option 'Sushi'
```

Messages does not render the payload title on the poll balloon, so `poll send` follows it with a best-effort caption. Use `--comment` to choose different visible text or `--no-comment` when the caller already sent the context.

Vote or remove a vote with one option selector:

```bash
imsg poll vote --chat-id 42 --poll <poll-guid> --option-index 2
imsg poll unvote --chat-id 42 --poll <poll-guid> --option-index 2
```

Poll creation requires `selectors.pollPayloadMessage`. Voting requires `selectors.pollVoteMessage` and the matching RPC capability reported by `imsg status --json`.

## Message and chat mutation

Mutate an existing message:

```bash
imsg edit --chat 'iMessage;-;+15551234567' \
  --message <message-guid> --new-text "actually..."
imsg unsend --chat 'iMessage;-;+15551234567' --message <message-guid>
imsg delete-message --chat 'iMessage;-;+15551234567' --message <message-guid>
imsg notify-anyways --chat 'iMessage;-;+15551234567' --message <message-guid>
```

Manage chats and participants:

```bash
imsg chat-create --addresses '+15551111111,+15552222222' --name 'Crew' --text 'gm'
imsg chat-name --chat 'iMessage;+;chat0000' --name 'Renamed'
imsg chat-photo --chat 'iMessage;+;chat0000' --file ~/Pictures/group.jpg
imsg chat-add-member --chat 'iMessage;+;chat0000' --address +15553333333
imsg chat-remove-member --chat 'iMessage;+;chat0000' --address +15553333333
imsg chat-leave --chat 'iMessage;+;chat0000'
imsg chat-delete --chat 'iMessage;+;chat0000'
imsg chat-mark --chat 'iMessage;+;chat0000' --read
```

`chat-photo` clears the photo when `--file` is omitted. `chat-mark` also accepts `--unread`. `chat-create` creates iMessage chats; SMS sending remains available through the standard `imsg send --service sms` path.

## Account and identity

Inspect the active account, local history, and address capabilities:

```bash
imsg account
imsg account --local
imsg whois --address +15551234567 --type phone
imsg whois --address +15551234567 --local
imsg nickname --address +15551234567
imsg nickname --address +15551234567 --local
```

Inspect or explicitly share the local Messages Name & Photo:

```bash
imsg name-photo status --chat 'iMessage;-;+15551234567'
imsg name-photo share --chat 'iMessage;-;+15551234567'
```

`status` reports whether Messages would offer its native sharing action; it is not a durable record of prior sharing. `share` discloses the local profile to every chat participant and reports a request, not a delivery receipt. Call it only after explicit user confirmation of the destination.

## Live bridge events

Merge bridge-pushed typing and alias events into the normal watch stream:

```bash
imsg watch --bb-events --json
```

This combines two independently ordered best-effort sources on serialized
stdout. Bridge events begin at the current event-log EOF and are non-resumable;
there is no ordering guarantee relative to database messages. RPC clients can
subscribe separately with `bridge.events.subscribe` and cancel its shared
subscription ID with `watch.unsubscribe`.

## IPC layout

The bridge uses a UUID-keyed request queue so concurrent CLI invocations cannot overwrite one another:

```text
~/Library/Containers/com.apple.MobileSMS/Data/
  .imsg-bridge-ready          PID lock set while injection is live
  .imsg-rpc/in/<uuid>.json    atomically published requests
  .imsg-rpc/out/<uuid>.json   per-request responses
  .imsg-events.jsonl          inbound asynchronous events
```

Set `IMSG_BRIDGE_LEGACY_IPC=1` only when debugging against an older, unrebuilt helper that still uses the single-file IPC path.

## Delivery outcomes and retry safety

The v2 client classifies failed mutations from queue ownership, using monotonic
deadlines:

- An unpublished request, or an unclaimed request that the client atomically
  owns and removes before a final empty response check, is `not_started` and
  retry-safe.
- A `.processing.<pid>` claim or an unreadable inbox is `still_in_flight`.
  Files are preserved.
- A published request that vanished without a response is
  `may_have_completed`.

Malformed or unreadable responses after publication are also uncertain. The
legacy single-file command timeout is always `still_in_flight` because it has
no per-request claim proof. Never automatically retry a bridge mutation unless
the typed disposition is `not_started`; human-readable error wording is not a
retry contract.
