Relay now uses WebKit for all normal macOS accounts, with faster service switching and consistent browser version identification.

- Restores Relay’s “R” logo in the title bar. The menu-bar icon remains under investigation after reports that it can be invisible.
- Keeps loaded browser views attached when switching services, addressing a source of sluggish transitions and blank-content reports. Local fixtures show lower switching overhead; live-provider verification continues.
- Applies the installed desktop Safari version identifier to every WebKit service and its popups, including Google Calendar.
- Removes Chromium and the engine selector from normal builds. The app bundle is approximately 11 MiB on disk, down from approximately 611 MiB in the previous local Chromium-enabled build.
- Accounts previously set to Chromium resume their existing WebKit profiles. Both engine profiles are preserved; accounts without an existing WebKit sign-in may need to sign in again.
- Includes Messenger activation refreshes that preserve drafts and scroll position, plus the Gmail unread modes and scrolling media titles from earlier previews.

Requires macOS 14 or later on Apple silicon or Intel. This preview is self-signed with the existing Relay Local Development certificate and is not notarized. Existing service profiles and WebCrypto keys are preserved. macOS or WebCrypto may request approval when opening the new build.

Validation: macOS model/script parity, WebKit browser regressions, live shell transitions, experimental Chromium isolation checks, build-configuration checks, and universal code signing. Windows builds and releases are unchanged.
