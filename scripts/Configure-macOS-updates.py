"""Set build metadata and opt into signed Sparkle updates before code signing."""
import base64
import json
import os
import pathlib
import plistlib
import re
import subprocess
import sys
import urllib.parse
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent
ACCOUNT = 'com.chungus-actual.relay.updates'
HOSTING = json.loads((ROOT / 'macos/Updates.json').read_text())


def https_url(value):
    url = urllib.parse.urlsplit(value)
    if url.scheme != 'https' or not url.hostname or url.username or url.password or url.fragment:
        raise ValueError('Expected an HTTPS URL without credentials or a fragment')
    return value


def public_key():
    return subprocess.check_output([
        str(ROOT / 'macos/.build/dependencies/sparkle-bin/generate_keys'),
        '--account', ACCOUNT, '-p'], text=True).strip()


def configure(path):
    info = plistlib.loads(path.read_bytes())
    # Windows and macOS share the marketing version; Sparkle keeps its own increasing build number.
    info['CFBundleShortVersionString'] = ET.parse(ROOT / 'Relay.csproj').findtext('./PropertyGroup/Version')
    experimental = os.environ.get('RELAY_EXPERIMENTAL_CHROMIUM', '0')
    if experimental not in ('0', '1'):
        raise ValueError('RELAY_EXPERIMENTAL_CHROMIUM must be 0 or 1')
    if os.environ.get('RELAY_CHROMIUM', '0') != '0':
        raise ValueError('RELAY_CHROMIUM is retired; use RELAY_EXPERIMENTAL_CHROMIUM for development only')
    if experimental == '1' and (os.environ.get('RELAY_DISTRIBUTION', '0') != '0'
                               or os.environ.get('RELAY_UPDATES', '0') != '0'
                               or os.environ.get('RELAY_UPDATE_FEED_URL')):
        raise ValueError('Experimental Chromium cannot be used in distribution or update-enabled builds')
    info['RelayExperimentalChromium'] = experimental == '1'
    for variable, field, pattern in [
        ('RELAY_VERSION', 'CFBundleShortVersionString', r'[0-9]+\.[0-9]+\.[0-9]+'),
        ('RELAY_BUILD_NUMBER', 'CFBundleVersion', r'[1-9][0-9]*'),
    ]:
        value = os.environ.get(variable, info[field])
        if not re.fullmatch(pattern, value):
            raise ValueError('Invalid ' + variable)
        info[field] = value
    enabled = os.environ.get('RELAY_UPDATES', '0')
    if enabled not in ('0', '1'):
        raise ValueError('RELAY_UPDATES must be 0 or 1')
    feed = os.environ.get('RELAY_UPDATE_FEED_URL', HOSTING['feedURL'] if enabled == '1' else '')
    key = os.environ.get('RELAY_UPDATE_PUBLIC_KEY', '')
    if key and not feed:
        raise ValueError('RELAY_UPDATE_PUBLIC_KEY requires RELAY_UPDATE_FEED_URL')
    for field in ['SUFeedURL', 'SUPublicEDKey', 'SUEnableAutomaticChecks',
                  'SUAutomaticallyUpdate', 'SUVerifyUpdateBeforeExtraction', 'SURequireSignedFeed']:
        info.pop(field, None)
    if feed:
        https_url(feed)
        key = key or public_key()
        if len(base64.b64decode(key, validate=True)) != 32:
            raise ValueError('Invalid Sparkle public key')
        info.update(SUFeedURL=feed, SUPublicEDKey=key,
                    SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=False,
                    SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True)
    path.write_bytes(plistlib.dumps(info))


if __name__ == '__main__':
    configure(pathlib.Path(sys.argv[1]))
