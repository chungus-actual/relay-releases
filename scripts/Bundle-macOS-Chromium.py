"""Bundle the optional Chromium backend into a locally signed Relay preview."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
app = Path(sys.argv[1]).resolve()
identity = sys.argv[2]
sdk = Path(os.environ.get('RELAY_QT_SDK', root / 'macos/.build/qt-sdk/6.11.2/macos'))
cmake = Path(os.environ.get('RELAY_CMAKE', root / 'macos/.build/cef-tools/cmake/data/bin/cmake'))
ninja = Path(os.environ.get('RELAY_NINJA', root / 'macos/.build/cef-tools/bin/ninja'))
for tool in [sdk / 'bin/macdeployqt', cmake, ninja]:
    if not tool.is_file():
        raise SystemExit('Install the Chromium SDK/tools described in docs/chromium-macos.md.')
build = root / 'macos/.build/chromium-bridge'
subprocess.run([str(cmake), '-S', str(root / 'macos/ChromiumBridge'), '-B', str(build), '-G', 'Ninja',
                f'-DCMAKE_PREFIX_PATH={sdk}', f'-DCMAKE_MAKE_PROGRAM={ninja}',
                '-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64', '-DCMAKE_BUILD_TYPE=Release'], check=True)
subprocess.run([str(cmake), '--build', str(build), '-j4'], check=True)
frameworks = app / 'Contents/Frameworks'
frameworks.mkdir(parents=True, exist_ok=True)
bridge = frameworks / 'libRelayChromium.dylib'
shutil.copy2(build / bridge.name, bridge)
result = subprocess.run([str(sdk / 'bin/macdeployqt'), str(app), f'-executable={bridge}',
                         f'-libpath={sdk / "lib"}', '-always-overwrite', '-no-codesign', '-verbose=1'],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
print(result.stdout, end='')
if result.returncode or 'ERROR:' in result.stdout:
    raise SystemExit('Qt deployment failed.')
# Sign nested components before their containing frameworks and the outer app.
# Sparkle already has its own explicit signing step; leave its nested signatures alone.
components = []
for directory in [frameworks, app / 'Contents/PlugIns']:
    for path in directory.rglob('*'):
        if path.is_symlink() or 'Sparkle.framework' in path.parts:
            continue
        if path.suffix in {'.framework', '.app', '.xpc', '.dylib'}:
            components.append(path)
for path in sorted(components, key=lambda p: len(p.parts), reverse=True):
    command = ['codesign', '--force', '--sign', identity]
    if os.environ.get('RELAY_DISTRIBUTION') == '1':
        command += ['--options', 'runtime', '--timestamp']
    if path.name == 'QtWebEngineProcess.app':
        entitlements = path / 'Contents/Resources/QtWebEngineProcess.entitlements'
        if not entitlements.is_file():
            raise SystemExit('Qt helper entitlements are missing.')
        command += ['--entitlements', str(entitlements)]
    subprocess.run(command + [str(path)], check=True)
