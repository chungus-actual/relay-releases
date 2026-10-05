Corrects browser hosting during service and layout switches, addressing reports of file drops being lost in the macOS app.

- Keeps the selected browser above retained background browsers so native file drops reach the visible service.
- Prevents an outgoing browser host from reclaiming pages when switching between the sidebar and top tabs.
- Preserves loaded pages and drafts; no account reload or storage reset is required.

Validation: offscreen native WebKit PNG/text drops, multiple files, modern and legacy file pasteboards, service and host replacement, cancellation/retry, exact file bytes, trusted events, and duplicate/background exclusion. macOS model/script parity, the WebKit browser suite, isolated development Chromium checks, and universal signing passed. Live Finder uploads in Gmail, Google Chat, and Messenger still need tester confirmation. Windows runtime checks were not run on this Mac; Windows releases are unchanged.

Requires macOS 14 or later on Apple silicon or Intel. This preview is self-signed with the existing Relay Local Development certificate and is not notarized. Existing service profiles and WebCrypto keys are preserved. The title-bar Relay logo remains restored; menu-bar icon visibility remains under investigation.
