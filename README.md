# imsg 💬 — Messages, piped.

[![CI](https://img.shields.io/github/actions/workflow/status/openclaw/imsg/ci.yml?branch=main&style=flat-square&label=ci)](https://github.com/openclaw/imsg/actions/workflows/ci.yml)
[![GitHub release](https://img.shields.io/github/v/release/openclaw/imsg?style=flat-square)](https://github.com/openclaw/imsg/releases/latest)
[![macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey?style=flat-square)](docs/install.md)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)](https://www.swift.org)
[![License](https://img.shields.io/github/license/openclaw/imsg?style=flat-square)](LICENSE)
[![Homebrew](https://img.shields.io/badge/Homebrew-steipete%2Ftap-FBB040?style=flat-square&logo=homebrew&logoColor=black)](https://github.com/steipete/homebrew-tap)
[![Docs](https://img.shields.io/badge/docs-imsg.sh-4B5563?style=flat-square)](https://imsg.sh)

![imsg banner](docs/assets/readme-banner.jpg)

`imsg` is a Swift CLI for reading, watching, and sending iMessage and SMS from macOS. It reads the local Messages database, sends through Messages.app automation, and exposes NDJSON and JSON-RPC for scripts and agents.

```bash
imsg chats --limit 10 --json | jq -s
imsg history --chat-id 42 --limit 20 --attachments --json | jq -s
imsg watch --chat-id 42 --reactions --json
imsg send --to "+14155551212" --text "on my way"
```

That's the whole pitch: read directly, stream updates, and ask Messages.app to send.

## Install

Homebrew is the smallest path on macOS:

```bash
brew install steipete/tap/imsg
imsg --version
```

`imsg` requires macOS 14 or newer. Signed macOS builds and Linux x86_64 read-only builds are also available from [GitHub Releases](https://github.com/openclaw/imsg/releases/latest). Linux reads a `chat.db` copied from macOS; it does not connect to iMessage or send messages. See the [Linux guide](docs/linux.md).

## Quick start

Grant your terminal **Full Disk Access** in **System Settings → Privacy & Security**, then reopen it. `imsg` needs that permission to read `~/Library/Messages/chat.db`.

```bash
# Find a chat and note its id.
imsg chats --limit 3

# Read its ten most recent messages.
imsg history --chat-id 42 --limit 10
```

Use an id from the first command in place of `42`. The [five-minute quickstart](docs/quickstart.md) continues with live watching and sending.

## Core workflows

| Goal | Start here |
| --- | --- |
| List chats and inspect their identifiers | [Chats](docs/chats.md) and [groups](docs/groups.md) |
| Read or search local history | [History](docs/history.md) |
| Stream new messages and tapbacks | [Watch](docs/watch.md) |
| Send text, files, and standard tapbacks | [Send](docs/send.md) and [attachments](docs/attachments.md) |
| Count messages and media | [Statistics](docs/stats.md) |
| Consume stable NDJSON or a long-running stdio API | [JSON schema](docs/json.md) and [JSON-RPC](docs/rpc.md) |
| Generate shell completions or model-ready CLI help | [Completions](docs/completions.md) |

Read commands open the database in SQLite read-only mode. `watch` follows database and WAL filesystem events, with a polling fallback when macOS drops an event or rotates a sidecar file.

## Permissions

Full Disk Access is required for local database reads. Sending and standard tapbacks also require **Automation → Messages**; Contacts access is optional and only adds resolved names. The [permissions guide](docs/permissions.md) covers parent-process grants and stale TCC entries, while [troubleshooting](docs/troubleshooting.md) maps common failures to their likely gate.

SSH sessions can also resolve contact names through the Mac’s read-only AddressBook database when the SSH service has Full Disk Access and Contacts.framework is unavailable. See [Contacts over SSH](docs/permissions.md#contacts-over-ssh).

For SMS, enable Text Message Forwarding on the paired iPhone. `imsg send` uses Messages.app's AppleScript surface and cannot force a particular outgoing number when several numbers share one Apple ID.

## JSON and automation

`--json` emits one JSON object per line. Human progress and warnings stay on stderr, so stdout remains safe to stream. Pipe finite commands through `jq -s` when you want one array.

```bash
imsg chats --json | jq -s
imsg rpc
imsg completions llm
```

The [JSON schema](docs/json.md) documents chats, messages, attachments, reactions, polls, scheduled messages, and statistics. The [JSON-RPC reference](docs/rpc.md) covers the long-running stdio transport used by agents and gateways.

## Advanced IMCore

Normal `chats`, `history`, `watch`, `send`, `react`, and read-only RPC workflows do not use private frameworks or process injection.

Read receipts, typing indicators, rich sends, message mutation, stickers, polls, and chat management use an injected helper inside Messages.app. They require SIP to be disabled and may be blocked by library validation or private-entitlement checks on current macOS releases. Start with [Advanced IMCore](docs/advanced-imcore.md), then use the [bridge command reference](docs/bridge.md) for the full CLI surface and IPC layout.

[`imsg chat-create`](docs/chats.md#create-an-imessage-chat) accepts phone numbers and email addresses you have never contacted. It creates missing handles through the active iMessage account and checks every recipient with IDS before creating the chat. You do not need to type recipients into Messages first.

## Documentation

The complete guide lives at **[imsg.sh](https://imsg.sh)**. Useful entry points include [install](docs/install.md), [permissions](docs/permissions.md), [history](docs/history.md), [watch](docs/watch.md), [send](docs/send.md), [attachments](docs/attachments.md), [Linux](docs/linux.md), and [troubleshooting](docs/troubleshooting.md).

## Development

```bash
make lint
make test
make build
```

`IMsgCore` contains the reusable Swift core, `imsg` contains the CLI, and `IMsgHelper` contains the optional injected helper. The package uses Swift 6 and targets macOS 14 or newer.

## License

MIT. See [LICENSE](LICENSE). Not affiliated with Apple; iMessage and SMS are trademarks of their respective owners.
