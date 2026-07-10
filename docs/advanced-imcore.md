---
title: Advanced IMCore features
description: "Read receipts, typing indicators, IMCore status, and Messages launch control — opt-in, SIP-disabled, and increasingly limited on macOS 26."
---

Most `imsg` workflows — `chats`, `history`, `watch`, `send`, `react` — are explicitly designed to *not* require any private framework or process injection. They go through Messages.app's published surfaces (SQLite, AppleScript, file events) and need only the documented permissions covered in [Permissions](permissions.md).

The features documented here are the exception. They drive Messages.app from the inside via a helper dylib injected into the Messages process, and they trigger several macOS protections you have to disable to use them.

You almost certainly do not need any of this for normal use.

## What's in scope

- `imsg read --to <handle> [--chat-id <id>]` — mark a chat as read.
- `imsg typing --to <handle> [--duration 5s] [--stop true]` — show or stop the typing indicator.
- `imsg launch [--dylib <path>] [--kill-only]` — launch Messages.app with the helper dylib injected.
- `imsg status` — read-only IMCore bridge status.
- `imsg send-rich --chat <guid> --reply-to <message-guid> --file <path>` —
  sends a threaded reply with an attachment through the bridge.
- `imsg send-attachment --chat <guid> --file <path> [--reply-to <message-guid>]` —
  prefers the bridge for private attachment sends, with AppleScript fallback
  for normal files when no reply target is requested.

## Why they're separate

These features depend on private IMCore APIs that aren't reachable from outside the Messages process. To touch them, `imsg` injects a small helper dylib into Messages.app via `DYLD_INSERT_LIBRARIES`. Homebrew installs that helper when the release archive includes it; source builds can create it with `make build-dylib`.

That injection requires three things to be true on the target machine:

1. **SIP disabled.** System Integrity Protection blocks `DYLD_INSERT_LIBRARIES` into protected system apps. Without disabling SIP, the launch step refuses to proceed.
2. **Library validation off.** macOS 26 (Tahoe) tightened library validation; even with SIP off, a dylib that isn't signed against Messages' team identifier can be rejected.
3. **No private-entitlement gate.** macOS 26 also added `imagent` entitlement checks that can refuse direct IMCore clients regardless of injection success.

You should expect at least one of these gates to be active on a current macOS install. The features are documented because they remain useful for research, testing, and CI — not because they're stable user-facing functionality.

## Building and launching

```bash
imsg launch        # launches Messages.app with the dylib injected
imsg status        # confirms the bridge is up
```

Source installs need one extra step first:

```bash
make build-dylib   # produces .build/release/imsg-bridge-helper.dylib (arm64e)
```

`imsg launch` refuses to inject when SIP is enabled. There's no override.

`imsg status` is read-only. It does not auto-launch or auto-inject. Run `imsg launch` first.

To revert: re-enable SIP from Recovery mode (`csrutil enable`), then reboot.

## Read receipts

```bash
imsg read --to "+14155551212"
imsg read --to "+14155551212" --chat-id 42
imsg read --to "+14155551212" --chat-identifier "iMessage;+;chat..."
imsg read --to "+14155551212" --chat-guid "iMessage;+;chat..."
```

Marks the chat for that handle as read. Useful when you want a programmatic agent to clear the unread counter in Messages without spawning a UI action.

## Typing indicators

```bash
imsg typing --to "+14155551212" --duration 5s
imsg typing --to "+14155551212" --duration 30s --service imessage
imsg typing --to "+14155551212" --stop true
```

Displays or hides the "typing" bubble on the recipient's device.

`--service` accepts `imessage`, `sms`, or `auto`. The IMCore typing chat lookup normalizes across `iMessage`, `SMS`, and `any` prefixes so the same handle works on either service.

On macOS 26, typing indicators frequently fail with an entitlement error. `imsg` reports this as an advanced-feature setup error rather than a misleading "chat not found" — see `CHANGELOG.md` 0.6.0 for the issue history.

## Status

```bash
imsg status
imsg status --json
```

Reports whether Messages is running, whether the helper dylib is loaded, and whether the IMCore bridge is responding. Read-only; safe to run on any machine.

When the bridge isn't loaded, `status` prints the reason rather than attempting to fix it. Use `imsg launch` if you want to bring it up.

## Launching Messages with a custom dylib

```bash
imsg launch --dylib /path/to/custom.dylib
imsg launch --kill-only           # quit Messages without launching
imsg launch --json                # machine-readable launch result
```

`--kill-only` is the inverse: it tears Messages down (to drop a stale injection) without relaunching.

## When to use any of this

The honest answer for most readers: **don't**. The macOS 26 limits make these features unstable in production. They're useful when:

- You're doing macOS / Messages.app research.
- You're running CI inside a controlled VM with SIP disabled by configuration.
- You need a typing-indicator demo on a single hand-tuned machine.

For agent integrations, prefer the standard CLI surfaces (`send`, `react`, `watch`). They cover the realistic interaction surface without touching SIP.

`send-attachment --transport auto` is the one bridge command that can still
complete without a running bridge for normal file attachments: it stages the
file under Messages' attachments directory, tries the dylib path first, then
falls back to AppleScript. `--audio` remains bridge-only because AppleScript
cannot preserve the private audio-message flag.
