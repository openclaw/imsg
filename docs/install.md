---
title: Install
description: "Install imsg with Homebrew, build it from source, or pin a specific release."
---

`imsg` ships as a signed, notarized universal macOS binary. It runs on macOS 14 (Sonoma) and newer, including macOS 26 (Tahoe).

0.8.0 and newer releases also publish Linux builds as a read-only preview for
existing Messages databases copied from macOS. See [Linux read-only preview](linux.md).

## Homebrew

```bash
brew install steipete/tap/imsg
```

This is the recommended path. Homebrew downloads the universal binary for your architecture, installs it onto your `PATH`, and tracks updates with `brew upgrade`.

To uninstall:

```bash
brew uninstall imsg
brew untap steipete/tap   # optional
```

## Build from source

```bash
git clone https://github.com/openclaw/imsg.git
cd imsg
make build
./bin/imsg --help
```

`make build` runs the universal release build through Swift Package Manager and applies the required SQLite.swift and PhoneNumberKit resource patches. The binary lands at `bin/imsg`.

Each architecture's dependency checkout is patched before compilation. Keep the generated resource bundles beside the executable when installing it elsewhere; invoking that executable through a symlink is supported. The CLI and helper both target macOS 14 or newer.

For day-to-day development:

```bash
make imsg ARGS="chats --limit 5"
```

This is a clean debug rebuild that runs the resulting binary with the supplied arguments.

## Linux read-only preview

Linux support is for reading an existing `chat.db` copied from macOS. It opens
the database read-only and supports inspection commands such as `chats`,
`group`, `history`, and `search`.

It does not send messages, react, mark chats read, show typing, launch
Messages.app, use Contacts, or access iMessage/SMS accounts on Linux. Those
features depend on macOS frameworks or Messages.app automation.

For setup and copy-safe database commands, see [Linux read-only preview](linux.md).

## Verify the install

```bash
imsg --version
imsg chats --limit 3
```

If `chats` returns `unable to open database file` or `authorization denied`, jump to [Permissions](permissions.md). The CLI is installed correctly; macOS just hasn't granted it Full Disk Access yet.

## Optional dependencies

- **`ffmpeg`** on your `PATH`. Required only for `--convert-attachments`; see [Attachments](attachments.md).
- **`jq`**. Not required, but every example here uses it to pretty-print JSON streams.

## What you don't need

- No Node, Python, or Ruby runtime.
- No background daemon, launch agent, or login item.
- No private API patches. Default reads use a read-only handle on `chat.db`; sends use Messages' published AppleScript surface. Only the [advanced IMCore features](advanced-imcore.md) need a helper dylib, and even those are off by default.
