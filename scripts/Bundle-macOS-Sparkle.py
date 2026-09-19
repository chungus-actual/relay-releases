import os, pathlib, subprocess, sys
root = pathlib.Path(__file__).resolve().parent.parent
app = pathlib.Path(sys.argv[1]); identity = sys.argv[2]
source = root / 'macos/.build/dependencies/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
target = app / 'Contents/Frameworks/Sparkle.framework'
subprocess.run(['ditto', str(source), str(target)], check=True)
version = target / 'Versions/B'
flags = ['--options', 'runtime', '--timestamp'] if os.environ.get('RELAY_DISTRIBUTION') == '1' else []
for relative in ['Autoupdate', 'Updater.app', 'XPCServices/Installer.xpc', 'XPCServices/Downloader.xpc']:
    subprocess.run(['codesign', '--force', '--sign', identity, *flags, str(version / relative)], check=True)
subprocess.run(['codesign', '--force', '--sign', identity, *flags, str(target)], check=True)
