#!/usr/bin/env bash
set -euo pipefail

SQLITE_PACKAGE=".build/checkouts/SQLite.swift/Package.swift"
PHONE_NUMBER_BUNDLE=".build/checkouts/PhoneNumberKit/Sources/PhoneNumberKit/Bundle+Resources.swift"

# Try python3, then python, then fail
if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
else
  echo "Error: Python not found. Please install Python 3."
  exit 1
fi

if [[ -f "$SQLITE_PACKAGE" ]]; then
  chmod u+w "$SQLITE_PACKAGE" || true
  $PYTHON_BIN - <<'PY'
import sys
from pathlib import Path
path = Path('.build/checkouts/SQLite.swift/Package.swift')
text = path.read_text()
if 'PrivacyInfo.xcprivacy' in text:
    raise SystemExit(0)
needle = 'exclude: [\n            "Info.plist"\n        ]'
replacement = 'exclude: [\n            "Info.plist",\n            "PrivacyInfo.xcprivacy"\n        ]'
if needle not in text:
    print(f"Error: SQLite.swift Package.swift no longer contains the expected resource exclude block: {path}", file=sys.stderr)
    raise SystemExit(1)
path.write_text(text.replace(needle, replacement))
PY
fi

if [[ ! -f "$PHONE_NUMBER_BUNDLE" ]]; then
  echo "Error: PhoneNumberKit bundle resource patch target is missing: $PHONE_NUMBER_BUNDLE" >&2
  exit 1
fi

chmod u+w "$PHONE_NUMBER_BUNDLE" || true
PHONE_NUMBER_BUNDLE="$PHONE_NUMBER_BUNDLE" $PYTHON_BIN - <<'PY'
import os
import sys
from pathlib import Path

path = Path(os.environ["PHONE_NUMBER_BUNDLE"])
text = path.read_text()

updated = False
if "#if DEBUG && SWIFT_PACKAGE" in text:
    text = text.replace("#if DEBUG && SWIFT_PACKAGE", "#if SWIFT_PACKAGE")
    updated = True
elif "#if SWIFT_PACKAGE" not in text:
    print(f"Error: PhoneNumberKit bundle guard no longer matches expected Swift package condition: {path}", file=sys.stderr)
    raise SystemExit(1)

needle = "Bundle.main.bundleURL,\n"
insert = "Bundle.main.bundleURL,\n            Bundle.main.bundleURL.resolvingSymlinksInPath(),\n"
if "resolvingSymlinksInPath()" not in text and needle in text:
    text = text.replace(needle, insert)
    updated = True
elif "resolvingSymlinksInPath()" not in text:
    print(f"Error: PhoneNumberKit bundle URL list no longer contains the expected insertion point: {path}", file=sys.stderr)
    raise SystemExit(1)

if updated:
    path.write_text(text)
PY
