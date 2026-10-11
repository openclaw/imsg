#!/usr/bin/env bash
set -euo pipefail

# Keep every shipping slice compatible with the documented macOS 14 minimum.
[[ "$#" -gt 0 ]] || { echo "Usage: $0 <Mach-O file>..." >&2; exit 2; }
for binary in "$@"; do
  arches=$(lipo -archs "$binary")
  [[ -n "$arches" ]] || { echo "No architecture slices: $binary" >&2; exit 1; }
  for arch in $arches; do
    load_commands=$(otool -arch "$arch" -l "$binary")
    printf '%s\n' "$load_commands" | grep -A3 'cmd LC_BUILD_VERSION'
    minos=$(printf '%s\n' "$load_commands" | awk '
      $1 == "cmd" { build_version = ($2 == "LC_BUILD_VERSION") }
      build_version && $1 == "minos" { print $2 }
    ')
    if ! awk -v version="$minos" 'BEGIN {
      if (version !~ /^[0-9]+\.[0-9]+(\.[0-9]+)?$/) exit 1
      split(version, parts, ".")
      exit !(parts[1] < 14 || (parts[1] == 14 && parts[2] == 0 && parts[3] + 0 == 0))
    }'; then
      echo "Unsupported macOS minimum for $binary ($arch): $minos; expected <= 14.0" >&2
      exit 1
    fi
    echo "Verified macOS minimum: $binary ($arch) $minos <= 14.0"
  done
done
