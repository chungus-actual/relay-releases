#!/bin/bash
# Notarize and staple before generating the immutable Sparkle update archive.
set -euo pipefail
case "${1:-}" in
    ""|--submit-only) ;;
    *) echo "Usage: $0 [--submit-only]" >&2; exit 1 ;;
esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/macos/Relay.app"
PROFILE="${RELAY_NOTARY_PROFILE:-relay-notary}"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
WORK="$ROOT/macos/.build/notary-$BUILD"
mkdir -p "$WORK"
codesign --verify --deep --strict "$APP"
DETAILS="$(codesign -dv --verbose=4 "$APP" 2>&1)"
[[ "$DETAILS" == *"Authority=Developer ID Application:"* && "$DETAILS" == *"(runtime)"* && "$DETAILS" == *"Timestamp="* ]] || {
    echo 'Build with RELAY_DISTRIBUTION=1 before notarizing.' >&2; exit 1;
}
ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/Relay.zip"
xcrun notarytool submit "$WORK/Relay.zip" --keychain-profile "$PROFILE" --output-format json > "$WORK/submission.json"
ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$WORK/submission.json")"
echo "Notarization submission: $ID"
# Staple the submitted bytes even if the local testing bundle changes while Apple scans.
mkdir -p "$WORK/stapled"
ditto -x -k "$WORK/Relay.zip" "$WORK/stapled"
SUBMITTED_APP="$WORK/stapled/Relay.app"
if [[ "${1:-}" == --submit-only ]]; then
    echo "Submitted snapshot ready: $SUBMITTED_APP"
    exit 0
fi
xcrun notarytool wait "$ID" --keychain-profile "$PROFILE" --output-format json > "$WORK/result.json"
xcrun notarytool log "$ID" --keychain-profile "$PROFILE" "$WORK/log.json"
python3 - "$WORK/result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization failed; inspect result.json and log.json')
PY
xcrun stapler staple "$SUBMITTED_APP"
xcrun stapler validate "$SUBMITTED_APP"
codesign --verify --deep --strict "$SUBMITTED_APP"
spctl --assess --type execute --verbose=2 "$SUBMITTED_APP"
SUBMITTED_HASH="$(codesign -d --verbose=4 "$SUBMITTED_APP" 2>&1 | sed -n 's/^CDHash=//p')"
CURRENT_HASH="$(codesign -d --verbose=4 "$APP" 2>&1 | sed -n 's/^CDHash=//p')"
if [[ -n "$SUBMITTED_HASH" && "$SUBMITTED_HASH" == "$CURRENT_HASH" ]]; then
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
fi
echo "Notarization accepted; stapled build: $SUBMITTED_APP"
