#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP_NAME="imsg"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT}/dist}"
BUILD_MODE=${BUILD_MODE:-release}
DIST_DIR="$(mktemp -d "/tmp/${APP_NAME}-linux.XXXXXX")"

cleanup() {
  rm -rf "$DIST_DIR"
}
trap cleanup EXIT

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "scripts/build-linux.sh must run on Linux." >&2
  exit 1
fi

TARGET_TRIPLE=$(swift -print-target-info | python3 -c 'import json,sys; print(json.load(sys.stdin)["target"]["triple"])')
TARGET_ARCH="${TARGET_TRIPLE%%-*}"
ARCHIVE_NAME="${APP_NAME}-linux-${TARGET_ARCH}.tar.gz"

# Swift 6.4's default Swift Build backend omits ICU libraries from static links.
# Keep the standalone archive contract on SwiftPM's native backend.
BUILD_ARGS=(--build-system native -c "$BUILD_MODE" --product "$APP_NAME" --static-swift-stdlib)
swift build "${BUILD_ARGS[@]}"
BUILD_DIR=$(swift build "${BUILD_ARGS[@]}" --show-bin-path)

cp "${BUILD_DIR}/${APP_NAME}" "${DIST_DIR}/${APP_NAME}"
for bundle in "${BUILD_DIR}"/*.bundle "${BUILD_DIR}"/*.resources; do
  if [[ -e "$bundle" ]]; then
    cp -R "$bundle" "$DIST_DIR/"
  fi
done

mkdir -p "$OUTPUT_DIR"
tar -C "$DIST_DIR" -czf "${OUTPUT_DIR}/${ARCHIVE_NAME}" .

echo "Built ${OUTPUT_DIR}/${ARCHIVE_NAME}"
