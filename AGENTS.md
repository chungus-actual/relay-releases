# Cross-platform behavior

Relay targets Windows (WPF/WebView2) and macOS (SwiftUI/WebKit and Chromium). Changes to shared service behavior, unread detection, notifications, media controls, downloads, account state, or settings must consider both platforms in the same change.

- Inspect both implementations before changing shared behavior. Implement matching behavior on both platforms unless the user explicitly requests a platform-specific change or an engine/API limitation prevents it.
- Keep provider scripts equivalent. For duplicated browser JavaScript, extend the existing script parity checks in `macos/Tests/RelayMacTests/RelayMacTests.swift`; prefer a shared source when practical.
- Add meaningful regressions for the behavior, including stale/duplicate events and clearing state where relevant. Update both platform test fixtures when the feature exists on both.
- Run the macOS model checks (`bash scripts/Test-macOS.sh`) for shared changes; they also compare provider scripts with Windows. Run affected browser checks and the Windows smoke checks where the environment supports them.
- Never claim platform parity from matching source alone. State which builds and runtime checks passed, which could not run, and any remaining engine limitations. Record intentional differences in the platform documentation.
- Changes to parity-checked Windows files must continue to trigger the macOS CI checks. Keep workflow path filters in sync when adding shared scripts.

# Local testing and releases

- Keep one testing application at `dist/macos/Relay.app`; do not create alternate distribution forks.
- Preserve existing service profiles, the local signing certificate, and WebCrypto keys. Do not weaken Keychain permissions to suppress prompts.
- Published releases and their signed archives are immutable. Publish a new build for fixes; preserve historical download URLs in the signed update feed.
