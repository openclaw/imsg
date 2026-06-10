# Changelog

## 0.11.1 - Unreleased

### Read Commands
- fix: let `chats` and `history` run without prompting for Contacts when permission is still undecided, while preserving Contacts prompts for explicit name-resolution flows (#135, thanks @cemendes).

### JSON Output
- feat: expose raw Messages `balloon_bundle_id` in message JSON/RPC payloads so consumers can recognize URL-preview rows without parsing text (#137, thanks @omarshahine).

### Advanced IMCore
- fix: defer injected bridge bootstrap until after Messages startup so macOS 26 dyld constructor ordering cannot touch ObjC/Foundation/IMCore before the process is ready (#138, thanks @omarshahine).
- fix: let bridge-backed sends and initial chat creation wait longer for slow Messages private-send completions while keeping short timeouts for probe and mutation calls (#139, thanks @omarshahine).

## 0.11.0 - 2026-05-31

### Send
- feat: add SIP-free local iMessage/SMS service detection for direct `send --service auto`, with text-only iMessage-to-SMS fallback that never overrides explicit `--service` choices (#132, thanks @ranaroussi).
- fix: keep direct `send --service auto` usable without Full Disk Access by treating local Messages history lookup as best-effort for direct recipients.

### Local Lookups
- feat: add `--local` modes for `account`, `whois`, and `nickname` so common introspection can read local history or Contacts without launching the IMCore bridge (#132, thanks @ranaroussi).

## 0.10.0 - 2026-05-28

### Watch
- fix: re-arm `watch`/RPC filesystem sources after SQLite rotates `chat.db-wal` or `chat.db-shm`, so busy iCloud-synced databases keep emitting inbound rows (#126).
- fix: retry live watch rows whose chat metadata has not resolved yet, then drop them fail-closed instead of emitting `chat_id=0` direct-message-shaped payloads (#118).

### Native Polls
- feat: add native Apple Messages poll decoding and bridge-backed `imsg poll send` / `poll.send` support, including threaded poll replies and vote readback (#125, thanks @veteranbv).

### JSON-RPC
- fix: return chat GUID, message GUID, and service identity from JSON-RPC send/create responses when observable (#119, thanks @svetly).
- feat: expose `handles.check` for bridge-backed iMessage handle availability checks (#120, thanks @svetly).
- feat: expose `message.send_status` to query outbound message delivery state by GUID (#121, thanks @svetly).

## 0.9.0 - 2026-05-16

### JSON Output
- feat: include `reply_to_text` and `reply_to_sender` on message payloads
  emitted by `history`, `search`, `watch`, and `rpc` so consumers can quote
  the parent of a threaded reply (or non-reaction association) without a
  follow-up chat.db lookup. The parent is resolved by joining
  `thread_originator_guid` or the non-reaction `associated_message_guid`
  back to the message table; absent parents leave the fields nil (#115, thanks
  @omarshahine).

### JSON-RPC
- feat: expose bridge-backed message RPC methods for rich sends, attachments, tapbacks, edits, unsends, deletes, and notify-anyways; include the CLI version in `imsg status --json` so callers can gate newer RPC action surfaces.

### Private API Bridge
- fix: support threaded attachment replies via `send-rich --file` and
  `send-attachment --reply-to`, including the macOS 26 attachment staging
  fallback (#113, #114, thanks @omarshahine).
- fix: `edit` now applies on macOS 14+ instead of silently no-opping by passing
  the backing `IMMessageItem` and attributed compatibility text to IMCore (#116,
  thanks @zshawauxlol).

### Attachments
- fix: avoid hanging attachment metadata conversion when `ffmpeg` emits enough output to fill stdout or stderr pipes.

## 0.8.2 - 2026-05-11

### JSON-RPC
- fix: keep `imsg rpc` stdout strictly JSONL when startup fails before the
  database opens; Full Disk Access failures now answer the caller's request
  with a JSON-RPC error instead of printing the human permission banner to
  stdout.

## 0.8.1 - 2026-05-09

### Release Packaging
- fix: include the IMCore bridge helper dylib in macOS release archives and
  search Homebrew install paths for brew-installed advanced features (#111,
  thanks @omarshahine).

### Messaging
- fix: route JSON-RPC `send` through the IMCore bridge when it is available,
  with automatic AppleScript fallback and an explicit `transport` override
  (#108).
- fix: resolve JSON-RPC `typing` direct recipients against existing chat GUIDs
  before synthesizing an `iMessage`/`SMS` prefix (#109).
- fix: stage bridge attachments before dylib sends and let
  `send-attachment --transport auto` fall back to AppleScript for normal files
  when the bridge is unavailable (#110, thanks @omarshahine).

## 0.8.0 - 2026-05-08

### Linux Read-Only Preview
- feat: add a Linux read-only core build with fixture-backed tests and GitHub
  CI coverage for copied Messages databases.
- build: add Linux release archive packaging for `imsg-linux-x86_64.tar.gz`.
- docs: document Linux as read-only support for existing copied Messages
  databases.

### Message Decoding
- fix: strip printable typedstream length bytes from recovered `attributedBody`
  text for 32-126 byte messages (#107, thanks @SagarSDagdu).

## 0.7.3 - 2026-05-06

### Private API Bridge
- fix: restore macOS 26 bridge sends, replies, tapbacks, typing/read RPC, and
  chat/group lifecycle RPC methods after the BlueBubbles-inspired bridge port
  regressed on Tahoe (#101, thanks @omarshahine).
- fix: stage bridge attachments with the target chat GUID and fall back to the
  modern IMDPersistence save API when the legacy persistent-path API returns
  nil (#102, #103, thanks @omarshahine).

### Security
- fix: harden bridge IPC queue directories and attachment paths against
  symlink traversal while preserving trusted macOS system aliases like `/tmp`
  (#105, thanks @omarshahine).

## 0.7.2 - 2026-05-06

### Release Packaging
- fix: publish a fresh signed and notarized macOS patch archive with matching
  Homebrew metadata.

## 0.7.1 - 2026-05-06

### Release Packaging
- fix: ship a signed and notarized macOS release archive and refresh the
  Homebrew checksum for the patch release.

## 0.7.0 - 2026-05-06

### Private API Bridge
- feat: port the BlueBubbles-inspired private-API bridge surface for rich sends,
  message mutation, chat management, account/nickname introspection, and live
  bridge events; add local DB search and v2 concurrent bridge IPC (#100, thanks
  @omarshahine).
- fix: route default bridge calls over v2 IPC when available and reject
  unsupported `chat-create --service SMS` requests instead of reporting a
  service that was not applied.
- fix: decode typedstream attributed bodies with `0x81`/`0x82` length prefixes
  so long fallback message text is preserved in history and watch output (#99,
  thanks @SagarSDagdu).

### Docs And CI
- docs: publish the per-feature docs site at `imsg.sh` and add
  syntax-highlighted code examples.
- ci: update GitHub Actions for the Node 24 runtime and quote workflow
  architecture lookup.

## 0.6.0 - 2026-05-05

### More Reliable Live Streams And History
- fix: keep `imsg watch` streams alive with a lightweight polling fallback when macOS misses filesystem events (#78).
- fix: dedupe URL preview balloon messages in `watch` without dropping similar messages from other chats or older database schemas (#64, thanks @lesaai).
- fix: decode UTF-16LE BOM attributed bodies so plain-text history output recovers messages whose `text` column is empty (#91, thanks @clawbunny).
- fix: speed up JSON history output by batching attachment and reaction metadata lookups (#81, thanks @kacy).
- fix: speed up chat listing by using `chat_message_join.message_date` when Messages provides it (#76, thanks @tmad4000).
- docs: clarify stale Full Disk Access grants, Terminal.app permissions, and watch fallback polling requirements (#28, #32, #33, #46, #83, thanks @wangran870414).

### Better Chat, Group, And Account Diagnostics
- feat: add `imsg group --chat-id <id>` to inspect a chat's identifier, GUID, service, participants, account metadata, and group/direct status (#88, thanks @mryanb).
- feat: resolve Contacts names in `chats`, `history`, `watch`, and direct sends while preserving raw handles for automation (#75, #77, thanks @regaw-leinad and @jsindy).
- feat: expose read-only account routing hints (`account_id`, `account_login`, `last_addressed_handle`) for multi-number diagnostics (#18).
- fix: include group metadata in CLI JSON history/watch output, not just RPC payloads (#57, thanks @clawbunny).

### Sending, RPC, And Automation Fixes
- fix: return best-effort sent message `id` and `guid` from RPC `send` responses when the row can be observed after Messages accepts the send (#85).
- fix: expose RPC watch debounce and default it to 500ms to reduce outbound echo races (#72, #80).
- fix: gate RPC watch reaction metadata on `include_reactions`, not `attachments` (#82).
- fix: confirm standard tapback reaction selection in Messages automation before reporting success (#53, thanks @PeterRosdahl).
- fix: reject unsupported custom emoji reaction sends instead of taking a no-op AppleScript path (#55).
- fix: detect Tahoe group-send ghost rows and fail instead of reporting false success (#90, thanks @loop).
- docs: document standard tapback sending and watch reaction events (#66, thanks @safaaleigh).

### Attachments, Completions, And Install Polish
- feat: optionally report model-compatible converted receive-side attachment files for CAF audio and GIF images (#73, thanks @mfzeidan).
- feat: add shell completions and an LLM-oriented command reference generator (`imsg completions bash|zsh|fish|llm`) (#21, thanks @bdmorin).
- fix: publish universal macOS release binaries for Homebrew installs (#68, #79).
- docs: document the Homebrew install path in the README (#61, thanks @joshuayoes).
- docs: clarify that `send --file` supports regular file and audio attachments through Messages.app (#35, thanks @rock19).
- docs: add a local release helper for dispatching Homebrew tap updates (#97, thanks @dinakars777).

### Advanced IMCore / Tahoe Notes
- feat: add advanced IMCore controls for `status`, `launch`, `read`, and typing diagnostics.
- fix: normalize IMCore typing chat lookup across `iMessage`, `SMS`, and `any` prefixes (#51, #54, #56, #58).
- fix: report macOS 26/Tahoe IMCore typing entitlement failures as advanced-feature setup errors instead of misleading chat lookup failures (#60).
- docs: document macOS 26 advanced IMCore injection, library-validation, and private-entitlement limits (#60).

### Internal Safety
- refactor: centralize Messages schema detection, row decoding, query assembly, typed row IDs, and attachment/reaction query paths behind smaller `MessageStore` extensions.
- test: expand release packaging, CLI metadata, schema-compatibility, JSON newline, stdout capture, and live-read coverage.

## 0.5.0 - 2026-02-16

- feat: add typing indicator command + RPC methods with stricter validation (#41, thanks @kohoj)
- feat: `--reactions` flag for `watch` command to include tapback events in stream (#26)
- feat: `imsg react` command to send tapback reactions via UI automation (#24)
- feat: reaction events include `is_reaction`, `reaction_type`, `reaction_emoji`, `is_reaction_add`, `reacted_to_guid` fields
- feat: add `include_reactions` toggle to `watch.subscribe` RPC and extend RPC reaction metadata fields
- feat: include `thread_originator_guid` in message output (#39, thanks @ruthmade)
- feat: expose `destination_caller_id` in message output (#29, thanks @commander-alexander)
- fix: apply history filters before limit (#20, thanks @tommybananas)
- fix: flush watch output immediately when stdout is buffered (#43, thanks @ccaum)
- fix: prefer handle sends when chat identifier is a direct handle
- fix: detect groups from `;+;` prefix in guid/identifier for RPC payloads (#42, thanks @shivshil)
- fix: harden `react` AppleScript execution and tighten group-handle detection paths
- refactor: consolidate schema detection, stdout writing, and message/RPC payload mapping paths
- test: split command test suites by domain and align group-handle expectations
- docs: update changelog entries as typing/reaction work landed
- chore: bump version marker to `0.5.0`

## 0.4.0 - 2026-01-07
- feat: surface audio message transcriptions (thanks @antons)
- fix: stage message attachments in Messages attachments directory (thanks @antons)
- fix: prefer chat GUID for `chat_id` sends to avoid 1:1 AppleScript errors (thanks @mshuffett)
- fix: detect python3 in patch-deps script (thanks @visionik)
- build: add universal binary build helper
- ci: switch to make-based lint/test/build
- docs: update build/test/release instructions
- chore: replace pnpm scripts with make targets
- refactor: split message-store query paths for clearer message retrieval internals
- test: keep attachment tests isolated from user attachment directories
- fix: address attachment upload error handling regressions
- docs: refine changelog ordering/notes for patch-deps and 0.4.0 prep
- chore: version housekeeping for the 0.3.1 -> 0.4.0 release transition

## 0.3.0 - 2026-01-03
- feat: JSON-RPC server over stdin/stdout (`imsg rpc`) with chats, history, watch, and send
- feat: group chat metadata in JSON/RPC output (participants, chat identifiers, is_group)
- feat: tapback + emoji reaction support in JSON output (#8) — thanks @tylerwince
- enhancement: custom emoji reactions and tapback removal handling
- feat: include `guid` and `reply_to_guid` metadata in JSON output
- fix: hide reaction rows from history/watch output and improve reaction matching
- fix: fill missing sender handles from `destination_caller_id` for outgoing/group messages
- fix: harden reaction detection
- docs: add RPC + group chat notes
- test: expand RPC/command coverage, add reaction fixtures, drop unused stdout helper
- test: add coverage for sender fallback
- feat: add IMCore send mode and IMCore-based reaction send path
- fix: stabilize IMCore send and sender fallback behavior
- change: remove private API send mode in favor of IMCore path
- build: add/harden notarized release script checks
- chore: update copyright year to 2026
- test: split message-store fixtures for more isolated reaction/sender coverage
- docs: maintain unreleased/release changelog staging for 0.2.2/0.3.0
- chore: release/prepare metadata updates for 0.3.0 and 0.3.1

## 0.2.1 - 2025-12-30
- fix: avoid crash parsing long attributed bodies (>256 bytes) (thanks @tommybananas)
- docs: prepare/backfill changelog notes for 0.2.1
- chore: bump release version metadata to 0.2.1

## 0.2.0 - 2025-12-28
- feat: Swift 6 rewrite with reusable IMsgCore library target
- feat: Commander-based CLI with SwiftPM build/test workflow
- feat: event-driven watch using filesystem events (no polling)
- feat: SQLite.swift + PhoneNumberKit + NSAppleScript integration
- fix: ship PhoneNumberKit resource bundle for CLI installs
- fix: patch/avoid PhoneNumberKit bundle lookup crashes across install layouts
- fix: embed Info.plist + AppleEvents entitlement for automation prompts
- fix: fall back to osascript when AppleEvents permission is missing
- fix: retry osascript on transient unknown AppleScript errors
- fix: decode length-prefixed attributed bodies for sent messages
- fix: resolve CLI version detection for symlinked/bundle installs
- chore: SwiftLint + swift-format linting
- change: JSON attachment keys now snake_case
- deprecation note: `--interval` replaced by `--debounce` (no compatibility)
- docs: add release process documentation
- ci: publish release notes from changelog and harden extraction
- chore: reset release versioning during Swift rewrite stabilization
- chore: version.env + generated version source for `--version`

## 0.1.1 - 2025-12-27
- feat: `imsg chats --json`
- fix: drop sqlite `immutable` flag so new messages/replies show up (thanks @zleman1593)
- test: add/stabilize live update regression coverage
- docs: add unreleased entry and backfill/prepare changelog history
- chore: update go dependencies

## 0.1.0 - 2025-12-20
- feat: `imsg chats` list recent conversations
- feat: `imsg history` with filters (`--participants`, `--start`, `--end`) + `--json`
- feat: `imsg watch` polling stream (`--interval`, `--since-rowid`) + filters + `--json`
- feat: `imsg send` text and/or one attachment (`--service imessage|sms|auto`, `--region`)
- feat: attachment metadata output (`--attachments`) incl. resolved path + missing flag
- fix: clearer Full Disk Access error for `~/Library/Messages/chat.db`
- fix: coerce attachment aliasing in message parsing
- build: add GoReleaser workflow and tag backfill support
- ci: harden Go/lint environment setup and align toolchain/linter installation
- docs: add repository guidelines/package docs and initial README polish
- chore: bootstrap initial project/release scaffolding and dependency baseline
