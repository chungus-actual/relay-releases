Developer ID signed and Apple-notarized release of the latest Relay macOS app.

- Includes the tester-confirmed file-drop routing fix from 0.1.12: attachments go to the visible service instead of a retained background browser.
- Preserves the browser-host correction for sidebar/top-tab changes, faster service switching, consistent Safari version identification, and the restored title-bar Relay logo.
- Keeps existing service profiles, WebCrypto keys, and the Sparkle update signing key. Normal builds remain WebKit-only.

Requires macOS 14 or later on Apple silicon or Intel. This build carries a stapled Apple notarization ticket and passes Gatekeeper assessment. Earlier release archives and Windows releases are unchanged. Menu-bar icon visibility remains under investigation.

Validation: universal Developer ID signature, hardened runtime and timestamp, Apple notarization, ticket validation, Gatekeeper assessment, signed archive/feed verification, and downloaded asset checksums. The underlying code passed macOS model/script-parity, native file-drop, WebKit, and isolated development Chromium checks. Windows runtime checks were not run on this Mac.
