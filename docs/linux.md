---
title: Linux Read-Only Preview
description: "Use imsg on Linux to inspect an existing Messages database copied from macOS."
---

Linux support is a read-only preview. It is for inspecting an existing
`chat.db` copied from macOS; it is not a Linux Messages client.

`imsg` opens the database in SQLite read-only mode. It does not write to the
copied database, and it cannot send or mutate messages on Linux.

## What Works

Use Linux for offline inspection and automation:

```bash
imsg chats --db ./chat.db --limit 20 --json | jq -s
imsg group --db ./chat.db --chat-id 42 --json
imsg history --db ./chat.db --chat-id 42 --limit 50 --json | jq -s
imsg search --db ./chat.db --query "invoice" --limit 20 --json | jq -s
```

The JSON shape matches macOS for these read paths, including chat identifiers,
participants, message GUIDs, timestamps, text, reactions, and attachment
metadata when the copied database contains it.

## What Does Not Work

These features require macOS frameworks, Messages.app, or AppleScript
automation and are not supported on Linux:

- `send`
- `react`
- `read`
- `typing`
- `launch`
- IMCore bridge features
- Contacts name resolution
- live access to iMessage or SMS accounts

Attachment paths inside `chat.db` usually point to macOS locations under the
original user's home directory. Linux can report that metadata, but files only
exist if you copy the attachment tree too.

## Copy A Database From macOS

Do not copy a live SQLite database with plain `cp`. Use SQLite's backup command
so the snapshot is consistent:

```bash
mkdir -p /tmp/imsg-linux
sqlite3 "$HOME/Library/Messages/chat.db" \
  ".backup '/tmp/imsg-linux/chat.db'"
sqlite3 /tmp/imsg-linux/chat.db 'pragma quick_check;'
```

Then transfer `/tmp/imsg-linux/chat.db` to the Linux machine and point `imsg`
at it:

```bash
imsg chats --db ./chat.db --limit 5 --json | jq -s
```

For repeatable tests, keep copied databases in a private, ignored directory and
avoid printing raw message output in CI logs.

## Build From Source On Linux

The Linux build requires Swift 6.2 or newer:

```bash
git clone https://github.com/openclaw/imsg.git
cd imsg
scripts/generate-version.sh
swift package resolve
scripts/patch-deps.sh
swift build -c release --product imsg
.build/release/imsg chats --db ./chat.db --limit 5
```

Release builds for 0.8.0 and newer publish `imsg-linux-x86_64.tar.gz` from the
GitHub release workflow.

Once a release is tagged, install the archive like this:

```bash
curl -LO https://github.com/openclaw/imsg/releases/latest/download/imsg-linux-x86_64.tar.gz
tar -xzf imsg-linux-x86_64.tar.gz
./imsg chats --db ./chat.db --limit 5
```
