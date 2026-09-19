#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/macos/.build/checks"
swiftc -parse-as-library -module-cache-path "$ROOT/macos/.build/module-cache" \
    "$ROOT/macos/Sources/RelayMac/ChromiumSession.swift" \
    "$ROOT/macos/Sources/RelayMac/BrowserRules.swift" \
    "$ROOT/macos/Sources/RelayMac/Models.swift" \
    "$ROOT/macos/Sources/RelayMac/MediaBridge.swift" \
    "$ROOT/macos/Sources/RelayMac/ProfileStorage.swift" \
    "$ROOT/macos/Sources/RelayMac/MediaCenter.swift" \
    "$ROOT/macos/Sources/RelayMac/AccountDragSource.swift" \
    "$ROOT/macos/Sources/RelayMac/UnreadModels.swift" \
    "$ROOT/macos/Sources/RelayMac/UnreadCenter.swift" \
    "$ROOT/macos/Sources/RelayMac/MessengerChrome.swift" \
    "$ROOT/macos/Sources/RelayMac/MessengerUnread.swift" \
    "$ROOT/macos/Sources/RelayMac/DownloadDestination.swift" \
    "$ROOT/macos/Sources/RelayMac/Downloads.swift" \
    "$ROOT/macos/Sources/RelayMac/PageControls.swift" \
    "$ROOT/macos/Sources/RelayMac/BrowserDeck.swift" \
    "$ROOT/macos/Sources/RelayMac/BrowserSession.swift" \
    "$ROOT/macos/Tests/BrowserChecks/BrowserChecks.swift" \
    "$ROOT/macos/Tests/BrowserChecks/FileDropChecks.swift" \
    -o "$ROOT/macos/.build/checks/BrowserChecks"
"$ROOT/macos/.build/checks/BrowserChecks" "$@"
