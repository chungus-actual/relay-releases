"""Publish one verified Windows/macOS release, then advance the signed Sparkle feed.

Run on the signing Mac after verified Windows packages are published to the private
source release and the Mac update is notarized and packaged. --macos-only publishes
a separate Mac build without changing Windows or GitHub Latest. Does not replace
existing releases or change historical feed entries.
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
import release_source

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


def check_macos_only_source(root, tag, windows_tag):
    if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', windows_tag):
        raise ValueError('Windows Latest must remain a shared version release')
    changed = release_source.git(root, 'diff', '--name-only', windows_tag + '^{commit}', tag + '^{commit}',
        '--', 'windows', 'Assets', 'Relay.csproj', 'services.json', 'reporting.json').strip()
    if changed:
        raise ValueError('Mac-only release changes Windows source or shared runtime assets: ' + changed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--windows-dir', type=pathlib.Path)
    parser.add_argument('--macos-only', action='store_true', help='Publish a new Mac build; preserve Windows and GitHub Latest')
    parser.add_argument('--macos-dir', type=pathlib.Path, default=ROOT / 'dist/macos/updates')
    parser.add_argument('--validate-only', action='store_true')
    args = parser.parse_args()
    if not args.macos_only and args.windows_dir is None:
        parser.error('--windows-dir is required for a shared release')
    if args.macos_only and args.windows_dir is not None:
        parser.error('--windows-dir cannot be used with --macos-only')
    version = args.version
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('Invalid version')
    if version != ET.parse(ROOT / 'Relay.csproj').findtext('./PropertyGroup/Version'):
        raise ValueError('Version differs from source project')
    baseline = api(REPO, 'contents/macos/appcast.xml')
    old_latest = api(REPO, 'releases/latest')['tag_name']
    feed = args.macos_dir / 'appcast.xml'
    feed_data = feed.read_bytes()
    item = ET.fromstring(feed_data).find('./channel/item')
    build = item.findtext(NS + 'version')
    if not build or not re.fullmatch(r'[1-9][0-9]*', build) or item.findtext(NS + 'shortVersionString') != version:
        raise ValueError('Mac feed version differs from shared release')
    tag = f'macos-{version}-{build}' if args.macos_only else 'v' + version
    release_source.export(ROOT, version, tag) # Validate the tagged source before any publication.
    if args.macos_only:
        check_macos_only_source(ROOT, tag, old_latest)
    notes = ROOT / 'docs/releases' / ((tag if args.macos_only else version) + '.md')
    if not notes.is_file():
        raise ValueError('Missing release notes')
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
    windows_assets = []
    if not args.macos_only:
        windows = [args.windows_dir / name for name in [f'Relay-{version}-Setup-x64.exe', f'Relay-{version}-win-x64.zip']]
        windows_checksums = args.windows_dir / 'SHA256SUMS.txt'
        check_manifest(windows_checksums, windows)
        source = api(SOURCE, 'releases/tags/' + tag)
        if source['draft']:
            raise ValueError('Verified Windows source release is not published')
        windows_assets = windows + [windows_checksums]
        for asset in windows_assets:
            matches = [entry for entry in source['assets'] if entry['name'] == asset.name]
            if len(matches) != 1 or matches[0].get('digest') != 'sha256:' + digest(asset):
                raise ValueError('Windows asset differs from verified source release: ' + asset.name)
    mac_checksums = args.macos_dir / 'SHA256SUMS-macos.txt'
    check_manifest(mac_checksums, [archive, feed])
    assets = windows_assets + [archive, feed, mac_checksums]
    if args.validate_only:
        print('Verified source, notarized macOS archive, signed feed, historical downloads, and ' +
              ('unchanged Windows source' if args.macos_only else 'Windows source release assets'))
        return
    work = ROOT / 'macos/.build' / ('publish-' + tag)
    work.mkdir(exist_ok=True)
    (work / 'feed-before.json').write_text(json.dumps(baseline))
    public_source = release_source.publish(ROOT, version, work, REPO, tag)
    title = f'Relay macOS {version} (build {build})' if args.macos_only else 'Relay ' + version
    run('gh', 'release', 'create', tag, '--repo', REPO, '--draft', '--latest=false',
        '--title', title, '--notes-file', notes, '--target', public_source, *assets)
    with tempfile.TemporaryDirectory(dir=work) as directory:
        run('gh', 'release', 'download', tag, '--repo', REPO, '--dir', directory)
        for asset in assets:
            if digest(pathlib.Path(directory) / asset.name) != digest(asset):
                raise ValueError('Uploaded bytes differ: ' + asset.name)
    if api(REPO, 'contents/macos/appcast.xml')['sha'] != baseline['sha'] or api(REPO, 'releases/latest')['tag_name'] != old_latest:
        raise ValueError('Public release state changed; draft retained for review')
    run('gh', 'release', 'edit', tag, '--repo', REPO, '--draft=false', '--prerelease=false',
        '--latest=false' if args.macos_only else '--latest')
    with urllib.request.urlopen(expected_url, timeout=60) as response:
        if hashlib.sha256(response.read()).hexdigest() != digest(archive):
            raise ValueError('Public Mac download differs; feed not advanced')
    request = work / 'feed-update.json'
    request.write_text(json.dumps(dict(message=f'Publish Relay {tag} signed macOS update feed',
        sha=baseline['sha'], branch='main', content=base64.b64encode(feed_data).decode())))
    run('gh', 'api', '--method', 'PUT', f'repos/{REPO}/contents/macos/appcast.xml', '--input', request)
    if base64.b64decode(api(REPO, 'contents/macos/appcast.xml')['content']) != feed_data:
        raise ValueError('Published signed feed differs')
    released = api(REPO, 'releases/tags/' + tag)
    if released['draft'] or released['prerelease'] or {a['name'] for a in released['assets']} != {a.name for a in assets}:
        raise ValueError('Published release metadata differs')
    if api(REPO, 'releases/latest')['tag_name'] != (old_latest if args.macos_only else tag):
        raise ValueError('Unexpected GitHub Latest release')
    (work / 'published.json').write_text(json.dumps(dict(version=version, build=build, url=released['html_url']), indent=2)+'\n')
    print('Published ' + released['html_url'] + ' and verified both updater feeds')


if __name__ == '__main__':
    main()
