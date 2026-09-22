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
'

cd "$ROOT"
node --test scripts/build-docs-site.test.mjs
