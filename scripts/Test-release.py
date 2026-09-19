"""Offline regression checks for shared-release asset validation."""
import importlib.util
import pathlib
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


if __name__ == '__main__':
    unittest.main()
