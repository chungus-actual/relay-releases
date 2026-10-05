"""Publish one verified Windows/macOS release, then advance the signed Sparkle feed.

Run on the signing Mac after Windows tag CI succeeds and the Mac update is notarized
and packaged. Does not replace existing releases or change historical feed entries.
"""
import argparse
import base64
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess
import tempfile
import urllib.request
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent
REPO = 'chungus-actual/relay-releases'
SOURCE = 'chungus-actual/relay'
NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
TOOLS = ROOT / 'macos/.build/dependencies/sparkle-bin'
ACCOUNT = 'com.chungus-actual.relay.updates'


def run(*args, capture=False):
    return subprocess.run(list(map(str, args)), check=True, cwd=ROOT,
                          stdout=subprocess.PIPE if capture else None, text=capture).stdout


def api(repo, endpoint):
    return json.loads(run('gh', 'api', f'repos/{repo}/{endpoint}', capture=True))


def digest(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def check_manifest(path, assets):
    entries = {}
    for line in path.read_text(encoding='utf-8-sig').splitlines():
        match = re.fullmatch(r'([a-fA-F0-9]{64})\s+\*?([^/\\]+)', line)
        if not match or match[2] in entries:
            raise ValueError('Invalid/duplicate checksum entry')
        entries[match[2]] = match[1].lower()
    if set(entries) != {asset.name for asset in assets}:
        raise ValueError('Checksum manifest must cover exactly the expected assets')
    for asset in assets:
        if entries[asset.name] != digest(asset):
            raise ValueError('Checksum mismatch: ' + asset.name)


def enclosures(data):
    result = {}
    for item in ET.fromstring(data).findall('./channel/item'):
        build = item.findtext(NS + 'version')
        if build in result:
            raise ValueError('Duplicate feed build')
        result[build] = dict(item.find('enclosure').attrib)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--windows-dir', type=pathlib.Path, required=True)
    parser.add_argument('--macos-dir', type=pathlib.Path, default=ROOT / 'dist/macos/updates')
    parser.add_argument('--validate-only', action='store_true')
    args = parser.parse_args()
    version = args.version
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('Invalid version')
    if version != ET.parse(ROOT / 'Relay.csproj').findtext('./PropertyGroup/Version'):
        raise ValueError('Version differs from source project')
    tag = 'v' + version
    notes = ROOT / 'docs/releases' / (version + '.md')
    if not notes.is_file():
        raise ValueError('Missing release notes')
    baseline = api(REPO, 'contents/macos/appcast.xml')
    old_latest = api(REPO, 'releases/latest')['tag_name']
    feed = args.macos_dir / 'appcast.xml'
    feed_data = feed.read_bytes()
    item = ET.fromstring(feed_data).find('./channel/item')
    build = item.findtext(NS + 'version')
    if not build or not re.fullmatch(r'[1-9][0-9]*', build) or item.findtext(NS + 'shortVersionString') != version:
        raise ValueError('Mac feed version differs from shared release')
    archive = args.macos_dir / ('Relay-' + build + '.zip')
    expected_url = f'https://github.com/{REPO}/releases/download/{tag}/{archive.name}'
    fresh = enclosures(feed_data)
    original = enclosures(base64.b64decode(baseline['content']))
    if int(build) <= max(map(int, original)) or set(fresh) != set(original) | {build}:
        raise ValueError('Feed must add exactly one increasing build')
    for number, enclosure in original.items():
        if fresh.get(number) != enclosure:
            raise ValueError('Historical download changed: ' + number)
    if fresh[build]['url'] != expected_url or int(fresh[build]['length']) != archive.stat().st_size:
        raise ValueError('Incorrect macOS archive URL or size')
    run(TOOLS / 'sign_update', '--account', ACCOUNT, '--verify', feed)
    run(TOOLS / 'sign_update', '--account', ACCOUNT, '--verify', archive, fresh[build][NS + 'edSignature'])
    with tempfile.TemporaryDirectory(dir=ROOT / 'macos/.build') as directory:
        run('ditto', '-x', '-k', archive, directory)
        app = pathlib.Path(directory) / 'Relay.app'
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if info['CFBundleVersion'] != build or info['CFBundleShortVersionString'] != version or info.get('RelayExperimentalChromium'):
            raise ValueError('Archive metadata differs from feed')
        run('codesign', '--verify', '--deep', '--strict', app)
        run('xcrun', 'stapler', 'validate', app)
        run('spctl', '--assess', '--type', 'execute', app)
    windows = [args.windows_dir / name for name in [f'Relay-{version}-Setup-x64.exe', f'Relay-{version}-win-x64.zip']]
    windows_checksums = args.windows_dir / 'SHA256SUMS.txt'
    check_manifest(windows_checksums, windows)
    source = api(SOURCE, 'releases/tags/' + tag)
    if source['draft']:
        raise ValueError('Windows CI release is not published')
    for asset in windows + [windows_checksums]:
        matches = [entry for entry in source['assets'] if entry['name'] == asset.name]
        if len(matches) != 1 or matches[0].get('digest') != 'sha256:' + digest(asset):
            raise ValueError('Windows asset differs from verified CI release: ' + asset.name)
    mac_checksums = args.macos_dir / 'SHA256SUMS-macos.txt'
    check_manifest(mac_checksums, [archive, feed])
    assets = windows + [windows_checksums, archive, feed, mac_checksums]
    if args.validate_only:
        print('Verified Windows CI assets, notarized macOS archive, signed feed, and historical downloads')
        return
    work = ROOT / 'macos/.build' / ('publish-' + tag)
    work.mkdir(exist_ok=True)
    (work / 'feed-before.json').write_text(json.dumps(baseline))
    run('gh', 'release', 'create', tag, '--repo', REPO, '--draft', '--latest=false',
        '--title', 'Relay ' + version, '--notes-file', notes, *assets)
    with tempfile.TemporaryDirectory(dir=work) as directory:
        run('gh', 'release', 'download', tag, '--repo', REPO, '--dir', directory)
        for asset in assets:
            if digest(pathlib.Path(directory) / asset.name) != digest(asset):
                raise ValueError('Uploaded bytes differ: ' + asset.name)
    if api(REPO, 'contents/macos/appcast.xml')['sha'] != baseline['sha'] or api(REPO, 'releases/latest')['tag_name'] != old_latest:
        raise ValueError('Public release state changed; draft retained for review')
    run('gh', 'release', 'edit', tag, '--repo', REPO, '--draft=false', '--prerelease=false', '--latest')
    with urllib.request.urlopen(expected_url, timeout=60) as response:
        if hashlib.sha256(response.read()).hexdigest() != digest(archive):
            raise ValueError('Public Mac download differs; feed not advanced')
    request = work / 'feed-update.json'
    request.write_text(json.dumps(dict(message=f'Publish shared Relay {version} signed macOS update feed',
        sha=baseline['sha'], branch='main', content=base64.b64encode(feed_data).decode())))
    run('gh', 'api', '--method', 'PUT', f'repos/{REPO}/contents/macos/appcast.xml', '--input', request)
    if base64.b64decode(api(REPO, 'contents/macos/appcast.xml')['content']) != feed_data:
        raise ValueError('Published signed feed differs')
    latest = api(REPO, 'releases/latest')
    if latest['tag_name'] != tag or latest['draft'] or latest['prerelease'] or {a['name'] for a in latest['assets']} != {a.name for a in assets}:
        raise ValueError('Shared latest release metadata differs')
    (work / 'published.json').write_text(json.dumps(dict(version=version, build=build, url=latest['html_url']), indent=2)+'\n')
    print('Published ' + latest['html_url'] + ' and verified both updater feeds')


if __name__ == '__main__':
    main()
