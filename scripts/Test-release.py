"""Offline regression checks for shared-release asset validation."""
import importlib.util
import pathlib
import plistlib
import subprocess
import release_source
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('publish_release', ROOT / 'scripts/Publish-Release.py')
publish = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publish)


class ReleaseChecks(unittest.TestCase):
    def test_exact_asset_bytes_and_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            asset = root / 'package.zip'
            asset.write_bytes(b'verified package')
            manifest = root / 'SHA256SUMS.txt'
            line = publish.digest(asset) + '  package.zip\n'
            manifest.write_text(line)
            publish.check_manifest(manifest, [asset])
            for invalid in [line + line, line + '0' * 64 + '  extra.zip\n', '0' * 64 + '  ../package.zip\n']:
                manifest.write_text(invalid)
                with self.assertRaises(ValueError):
                    publish.check_manifest(manifest, [asset])
            manifest.write_text(line)
            asset.write_bytes(b'tampered package')
            with self.assertRaisesRegex(ValueError, 'Checksum mismatch'):
                publish.check_manifest(manifest, [asset])

    def test_feed_enclosures_preserve_signature_and_reject_duplicate_build(self):
        item = '<item><sparkle:version>15</sparkle:version><enclosure url="https://example.test/old.zip" length="123" sparkle:edSignature="signed" /></item>'
        def feed(items):
            return ('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>' + items + '</channel></rss>').encode()
        result = publish.enclosures(feed(item))
        self.assertEqual(result['15'][publish.NS + 'edSignature'], 'signed')
        self.assertEqual(result['15']['url'], 'https://example.test/old.zip')
        with self.assertRaisesRegex(ValueError, 'Duplicate feed build'):
            publish.enclosures(feed(item + item))


class PublicSourceChecks(unittest.TestCase):
    def repo(self, root):
        subprocess.run(['git', 'init', '-q', str(root)], check=True)
        release_source.git(root, 'config', 'user.name', 'Release test')
        release_source.git(root, 'config', 'user.email', 'release@example.test')
        release_source.git(root, 'config', 'core.autocrlf', 'false')
        release_source.git(root, 'config', 'core.eol', 'lf')
        release_source.git(root, 'config', 'core.safecrlf', 'false')

    def commit(self, root):
        release_source.git(root, 'add', '--all')
        release_source.git(root, 'commit', '-qm', 'Fixture')

    def fixture(self, root):
        self.repo(root)
        (root / 'macos').mkdir()
        (root / 'Relay.csproj').write_text('<Project><PropertyGroup><Version>1.2.3</Version></PropertyGroup></Project>')
        (root / 'macos/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '1.2.3'}))
        (root / 'app.cs').write_bytes(b'released source\n')
        (root / '.gitattributes').write_text('* text=auto\nmacos/appcast.xml -text\n')
        (root / 'AGENTS.md').write_text('private instructions')
        (root / 'macos/AGENTS.md').write_text('nested instructions')
        (root / '.github').mkdir()
        (root / '.github/workflow.yml').write_text('private automation')
        self.commit(root)
        release_source.git(root, 'tag', 'v1.2.3')

    def test_tagged_source_excludes_instructions_untracked_files_and_later_edits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.fixture(root)
            release_source.git(root, 'config', 'core.autocrlf', 'true')
            (root / 'app.cs').write_bytes(b'unreleased changes')
            (root / 'credentials.pfx').write_bytes(b'local credentials')
            files, modes, manifest = release_source.export(root, '1.2.3')
            self.assertEqual(files['app.cs'], b'released source\n')
            self.assertEqual(modes['app.cs'], '100644')
            self.assertFalse(any(release_source.excluded(name) for name in files))
            self.assertNotIn('credentials.pfx', files)
            self.assertEqual(manifest['source_commit'], release_source.git(root, 'rev-parse', 'v1.2.3').strip())
            with self.assertRaises(ValueError):
                release_source.export(root, '../1.2.3')

    def test_snapshot_removes_stale_code_and_agents_preserves_feed_and_verifies_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source, public = root / 'source', root / 'public'
            source.mkdir()
            self.fixture(source)
            self.repo(public)
            (public / 'macos').mkdir()
            feed = public / 'macos/appcast.xml'
            feed.write_bytes(b'signed feed: must stay identical\r\n')
            (public / 'AGENTS.md').write_text('old public instructions')
            (public / 'removed.cs').write_text('stale source')
            self.commit(public)
            files, modes, manifest = release_source.export(source, '1.2.3')
            release_source.stage(public, files, modes, manifest)
            self.assertFalse((public / 'AGENTS.md').exists())
            self.assertFalse((public / 'removed.cs').exists())
            self.assertEqual(feed.read_bytes(), b'signed feed: must stay identical\r\n')
            self.commit(public)
            release_source.verify(public, 'HEAD', files, manifest)
            (public / 'app.cs').write_text('tampered source')
            self.commit(public)
            with self.assertRaisesRegex(ValueError, 'Public source differs'):
                release_source.verify(public, 'HEAD', files, manifest)
            different = dict(manifest, source_commit='0' * 40)
            with self.assertRaisesRegex(ValueError, 'different source'):
                release_source.verify(public, 'HEAD', files, different)

    def test_unsafe_snapshot_paths_are_rejected(self):
        for name in ['../outside', '/absolute', 'C:/outside', 'folder/../../outside', '.git/config', 'folder\\outside']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                release_source.safe_path(name)


if __name__ == '__main__':
    unittest.main()
