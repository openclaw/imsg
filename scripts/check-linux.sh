#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "scripts/check-linux.sh must run on a Linux host with Docker." >&2
  exit 1
fi

sudo docker run --rm -v "$ROOT:/workspace" -w /workspace swift:6.4.0-noble bash -euc '
  apt-get update
  apt-get install -y --no-install-recommends python3
  scripts/generate-version.sh
  swift package resolve
  scripts/patch-deps.sh
  swift test -j 2
  swift build -j 2 --product imsg
  .build/debug/imsg completions bash > /dev/null
  scripts/build-linux.sh
'

sudo docker run --rm -v "$ROOT/dist:/artifacts:ro" \
  -e IMSG_ARCHIVE_NAME="imsg-linux-$(uname -m).tar.gz" ubuntu:24.04 bash -euc '
  mkdir /tmp/imsg-release
  tar -xzf "/artifacts/$IMSG_ARCHIVE_NAME" -C /tmp/imsg-release
  cd /tmp/imsg-release
  ./imsg --version
  ./imsg completions bash > /dev/null
  # Linux rejects sends, but constructing the sender loads phone metadata first.
  if ./imsg send --to +16502530000 --text fixture > output.txt 2> error.txt; then
    echo "Linux send unexpectedly succeeded" >&2
    exit 1
  fi
  grep -F "only supported on macOS" error.txt
'

cd "$ROOT"
node --test scripts/build-docs-site.test.mjs
