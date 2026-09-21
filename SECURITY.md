# Local storage and updates

Relay uses the services' own sign-in pages. It has no Relay account, server, or telemetry, and does not collect passwords or import another browser's credentials.

## Account data

Windows uses WebView2 profiles. Settings and browser data live under `%LOCALAPPDATA%\Relay`.

macOS uses WebKit data stores, one per account. Settings live at `~/Library/Application Support/Relay/macOS/settings.json`; WebKit manages the website data and Keychain storage used by the services.

Separate accounts keep separate website sessions. They are not OS security boundaries or a Relay-encrypted vault. Website storage, caches, and diagnostic logs can contain sensitive information. Relay has no master-password lock. Include only relevant, redacted diagnostics when reporting a problem.

## Release integrity

Downloads come from [this repository's releases](https://github.com/chungus-actual/relay-releases/releases). Published packages are immutable; fixes receive a new version.

- **Windows:** installers are unsigned. The updater checks package names, release paths, and SHA-256 checksums before installation. Checksums detect changed bytes; they do not independently authenticate the publisher.
- **macOS:** release apps are Developer ID signed and notarized. Sparkle verifies signed update archives using the public key bundled with Relay.

The macOS update feed remains at [`macos/appcast.xml`](macos/appcast.xml). [Checksum instructions](docs/updates.md) are available for manual downloads.
