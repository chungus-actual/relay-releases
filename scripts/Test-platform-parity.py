"""Offline provider-script parity checks runnable on Windows and macOS.

These compare the same embedded scripts as RelayMacTests; native suites remain
responsible for behavior in each browser engine.
"""
import difflib
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
PAIRS = [
    ("Messenger unread", "UnreadDetection.cs", "MessengerUnreadScript", "MessengerUnread.swift", "script"),
    ("Gmail unread", "UnreadDetection.cs", "GmailUnreadScript", "UnreadModels.swift", "script"),
    ("Messenger layout", "MessengerChrome.cs", "MessengerChromeScript", "MessengerChrome.swift", "script"),
    ("Media controls", "MediaControls.cs", "MediaBridgeScript", "MediaBridge.swift", "template"),
]


def extract(path, name, swift=False):
    source = path.read_text(encoding="utf-8")
    pattern = (r"static let " if swift else r"private const string ") + re.escape(name)
    pattern += r'\s*=\s*#?"""\n(.*?)\n\s*"""'
    match = re.search(pattern, source, re.DOTALL)
    if not match:
        raise ValueError(f"Missing script {name} in {path}")
    return [line.strip() for line in match[1].splitlines() if line.strip()]


class PlatformParityChecks(unittest.TestCase):
    def test_provider_scripts_match(self):
        for label, windows, constant, mac, field in PAIRS:
            with self.subTest(provider=label):
                left = extract(ROOT / windows, constant)
                right = extract(ROOT / "macos/Sources/RelayMac" / mac, field, swift=True)
                self.assertEqual(left, right, "\n".join(difflib.unified_diff(
                    left, right, fromfile=windows, tofile=mac, lineterm="")))


if __name__ == "__main__":
    unittest.main()
