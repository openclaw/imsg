#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/version.env"

APP_NAME="imsg"
HELPER_NAME="imsg-bridge-helper.dylib"
CODESIGN_IDENTITY=${CODESIGN_IDENTITY:-"Developer ID Application: Peter Steinberger (Y5PE65HELJ)"}
ENTITLEMENTS="${ROOT}/Resources/imsg.entitlements"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp}"
ZIP_PATH="${OUTPUT_DIR}/imsg-macos.zip"
ARCHES_VALUE=${ARCHES:-"arm64 x86_64"}
ARCH_LIST=( ${ARCHES_VALUE} )
# arm64e is mandatory for the helper: macOS 26 Messages will not load an
# arm64-only dylib. The HELPER_ARCH_LIST validation below fails the notarize run
# if any slice (incl. arm64e) is missing.
HELPER_ARCHES_VALUE=${HELPER_ARCHES:-"arm64e arm64 x86_64"}
HELPER_ARCH_LIST=( ${HELPER_ARCHES_VALUE} )
SWIFT_SCRATCH_ROOT=${SWIFT_SCRATCH_ROOT:-"${ROOT}/.build/universal"}
DIST_DIR="$(mktemp -d "/tmp/${APP_NAME}-dist.XXXXXX")"
API_KEY_FILE="$(mktemp "/tmp/${APP_NAME}-notary.XXXXXX.p8")"

cleanup() {
  rm -f "$API_KEY_FILE"
  rm -rf "$DIST_DIR"
}
trap cleanup EXIT

if [[ -z "${APP_STORE_CONNECT_API_KEY_P8:-}" || -z "${APP_STORE_CONNECT_KEY_ID:-}" || -z "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
  echo "Missing APP_STORE_CONNECT_* env vars (API key, key id, issuer id)." >&2
  exit 1
fi

echo "$APP_STORE_CONNECT_API_KEY_P8" | sed 's/\\n/\n/g' > "$API_KEY_FILE"

BINARIES=()
PRODUCT_DIRS=()
for ARCH in "${ARCH_LIST[@]}"; do
  SCRATCH_PATH="${SWIFT_SCRATCH_ROOT}/${ARCH}"
  swift build -c release --product "$APP_NAME" --arch "$ARCH" \
    --scratch-path "$SCRATCH_PATH"
  PRODUCT_DIR=$(swift build -c release --arch "$ARCH" \
    --scratch-path "$SCRATCH_PATH" --show-bin-path)
  BINARIES+=("${PRODUCT_DIR}/${APP_NAME}")
  PRODUCT_DIRS+=("$PRODUCT_DIR")
done

lipo -create "${BINARIES[@]}" -output "$DIST_DIR/imsg"
HELPER_CLANG_ARCH_ARGS=()
for ARCH in "${HELPER_ARCH_LIST[@]}"; do
  HELPER_CLANG_ARCH_ARGS+=("-arch" "$ARCH")
done
clang -dynamiclib "${HELPER_CLANG_ARCH_ARGS[@]}" -fobjc-arc \
  -Wno-arc-performSelector-leaks \
  -install_name "@rpath/${HELPER_NAME}" \
  -framework Foundation \
  -framework AppKit \
  -o "$DIST_DIR/$HELPER_NAME" \
  "$ROOT/Sources/IMsgHelper/IMsgInjected.m"

# Validate the HELPER slices, not the CLI ARCH_LIST — the helper defaults to a
# superset (arm64e) that the CLI list does not contain, so ARCH_LIST here would
# silently skip the arm64e check macOS 26 Messages depends on.
for ARCH in "${HELPER_ARCH_LIST[@]}"; do
  if ! lipo -archs "$DIST_DIR/$HELPER_NAME" | tr ' ' '\n' | grep -Fxq "$ARCH"; then
    echo "Helper missing required architecture slice: $ARCH" >&2
    exit 1
  fi
done

codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  "$DIST_DIR/imsg"
codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" \
  --identifier com.steipete.imsg.bridge-helper \
  "$DIST_DIR/$HELPER_NAME"

for bundle in "${PRODUCT_DIRS[0]}"/*.bundle; do
  if [[ -e "$bundle" ]]; then
    cp -R "$bundle" "$DIST_DIR/"
  fi
done

chmod -R u+rw "$DIST_DIR"
xattr -cr "$DIST_DIR"
find "$DIST_DIR" -name '._*' -delete

DITTO_BIN=${DITTO_BIN:-/usr/bin/ditto}
rm -f "$ZIP_PATH"
(
  cd "$DIST_DIR"
  "$DITTO_BIN" --norsrc -c -k . "$ZIP_PATH"
)

xcrun notarytool submit "$ZIP_PATH" \
  --key "$API_KEY_FILE" \
  --key-id "$APP_STORE_CONNECT_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
  --wait

codesign --verify --strict --verbose=4 "$DIST_DIR/imsg"
codesign --verify --strict --verbose=4 "$DIST_DIR/$HELPER_NAME"
if ! spctl -a -t exec -vv "$DIST_DIR/imsg"; then
  echo "spctl check failed (CLI binaries often report 'not an app')." >&2
fi

echo "Done: $ZIP_PATH"
