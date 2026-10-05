"""Export release-tagged source without private history or repository instructions."""
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

MANIFEST = '.release-source.json'
PRESERVED = {'macos/appcast.xml', 'docs/updates.md'}


def git(root, *args, binary=False):
    return subprocess.check_output(['git', '-C', str(root), *args],
                                   encoding=None if binary else 'utf-8')


def safe_path(name):
    path = pathlib.PurePosixPath(name)
    if not name or path.is_absolute() or '..' in path.parts or '\\' in name or ':' in name or '.git' in path.parts:
        raise ValueError('Unsafe source path: ' + name)
    return path


def excluded(name):
    path = safe_path(name)
    return path.name == 'AGENTS.md' or path.parts[0] == '.github'



def tree_files(root, ref):
    """Read raw Git blobs, independent of OS or checkout/archive EOL conversion."""
    records = git(root, 'ls-tree', '-rz', ref, binary=True).split(b'\0')
    entries = []
    for record in filter(None, records):
        metadata, name = record.split(b'\t', 1)
        mode, kind, oid = metadata.decode('ascii').split()
        name = name.decode('utf-8')
        safe_path(name)
        if kind != 'blob' or mode not in {'100644', '100755'}:
            raise ValueError('Unsupported source entry: ' + name)
        entries.append((name, mode, oid))
    payload = subprocess.check_output(['git', '-C', str(root), 'cat-file', '--batch'],
                                     input=''.join(oid + '\n' for _, _, oid in entries).encode('ascii'))
    files, modes, offset = {}, {}, 0
    for name, mode, oid in entries:
        end = payload.index(b'\n', offset)
        actual_oid, kind, size = payload[offset:end].decode('ascii').split()
        if actual_oid != oid or kind != 'blob':
            raise ValueError('Unexpected Git object: ' + name)
        size = int(size)
        files[name] = payload[end + 1:end + 1 + size]
        modes[name] = mode
        offset = end + 2 + size
    return files, modes


def export(root, version):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('Invalid release version')
    commit = git(root, 'rev-parse', '--verify', 'refs/tags/v' + version + '^{commit}').strip()
    files, modes = tree_files(root, commit)
    for name in list(files):
        if excluded(name):
            del files[name]
            del modes[name]
        elif name in PRESERVED:
            raise ValueError('Unsupported source entry: ' + name)
    if ET.fromstring(files['Relay.csproj']).findtext('./PropertyGroup/Version') != version:
        raise ValueError('Source tag has a different Windows version')
    if plistlib.loads(files['macos/Info.plist'])['CFBundleShortVersionString'] != version:
        raise ValueError('Source tag has a different macOS version')
    for name in files:
        if any(part in {'.tools', '.test-data', '.build', 'bin', 'obj', 'dist', 'artifacts'} for part in pathlib.PurePosixPath(name).parts) or pathlib.PurePosixPath(name).suffix.lower() in {'.pfx', '.p12', '.key'} or pathlib.PurePosixPath(name).name.startswith('.env'):
            raise ValueError('Local-only file tracked in source: ' + name)
    manifest = dict(hash_format='sha256 of raw Git blob content (before checkout/archive line-ending conversion)', version=version, source_commit=commit, source_tag='v' + version,
                    excluded=['AGENTS.md (at any depth)', '.github/'],
                    files={name: dict(sha256=hashlib.sha256(data).hexdigest(), mode=modes[name])
                           for name, data in sorted(files.items())})
    return files, modes, manifest


def stage(checkout, files, modes, manifest):
    """Replace the release snapshot; keep the existing signed feed byte-for-byte."""
    checkout = pathlib.Path(checkout).resolve()
    tracked = git(checkout, 'ls-files', '-z').split('\0')
    feed = checkout / 'macos/appcast.xml'
    original_feed = feed.read_bytes()
    wanted = set(files) | PRESERVED | {MANIFEST}
    # Only unlink enumerated tracked files inside this checkout, never directories.
    for name in filter(None, tracked):
        target = checkout.joinpath(*safe_path(name).parts)
        if not target.resolve().is_relative_to(checkout):
            raise ValueError('Source path escapes checkout: ' + name)
        if name not in wanted:
            target.unlink()
    for name, data in files.items():
        target = checkout.joinpath(*safe_path(name).parts)
        if not target.resolve().is_relative_to(checkout):
            raise ValueError('Source path escapes checkout: ' + name)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    (checkout / MANIFEST).write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    git(checkout, 'config', 'core.autocrlf', 'false')
    git(checkout, 'config', 'core.eol', 'lf')
    git(checkout, 'add', '--all')
    for mode in ['100644', '100755']:
        names = [name for name in modes if modes[name] == mode]
        for offset in range(0, len(names), 64):
            git(checkout, 'update-index', '--chmod=' + ('+x' if mode == '100755' else '-x'), '--', *names[offset:offset + 64])
    if feed.read_bytes() != original_feed or git(checkout, 'show', ':macos/appcast.xml', binary=True) != original_feed:
        raise ValueError('Signed update feed changed during source export')


def verify(checkout, ref, files, manifest):
    actual, modes = tree_files(checkout, ref)
    if any(excluded(name) for name in actual):
        raise ValueError('Public snapshot contains repository instructions/automation')
    if json.loads(actual[MANIFEST]) != manifest:
        raise ValueError('Existing public source tag identifies different source')
    for name, data in files.items():
        if actual.get(name) != data or modes.get(name) != manifest['files'][name]['mode']:
            raise ValueError('Public source differs from release: ' + name)


def publish(root, version, work, repo):
    files, modes, manifest = export(root, version)
    checkout = pathlib.Path(tempfile.mkdtemp(prefix='public-source-', dir=work))
    subprocess.run(['git', 'clone', '--depth', '1', '--single-branch', '--no-tags',
                    'https://github.com/' + repo + '.git', str(checkout)], check=True)
    tag = 'source-v' + version
    existing = git(checkout, 'ls-remote', '--tags', 'origin', 'refs/tags/' + tag).strip()
    if existing:
        git(checkout, 'fetch', 'origin', 'tag', tag)
        verify(checkout, tag, files, manifest)
        return git(checkout, 'rev-parse', tag + '^{commit}').strip()
    stage(checkout, files, modes, manifest)
    for key in ['user.name', 'user.email']:
        git(checkout, 'config', key, git(root, 'config', key).strip())
    git(checkout, 'commit', '-m', 'Publish Relay ' + version + ' release source [skip ci]',
        '-m', 'Source snapshot: chungus-actual/relay@' + manifest['source_commit'])
    verify(checkout, 'HEAD', files, manifest)
    git(checkout, 'tag', '-a', tag, '-m', 'Relay ' + version + ' release source')
    git(checkout, 'push', '--atomic', 'origin', 'HEAD:refs/heads/main', 'refs/tags/' + tag)
    return git(checkout, 'rev-parse', 'HEAD').strip()
