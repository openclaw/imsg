# Releasing imsg

imsg pins the fleet-standard Swift CLI workflow to the immutable commit for `openclaw/release-workflows` release `v1.11.8`; advancing the moving `v1` tag does not change imsg's caller. The repository caller supplies imsg's stable artifact, signing-identifier, and Homebrew contracts; the shared workflow owns the protected-source freeze, annotated release tag, builds, signing and notarization, independent verification, exact publication, Homebrew handoff, and closeout.

## Prerequisites

The repository must contain these Actions secrets:

- `MACOS_SIGNING_P12`
- `MACOS_SIGNING_P12_PASSWORD`
- `ASC_KEY_ID`
- `ASC_ISSUER_ID`
- `ASC_PRIVATE_KEY_P8`
- `HOMEBREW_TAP_TOKEN`

The first five are required before the workflow can create a release tag. The preflight intentionally fails before mutating release state when any are unavailable.

## Release contract

- `version.env`, generated `Sources/imsg/Version.swift`, and the requested version must agree.
- `CHANGELOG.md` must contain exactly one dated level-two section for the requested version.
- `scripts/build-universal.sh` must emit the universal `imsg` CLI, `imsg-bridge-helper.dylib` with `arm64e`, `arm64`, and `x86_64` slices, and at least one Swift resource bundle.
- `scripts/build-linux.sh` must emit `imsg-linux-x86_64.tar.gz` with the static Swift runtime.
- The Darwin payload retains `com.steipete.imsg` and `com.steipete.imsg.bridge-helper` under Peter Steinberger's Developer ID identity.
- `scripts/check-macos-minimum.sh` checks `LC_BUILD_VERSION` for every CLI and helper slice during the macOS build and rejects any minimum newer than macOS 14.0.
- Both macOS architecture verifier jobs on `xcode-27` must accept the checksum inventory, signatures, architecture slices, resource bundles, notarization, version output (Intel under Rosetta), and Linux executable format before publication.
- The Homebrew formula in `steipete/homebrew-tap` must resolve to the exact verified `imsg-macos.zip` URL and SHA-256.

## Dispatch and verification

Dispatch only after the release-preparation PR is merged and current `main` CI is green. Run from the repository root so the requested version comes from the canonical source:

If GitHub does not create a push CI run for the merge commit, dispatch the same CI workflow manually, then verify that its head SHA matches current `main` and both macOS and Linux jobs pass. The release preflight accepts this independent `workflow_dispatch` evidence for the frozen commit:

```bash
gh workflow run ci.yml --repo openclaw/imsg --ref main
```

Once that exact commit is green, run the release preflight. Dry runs are the default and never create tags or publish. They validate the requested version against the frozen checkout, check the required signing credentials, read notarization history, build the universal macOS payload with a deployment-target check for every slice, and test the standalone Linux archive. The pinned shared workflow also signs, notarizes, and independently verifies both architectures without publishing:

```bash
gh workflow run release.yml --repo openclaw/imsg --ref main -f "version=$(cut -d= -f2 version.env)" -f dry_run=true
```

Require that exact run to succeed. Create, verify, and push an SSH-signed annotated version tag for that exact commit using the approved release signing key. The shared workflow reuses the immutable annotated tag and checks its target. Then dispatch publication from the same unchanged `main` commit:

```bash
gh workflow run release.yml --repo openclaw/imsg --ref main -f "version=$(cut -d= -f2 version.env)" -f dry_run=false
```

Watch the exact run. After success, verify that the public release is non-draft and non-prerelease, the annotated tag peels to the frozen main commit, all six control/platform assets are present, `SHA256SUMS` validates them, the Homebrew workflow succeeded, and the formula hash matches the published macOS ZIP.

Retries reuse the immutable annotated version tag and frozen commit. Never move or replace a consumer release tag to recover a failed run.
