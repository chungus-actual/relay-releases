"""Exercise development-engine gates without signing, networking, or real settings."""
import importlib.util
import os
import pathlib
import plistlib
import tempfile
import unittest
import xml.etree.ElementTree as ET
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('relay_config', ROOT / 'scripts/Configure-macOS-updates.py')
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class BuildConfigChecks(unittest.TestCase):
    def configure(self, environment):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'Info.plist'
            info = plistlib.loads((ROOT / 'macos/Info.plist').read_bytes())
            # A reused plist must not retain experimental enablement or an old feed.
            info.update(RelayExperimentalChromium=True, SUFeedURL='https://example.com/old.xml')
            path.write_bytes(plistlib.dumps(info))
            with patch.dict(os.environ, environment, clear=True):
                config.configure(path)
            return plistlib.loads(path.read_bytes())

    def test_normal_build_removes_experiment_and_old_feed(self):
        info = self.configure({})
        self.assertIs(info['RelayExperimentalChromium'], False)
        self.assertNotIn('SUFeedURL', info)

    def test_shared_version_and_build_override(self):
        version = ET.parse(ROOT / 'Relay.csproj').findtext('./PropertyGroup/Version')
        self.assertEqual(self.configure({})['CFBundleShortVersionString'], version)
        info = self.configure({'RELAY_VERSION': '9.8.7', 'RELAY_BUILD_NUMBER': '123'})
        self.assertEqual(info['CFBundleShortVersionString'], '9.8.7')
        self.assertEqual(info['CFBundleVersion'], '123')

    def test_explicit_development_build(self):
        info = self.configure({'RELAY_EXPERIMENTAL_CHROMIUM': '1'})
        self.assertIs(info['RelayExperimentalChromium'], True)
        self.assertNotIn('SUFeedURL', info)

    def test_experimental_distribution_and_updates_rejected(self):
        for key, value in [('RELAY_DISTRIBUTION', '1'), ('RELAY_UPDATES', '1'),
                           ('RELAY_UPDATE_FEED_URL', 'https://example.com/feed.xml')]:
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'distribution or update-enabled'):
                self.configure({'RELAY_EXPERIMENTAL_CHROMIUM': '1', key: value})

    def test_retired_and_invalid_flags(self):
        for environment in [{'RELAY_CHROMIUM': '1'}, {'RELAY_EXPERIMENTAL_CHROMIUM': 'yes'}]:
            with self.subTest(environment=environment), self.assertRaises(ValueError):
                self.configure(environment)


if __name__ == '__main__':
    unittest.main()
