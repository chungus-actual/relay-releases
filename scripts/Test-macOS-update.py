"""Exercise signed archive installation and relaunch with an isolated Sparkle app."""
import argparse
import functools
import http.server
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOOLS = ROOT / 'macos/.build/dependencies/sparkle-bin'
FRAMEWORK = ROOT / 'macos/.build/dependencies/Sparkle.xcframework/macos-arm64_x86_64'
ACCOUNT = 'com.chungus-actual.relay.updates'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--tamper', action='store_true', help='Verify a modified archive is rejected')
args = parser.parse_args()


def run(*args):
    subprocess.run(list(map(str, args)), check=True)


identity = re.search(r'([A-F0-9]{40}) "Relay Local Development"', subprocess.check_output(
    ['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)).group(1)
key = subprocess.check_output([str(TOOLS / 'generate_keys'), '--account', ACCOUNT, '-p'], text=True).strip()
with tempfile.TemporaryDirectory(dir=ROOT / 'macos/.build', prefix='sparkle-install-check-') as directory:
    base = pathlib.Path(directory)
    served = base / 'served'
    served.mkdir()
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(served))
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f'http://127.0.0.1:{server.server_port}/'
    app = base / 'installed/RelayUpdateCheck.app'
    (app / 'Contents/MacOS').mkdir(parents=True)
    marker = base / 'relaunched.txt'
    bundle_id = 'com.chungus-actual.relay.updatecheck.' + uuid.uuid4().hex
    info = dict(CFBundleIdentifier=bundle_id, CFBundleName='RelayUpdateCheck',
                CFBundleExecutable='Check', CFBundlePackageType='APPL', CFBundleVersion='1',
                CFBundleShortVersionString='0.1.0', LSMinimumSystemVersion='14.0',
                SUFeedURL=url + 'appcast.xml', SUPublicEDKey=key,
                SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
                SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False,
                RelayTestMarker=str(marker), NSAppTransportSecurity={'NSAllowsLocalNetworking': True})
    plist = app / 'Contents/Info.plist'
    plist.write_bytes(plistlib.dumps(info))
    run('clang', '-fobjc-arc', '-framework', 'Cocoa', '-F', FRAMEWORK,
        '-framework', 'Sparkle', '-Wl,-rpath,@executable_path/../Frameworks',
        ROOT / 'macos/Tests/UpdateCheck.m', '-o', app / 'Contents/MacOS/Check')
    run('python3', ROOT / 'scripts/Bundle-macOS-Sparkle.py', app, identity)
    run('codesign', '--force', '--sign', identity, app)
    newer = base / 'new/RelayUpdateCheck.app'
    newer.parent.mkdir()
    run('ditto', app, newer)
    info.update(CFBundleVersion='2', CFBundleShortVersionString='0.1.1')
    (newer / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    run('codesign', '--force', '--sign', identity, newer)
    run('ditto', '-c', '-k', '--keepParent', newer, served / 'Check-2.zip')
    run(TOOLS / 'generate_appcast', '--account', ACCOUNT, '--maximum-deltas', '0',
        '--download-url-prefix', url, served)
    if args.tamper:
        archive = served / 'Check-2.zip'
        data = bytearray(archive.read_bytes())
        data[len(data) // 2] ^= 1
        archive.write_bytes(data)
    log_path = ROOT / 'macos/.build/update-install-check.log'
    with log_path.open('w') as log:
        process = subprocess.Popen([str(app / 'Contents/MacOS/Check')], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 120
            while not marker.exists() and time.monotonic() < deadline:
                if args.tamper and process.poll() == 3:
                    break
                if process.poll() not in (None, 0):
                    raise RuntimeError(log_path.read_text())
                time.sleep(0.25)
            if args.tamper:
                assert process.poll() == 3 and not marker.exists(), log_path.read_text()
                assert 'signature' in log_path.read_text().lower(), log_path.read_text()
                assert plistlib.loads(plist.read_bytes())['CFBundleVersion'] == '1'
                print('PASS: tampered archive rejected; original version preserved')
            elif not marker.exists():
                raise RuntimeError('Install/relaunch timed out: ' + log_path.read_text())
            else:
                assert plistlib.loads(plist.read_bytes())['CFBundleVersion'] == '2'
                print('PASS: signed feed, archive download, replacement, and version-2 relaunch')
            run('codesign', '--verify', '--deep', '--strict', app)
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=10)
            server.shutdown()
