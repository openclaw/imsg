# Repository Guidelines

## Project Structure & Module Organization
- `Sources/imsg` holds the CLI entrypoint and command wiring.
- `Sources/IMsgCore` contains SQLite access, watchers, AppleScript send logic, and helpers.
- `bin/` is created by `make build` for local artifacts.

## Build, Test, and Development Commands
- `make imsg` — clean rebuild + run debug CLI (use `ARGS=...`).
- `make build` — universal release build into `bin/`.
- `make lint` — run `swift format` lint + `swiftlint`.
- `make test` — run `swift test` after syncing version + patching deps.
- `scripts/check-linux.sh` — Linux tests/builds in the pinned Swift container, standalone archive smoke tests in Ubuntu without Swift, and docs tests with Node; requires Docker, Node 26, and passwordless sudo on the Linux host. Crabbox hydration prepares both toolchains. Use `crabbox run --id <id> --timing-json --shell -- 'scripts/check-linux.sh'` after warmup. macOS-only tests still run in macOS CI.

## Coding Style & Naming Conventions
- Swift 6 module; prefer concrete types, early returns, and minimal globals.
- Formatting is enforced by `swift format` and `swiftlint`.
- CLI flags use long-form, kebab-case (`--chat-id`, `--attachments`).

## Testing Guidelines
- Unit tests live in `Tests/` as `*Tests.swift`.
- Prefer deterministic fixtures over touching the live Messages DB.
- Add regression tests for fixes touching parsing, filtering, or attachment metadata.

## Commit & Pull Request Guidelines
- Follow the existing short, lowercase prefixes seen in history (`ci:`, `chore:`, `fix:`, `feat:`) with an imperative summary (e.g., `fix: handle missing attachments`).
- PRs should include: brief description, steps to repro/verify, and outputs of `make lint` and `make test`. For CLI changes, include sample commands and before/after snippets.
- Keep changeset focused; avoid drive-by refactors unless they reduce risk or remove duplication in touched areas.

## Security & macOS Permissions
- The tool needs read-only access to `~/Library/Messages/chat.db`; ensure the terminal has Full Disk Access before running tests that touch the DB.
- Sending requires Automation permission for Messages.app and SMS relay configured in macOS/iOS; document any manual steps needed for reviewers.
