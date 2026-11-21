<!--
Write for someone who uses imsg but has not read the code. The title and opening
problem statement should make sense without the diff or linked issue.

Use the repository's short, lowercase title prefixes (for example, fix:, feat:,
ci:, or chore:) and an imperative summary. Name the affected task and the symptom
or outcome, not just a function or file.

Illustrative title examples, not reports of existing bugs:
Good: docs: explain how to read message history on Linux
Bad: docs: update SQLite platform notes
Good: ci: check that release archives run without Swift installed
Bad: ci: add archive smoke-test invocation

For internal-only work, name the actual developer or operator workflow affected.
Add a visible Closes #<issue-number> or Related: #<issue-number> below when useful.
-->

## What Problem This Solves

<!--
Describe the concrete user, product, or operational problem.
In 1–3 plain sentences, say who is affected, what happens today, and why it
matters to them. For a bug, name the trigger if known. For a feature or internal
work, describe the need in the actual workflow without inventing harm.
Could a reader understand the problem without knowing your proposed fix?

Good: "Background checks can use up a new user's model allowance before they've
asked the assistant to monitor anything."
Bad: "Turn off periodic checks on fresh installs."
-->

## User Impact

<!--
Lead with the concrete outcome for users, operators, or developers in plain
language, usually one sentence. For internal-only changes, say there is no
user-visible change; do not invent a benefit. Keep important risks, breaking
changes, and required user actions visible here.
-->

## Why This Change Was Made

<!--
Briefly explain how the change addresses the problem without repeating the
impact. Keep the body short. Leave file lists, internal acronyms, and root-cause
walkthroughs in the diff or optional <details>; include technical detail only
when it explains behavior or a material tradeoff. Do not hide risks or required
actions in <details>.
-->

## Evidence

<!--
Start with the behavior checked and the result in plain language, then give
reproduction or verification steps. Do not make readers decode command lists
to learn what was verified. Keep meaningful gaps and unrun checks visible.

Following AGENTS.md, include the outputs of make lint and make test. For CLI
changes, include sample commands and before/after snippets. Put exact commands
and long output in links or optional <details>, after the useful result summary.

Document any manual permission or setup steps reviewers need. Local Messages
database reads need Full Disk Access; sending needs Automation permission for
Messages.app, and SMS needs relay configured in macOS/iOS. Prefer deterministic
fixtures over the live Messages database, and redact private message content
and recipient details from evidence.
-->
