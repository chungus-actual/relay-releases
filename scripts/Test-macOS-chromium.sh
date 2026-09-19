#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${RELAY_QT_SDK:-$ROOT/macos/.build/qt-sdk/6.11.2/macos}"
CMAKE="${RELAY_CMAKE:-$ROOT/macos/.build/cef-tools/cmake/data/bin/cmake}"
NINJA="${RELAY_NINJA:-$ROOT/macos/.build/cef-tools/bin/ninja}"
[[ -x "$SDK/bin/macdeployqt" && -x "$CMAKE" && -x "$NINJA" ]] || { echo 'Install the investigation SDK/tools; see docs/chromium-macos.md.' >&2; exit 1; }
"$CMAKE" -S "$ROOT/macos/ChromiumBridge" -B "$ROOT/macos/.build/chromium-bridge" -G Ninja \
    "-DCMAKE_PREFIX_PATH=$SDK" "-DCMAKE_MAKE_PROGRAM=$NINJA" '-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64' -DCMAKE_BUILD_TYPE=Release
"$CMAKE" --build "$ROOT/macos/.build/chromium-bridge" -j4
APP="$ROOT/macos/.build/chromium-check/RelayChromiumCheck.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$ROOT/macos/.build/chromium-bridge/libRelayChromium.dylib" "$APP/Contents/Frameworks/"
swiftc -parse-as-library -module-cache-path "$ROOT/macos/.build/module-cache" \
    "$ROOT/macos/Sources/RelayMac/Models.swift" "$ROOT/macos/Sources/RelayMac/MediaBridge.swift" \
    "$ROOT/macos/Sources/RelayMac/BrowserRules.swift" "$ROOT/macos/Sources/RelayMac/MessengerChrome.swift" \
    "$ROOT/macos/Sources/RelayMac/BrowserDeck.swift" "$ROOT/macos/Sources/RelayMac/BrowserSession.swift" "$ROOT/macos/Sources/RelayMac/PageControls.swift" \
    "$ROOT/macos/Sources/RelayMac/Downloads.swift" "$ROOT/macos/Sources/RelayMac/DownloadDestination.swift" \
    "$ROOT/macos/Sources/RelayMac/UnreadModels.swift" "$ROOT/macos/Sources/RelayMac/MessengerUnread.swift" \
    "$ROOT/macos/Sources/RelayMac/ChromiumSession.swift" "$ROOT/macos/Tests/ChromiumChecks/ChromiumChecks.swift" \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o "$APP/Contents/MacOS/RelayChromiumCheck"
python3 - "$APP" <<'PY'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1]) / 'Contents/Info.plist'
path.write_bytes(plistlib.dumps(dict(RelayExperimentalChromium=True, CFBundleExecutable='RelayChromiumCheck', CFBundleIdentifier='com.chungus-actual.relay.chromium-check', CFBundleName='RelayChromiumCheck', CFBundlePackageType='APPL', LSMinimumSystemVersion='14.0', NSHighResolutionCapable=True)))
PY
"$SDK/bin/macdeployqt" "$APP" "-executable=$APP/Contents/Frameworks/libRelayChromium.dylib" "-libpath=$SDK/lib" -always-overwrite -no-codesign -verbose=1
# Ad-hoc signing is confined to this disposable fixture app.
codesign --force --deep --sign - "$APP"
python3 "$ROOT/macos/Tests/ChromiumChecks/run.py" "$APP/Contents/MacOS/RelayChromiumCheck" 2>&1 | tee "$ROOT/macos/.build/chromium-check/output.txt"
