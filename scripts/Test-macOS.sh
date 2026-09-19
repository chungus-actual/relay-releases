#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/macos/.build/checks"
# Foundation-only checks also work without full Xcode/XCTest.
swiftc -module-cache-path "$ROOT/macos/.build/module-cache" \
    "$ROOT/macos/Sources/RelayMac/BrowserRules.swift" \
    "$ROOT/macos/Sources/RelayMac/Models.swift" \
    "$ROOT/macos/Sources/RelayMac/MediaBridge.swift" \
    "$ROOT/macos/Sources/RelayMac/UnreadModels.swift" \
    "$ROOT/macos/Sources/RelayMac/MessengerChrome.swift" \
    "$ROOT/macos/Sources/RelayMac/MessengerUnread.swift" \
    "$ROOT/macos/Sources/RelayMac/DownloadDestination.swift" \
    "$ROOT/macos/Tests/RelayMacTests/RelayMacTests.swift" \
    -o "$ROOT/macos/.build/checks/RelayChecks"
"$ROOT/macos/.build/checks/RelayChecks"

python3 "$ROOT/scripts/Test-platform-parity.py"
python3 "$ROOT/scripts/Test-macOS-build-config.py"
