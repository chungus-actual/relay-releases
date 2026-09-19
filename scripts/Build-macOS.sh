#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Validate the development-only engine opt-in before signing/building anything.
case "${RELAY_EXPERIMENTAL_CHROMIUM:-0}" in
    0|1) ;;
    *) echo "RELAY_EXPERIMENTAL_CHROMIUM must be 0 or 1" >&2; exit 1 ;;
esac
if [[ "${RELAY_CHROMIUM:-0}" != 0 ]]; then
    echo 'RELAY_CHROMIUM is retired. Use RELAY_EXPERIMENTAL_CHROMIUM=1 for development only.' >&2; exit 1
fi
if [[ "${RELAY_EXPERIMENTAL_CHROMIUM:-0}" == 1 && "${RELAY_DISTRIBUTION:-0}" == 1 ]]; then
    echo 'Experimental Chromium cannot be included in distribution builds.' >&2; exit 1
fi
# Prefer Developer ID for distribution; preserve local signing for development.
# Prefer an explicitly selected identity; never silently fall back if it fails.
SIGNING_IDENTITY="${RELAY_CODESIGN_IDENTITY:-}"
SIGNING_FLAGS=(--force)
case "${RELAY_DISTRIBUTION:-0}" in
    0) ;;
    1)
        if [[ -z "$SIGNING_IDENTITY" ]]; then
            SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk '/"Developer ID Application:/ { print $2; exit }')"
        fi
        python3 - "$SIGNING_IDENTITY" <<'PY'
import re, subprocess, sys
identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
valid = re.findall(r'([A-F0-9]{40}) "(Developer ID Application:[^\"]+)"', identities)
if not any(sys.argv[1] in pair for pair in valid):
    raise SystemExit('Distribution requires a valid Developer ID Application identity')
PY
        SIGNING_FLAGS+=(--options runtime --timestamp)
        ;;
    *) echo "RELAY_DISTRIBUTION must be 0 or 1" >&2; exit 1 ;;
esac
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk '/"Relay Local Development"/ { print $2; exit }')"
fi
if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ]]; then
    SIGNING_IDENTITY="-"
    echo "Warning: ad-hoc signing changes Relay's Keychain identity when its executable changes." >&2
    echo "WebCrypto may ask again after rebuilds. See docs/macos.md for stable local signing." >&2
fi
export CLANG_MODULE_CACHE_PATH="$ROOT/macos/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/macos/.build/module-cache"
python3 "$ROOT/scripts/Fetch-macOS-dependencies.py"
# Validate update configuration before replacing the testing bundle.
CONFIGURED_PLIST="$ROOT/macos/.build/Relay-Info.plist"
cp "$ROOT/macos/Info.plist" "$CONFIGURED_PLIST"
python3 "$ROOT/scripts/Configure-macOS-updates.py" "$CONFIGURED_PLIST"
BUILD_ARGS=(--package-path "$ROOT/macos" --configuration release)
case "${RELAY_UNIVERSAL:-0}" in
    0) ;;
    1) BUILD_ARGS+=(--arch arm64 --arch x86_64) ;;
    *) echo "RELAY_UNIVERSAL must be 0 or 1" >&2; exit 1 ;;
esac
swift build "${BUILD_ARGS[@]}"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
APP="$ROOT/dist/macos/Relay.app"
# Recreate the bundle so switching engine build options cannot retain old frameworks.
python3 - "$APP" <<'PY'
import pathlib, shutil, sys
app = pathlib.Path(sys.argv[1])
if app.exists():
    shutil.rmtree(app)
PY
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Relay" "$APP/Contents/MacOS/Relay"
cp "$ROOT/services.json" "$APP/Contents/Resources/services.json"
swift -module-cache-path "$ROOT/macos/.build/module-cache" "$ROOT/scripts/Export-macOS-icons.swift" \
    "$ROOT/Assets/ServiceIcons.xaml" "$APP/Contents/Resources/ServiceIcons"
cp "$ROOT/Assets/Services/LICENSE.txt" "$APP/Contents/Resources/ServiceIcons/"
cp "$ROOT/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Licenses"
cp -f "$ROOT/macos/Licenses/Sparkle.txt" "$APP/Contents/Resources/Licenses/"
bash "$ROOT/scripts/Export-macOS-app-icon.sh" "$APP/Contents/Resources/Relay.icns"
cp "$CONFIGURED_PLIST" "$APP/Contents/Info.plist"
python3 "$ROOT/scripts/Bundle-macOS-Sparkle.py" "$APP" "$SIGNING_IDENTITY"
if [[ "${RELAY_EXPERIMENTAL_CHROMIUM:-0}" == 1 ]]; then
    python3 "$ROOT/scripts/Bundle-macOS-Chromium.py" "$APP" "$SIGNING_IDENTITY"
fi
if [[ "${RELAY_DISTRIBUTION:-0}" == 1 ]]; then
    SIGNING_FLAGS+=(--entitlements "$ROOT/macos/Relay.entitlements")
fi
codesign --sign "$SIGNING_IDENTITY" "${SIGNING_FLAGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
