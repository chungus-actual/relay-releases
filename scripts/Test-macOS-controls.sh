#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/macos/.build/checks"
swiftc -parse-as-library -module-cache-path "$ROOT/macos/.build/module-cache" \
    "$ROOT/macos/Sources/RelayMac/Models.swift" \
    "$ROOT/macos/Sources/RelayMac/ShellTheme.swift" \
    "$ROOT/macos/Sources/RelayMac/AddAccountButton.swift" \
    "$ROOT/macos/Tests/ControlChecks/ControlChecks.swift" \
    -o "$ROOT/macos/.build/checks/ControlChecks"
"$ROOT/macos/.build/checks/ControlChecks"
