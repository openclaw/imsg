#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP_NAME="imsg"
HELPER_NAME="imsg-bridge-helper.dylib"
ENTITLEMENTS="${ROOT}/Resources/imsg.entitlements"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT}/bin}"
ARCHES_VALUE=${ARCHES:-"arm64 x86_64"}
ARCH_LIST=( ${ARCHES_VALUE} )
# The injected helper must include arm64e: macOS 26 Messages refuses to load an
# arm64-only dylib, which silently kills the bridge. Keep this ahead of the CLI
# arches so a release never ships an arm64-only helper.
HELPER_ARCHES_VALUE=${HELPER_ARCHES:-"arm64e arm64 x86_64"}
HELPER_ARCH_LIST=( ${HELPER_ARCHES_VALUE} )
BUILD_MODE=${BUILD_MODE:-release}
CODESIGN_IDENTITY=${CODESIGN_IDENTITY:-"-"}
SWIFT_SCRATCH_ROOT=${SWIFT_SCRATCH_ROOT:-"${ROOT}/.build/universal"}

BINARIES=()
PRODUCT_DIRS=()
for ARCH in "${ARCH_LIST[@]}"; do
  SCRATCH_PATH="${SWIFT_SCRATCH_ROOT}/${ARCH}"
  swift build -c "$BUILD_MODE" --product "$APP_NAME" --arch "$ARCH" \
    --scratch-path "$SCRATCH_PATH"
  PRODUCT_DIR=$(swift build -c "$BUILD_MODE" --arch "$ARCH" \
    --scratch-path "$SCRATCH_PATH" --show-bin-path)
  BINARIES+=("${PRODUCT_DIR}/${APP_NAME}")
  PRODUCT_DIRS+=("$PRODUCT_DIR")
done

DIST_DIR="$(mktemp -d "/tmp/${APP_NAME}-universal.XXXXXX")"
trap 'rm -rf "$DIST_DIR"' EXIT

lipo -create "${BINARIES[@]}" -output "${DIST_DIR}/${APP_NAME}"
HELPER_CLANG_ARCH_ARGS=()
for ARCH in "${HELPER_ARCH_LIST[@]}"; do
  HELPER_CLANG_ARCH_ARGS+=("-arch" "$ARCH")
done
clang -dynamiclib "${HELPER_CLANG_ARCH_ARGS[@]}" -fobjc-arc \
  -Wno-arc-performSelector-leaks \
  -install_name "@rpath/${HELPER_NAME}" \
  -framework Foundation \
  -framework AppKit \
  -framework ImageIO \
  -framework LinkPresentation \
  -o "${DIST_DIR}/${HELPER_NAME}" \
  "${ROOT}/Sources/IMsgHelper/IMsgInjected.m"

# This is the shipping path (release.yml runs only this script), so fail the
# build if any required helper slice is missing — a dropped arm64e slice
# silently kills the bridge on macOS 26 Messages.
for ARCH in "${HELPER_ARCH_LIST[@]}"; do
  if ! lipo -archs "${DIST_DIR}/${HELPER_NAME}" | tr ' ' '\n' | grep -Fxq "$ARCH"; then
    echo "Helper missing required architecture slice: $ARCH" >&2
    exit 1
  fi
done

if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - \
    --entitlements "$ENTITLEMENTS" \
    --identifier com.steipete.imsg \
    "${DIST_DIR}/${APP_NAME}"
  codesign --force --sign - \
    --identifier com.steipete.imsg.bridge-helper \
    "${DIST_DIR}/${HELPER_NAME}"
else
  codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --identifier com.steipete.imsg \
    "${DIST_DIR}/${APP_NAME}"
  codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" \
    --identifier com.steipete.imsg.bridge-helper \
    "${DIST_DIR}/${HELPER_NAME}"
fi

for bundle in "${PRODUCT_DIRS[0]}"/*.bundle; do
  if [[ -e "$bundle" ]]; then
    cp -R "$bundle" "$DIST_DIR/"
  fi
done

mkdir -p "$OUTPUT_DIR"
for existing in "$OUTPUT_DIR/$APP_NAME" "$OUTPUT_DIR/$HELPER_NAME" "$OUTPUT_DIR"/*.bundle; do
  [[ -e "$existing" ]] || continue
  if command -v trash >/dev/null 2>&1; then
    trash "$existing"
  else
    rm -rf -- "$existing"
  fi
done

cp "${DIST_DIR}/${APP_NAME}" "$OUTPUT_DIR/$APP_NAME"
cp "${DIST_DIR}/${HELPER_NAME}" "$OUTPUT_DIR/$HELPER_NAME"
for bundle in "${DIST_DIR}"/*.bundle; do
  if [[ -e "$bundle" ]]; then
    cp -R "$bundle" "$OUTPUT_DIR/"
  fi
done

echo "Built ${OUTPUT_DIR}/${APP_NAME} (${ARCHES_VALUE})"
echo "Built ${OUTPUT_DIR}/${HELPER_NAME} (${HELPER_ARCHES_VALUE})"
