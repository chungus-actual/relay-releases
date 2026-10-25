# Relay macOS 0.6.12 — build 29

- Release macOS media controls when a short notification finishes or stops, so an idle notification does not keep Relay registered as the current media player.
- Add **Settings → General → Media controls** to disable Relay's playback controls and website Media Session commands. Quit and reopen Relay after changing it; audio playback remains available.

WebKit can still claim macOS media keys during ordinary audio/video playback. The setting disables Relay's media integration; it is not a complete system media-key opt-out.

This update is for macOS only. Windows remains on 0.6.12 with unchanged source and packages. Existing accounts, sign-ins, encrypted-chat data and settings are preserved.

[Download for Apple silicon](https://github.com/chungus-actual/relay-releases/releases/download/macos-0.6.12-29/Relay-29.zip) — macOS 14 or later. Existing Mac users can use **Check for Updates** in Relay.

Intel Macs can continue using the [0.6.7 universal download](https://github.com/chungus-actual/relay-releases/releases/tag/v0.6.7).
