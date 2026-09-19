#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${RELAY_TEST_APP:-$ROOT/dist/macos/Relay.app}"
python3 - "$APP/Contents/MacOS/Relay" "$@" <<'PY'
import os, subprocess, sys
environment = os.environ.copy()
if '--chromium' in sys.argv[2:]:
    environment['QTWEBENGINE_CHROMIUM_FLAGS'] = '--disable-background-networking --disable-component-update --password-store=basic --use-mock-keychain'
process = subprocess.Popen([sys.argv[1], '--shell-check', *sys.argv[2:]], env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
try:
    output, _ = process.communicate(timeout=25)
except subprocess.TimeoutExpired:
    process.kill()
    output, _ = process.communicate()
    print(output[-7000:])
    raise SystemExit('FAIL: live shell navigation timed out')
print(output[-7000:])
if process.returncode or 'PASS: live service/Settings transitions' not in output:
    raise SystemExit('FAIL: live shell navigation did not complete')
PY
