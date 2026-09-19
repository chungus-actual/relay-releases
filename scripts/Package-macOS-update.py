"""Stage a signed update for the canonical Relay.app. Does not upload anything."""
import argparse
import importlib.util
import pathlib
import plistlib
import re
import subprocess
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('config', ROOT / 'scripts/Configure-macOS-updates.py')
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--download-url-prefix', help='Override the default relay-releases asset location')
    parser.add_argument('--app', type=pathlib.Path, default=ROOT / 'dist/macos/Relay.app',
                        help='App to package; use the submitted snapshot when notarization outlives a local rebuild')
    args = parser.parse_args()
    app = args.app.resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('RelayExperimentalChromium') or (app / 'Contents/Frameworks/libRelayChromium.dylib').exists():
        raise ValueError('Experimental Chromium builds cannot be packaged as tester updates')
    config.https_url(info.get('SUFeedURL', ''))
    if not info.get('SURequireSignedFeed') or not info.get('SUVerifyUpdateBeforeExtraction'):
        raise ValueError('Rebuild with signed update configuration first')
    if info.get('SUPublicEDKey') != config.public_key():
        raise ValueError('The app public key does not match the Relay signing key')
    build = info['CFBundleVersion']
    if not re.fullmatch(r'[1-9][0-9]*', build):
        raise ValueError('Update build number must be a positive integer')
    version = info['CFBundleShortVersionString']
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('Invalid release version')
    tag = 'v' + version
    prefix = config.https_url(args.download_url_prefix or
        'https://github.com/' + config.HOSTING['repository'] + '/releases/download/' + tag + '/')
    if not prefix.endswith('/') or urllib.parse.urlsplit(prefix).query:
        parser.error('Download prefix must end in / and have no query string')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    signature = subprocess.run(['codesign', '-dv', str(app)], capture_output=True, text=True, check=True)
    if 'Signature=adhoc' in signature.stderr:
        raise ValueError('Use the stable Relay certificate for update builds')
    if 'Authority=Developer ID Application:' in signature.stderr:
        # Stapling changes the bundle, so do it before creating/signing the archive.
        subprocess.run(['xcrun', 'stapler', 'validate', str(app)], check=True)
        subprocess.run(['spctl', '--assess', '--type', 'execute', str(app)], check=True)
    output = ROOT / 'dist/macos/updates'
    output.mkdir(parents=True, exist_ok=True)
    feed = output / 'appcast.xml'
    namespace = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
    prior_urls = {}
    if feed.exists():
        for item in ET.parse(feed).findall('./channel/item'):
            enclosure = item.find('enclosure')
            if enclosure is not None:
                prior_urls[item.findtext(namespace + 'version')] = enclosure.get('url')
        versions = [int(node.text) for node in ET.parse(feed).iter(
            '{http://www.andymatuschak.org/xml-namespaces/sparkle}version') if node.text and node.text.isdigit()]
        if versions and int(build) <= max(versions):
            raise ValueError('Increment RELAY_BUILD_NUMBER for each update')
    archive = output / ('Relay-' + build + '.zip')
    if archive.exists():
        raise ValueError('This update archive already exists; do not overwrite a release')
    with tempfile.TemporaryDirectory(dir=output) as directory:
        staged = pathlib.Path(directory) / archive.name
        subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(staged)], check=True)
        staged.rename(archive)
    subprocess.run([
        str(ROOT / 'macos/.build/dependencies/sparkle-bin/generate_appcast'),
        '--account', config.ACCOUNT, '--download-url-prefix', prefix,
        '--maximum-deltas', '0', '--maximum-versions', '0',
        '-o', str(feed), str(output)], check=True)
    # generate_appcast may rebase historical archives onto the new release tag.
    # Keep each published archive at its original immutable GitHub URL.
    tree = ET.parse(feed)
    restored = False
    for item in tree.findall('./channel/item'):
        prior = prior_urls.get(item.findtext(namespace + 'version'))
        enclosure = item.find('enclosure')
        if prior and enclosure is not None and enclosure.get('url') != prior:
            enclosure.set('url', prior)
            restored = True
    if restored:
        ET.register_namespace('sparkle', namespace[1:-1])
        tree.write(feed, encoding='utf-8', xml_declaration=True)
        subprocess.run([str(ROOT / 'macos/.build/dependencies/sparkle-bin/sign_update'),
                        '--account', config.ACCOUNT, str(feed)], check=True)
    print('Staged signed update in ' + str(output))
    print('Release tag: ' + tag + ' (publish together with the verified Windows assets)')
    print('Publish the archive first, then the unchanged signed feed to macos/appcast.xml on main in ' + config.HOSTING['repository'])


if __name__ == '__main__':
    main()
