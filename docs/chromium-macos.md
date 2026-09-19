# Chromium embedding investigation

Date: 2026-09-15. Status: development-only Chromium experiment. Normal tester builds ship WebKit only and do not expose engine selection.

**Direction:** a dynamically linked Qt WebEngine adapter inside the existing SwiftUI/AppKit shell. It exposes the notification presenter that stock CEF lacks, plus native audio mute and renderer IDs. Do not switch existing accounts until media support and production integration pass qualification. Chromium embedding is feasible; full provider parity is not yet established.

## Evidence

| Requirement | CEF 152 prototype | Qt WebEngine 6.11.2 prototype |
| --- | --- | --- |
| AppKit-owned window and embedded NSView | Passed | Passed, including compiled Swift/C++ bridge |
| Independent account storage | Separate request contexts; cookies/localStorage passed | Separate profiles; cookies/localStorage passed |
| Engine audio mute | `SetAudioMuted` state passed | `setAudioMuted` state and account isolation passed |
| Page notifications | API present; no native payload capture established | Native presenter captured title, body, origin and account |
| Service-worker notifications | API present; no native payload capture established | Native presenter captured worker notification; worker click callback passed |
| Page notification click callback | Not tested | Passed |
| Account renderer resources | Task manager returned CPU and memory for both browser IDs | Distinct renderer PIDs matched nonzero OS memory readings |
| Delayed download acceptance | Not tested | Passed after asynchronous delay; exact 64 KiB payload |
| Native zoom | Not tested | Independent 125% / 100% values passed |
| Teardown | Sample exited after closing embedded views | Swift adapter closed both sessions without crash |

These are localhost fixtures with disposable profiles, not signed-in provider tests. Mute assertions inspect engine state; they do not measure physical audio output or validate calls. Worker notifications were generated locally with `showNotification`; remote push transport and OS banner delivery were not tested. The shell now routes native notification tokens through the activity feed and macOS notification click handler, but interactive OS delivery remains unverified. Renderer PID attribution is not complete accounting for service workers, cross-site frames, GPU and shared network processes. Those must remain explicitly shared/unattributed until ownership can be established.

The Qt test uses `AA_PluginApplication`, an AppKit-owned `NSWindow`, and `QWindow::fromWinId` to parent the browser inside an `NSView`. AppKit runs its own event loop; no polling timer drives Qt. The compiled bridge is C++/Objective-C++ with a C ABI consumed by Swift. Python serves localhost fixtures and supervises tests; the native test app does not embed Python.

The universal bridge and bundled Qt frameworks contain arm64 and x86_64 slices. Runtime validation was on Apple silicon. The Swift fixture executable is built for the host architecture. The deployed test bundle is approximately 604 MiB uncompressed, including both Qt architectures. This is a prototype footprint, not an optimized release size. `codesign --verify --deep --strict` passed with a disposable ad-hoc signature. Developer ID signing, hardened runtime and notarization are not established by that test.

## Why Qt over stock CEF

CEF embeds cleanly in AppKit and has useful browser task APIs. Its current public surface did not provide the native notification payload/presentation hook needed by Relay. Choosing it would require investigating and maintaining a Chromium/CEF patch, or accepting another incomplete JavaScript notification bridge. The tested CEF build was `152.0.6+g708dc14+chromium-152.0.7977.83` (arm64).

Qt provides [`setNotificationPresenter`](https://doc.qt.io/qt-6/qwebengineprofile.html#setNotificationPresenter), and [`QWebEnginePage`](https://doc.qt.io/qt-6/qwebenginepage.html) exposes audio mute, render-process IDs and lifecycle state. The probes exercised these APIs rather than relying on their existence alone. Qt's [notification example](https://doc.qt.io/qt-6/qtwebengine-webenginewidgets-notifications-example.html) describes native presentation and event routing.

An Electron shell rewrite was not pursued: preserving Relay's native shell is a requirement. No claim is made that an unsupported Electron child-view integration was evaluated.

## Media and maintenance gates

The stock Qt SDK reports `QT_FEATURE_webengine_proprietary_codecs = -1`. The compiled fixture returned empty `canPlayType` results for H.264 and AAC, and `probably` for VP9. This prevents calling the stock package a suitable default for all Relay services.

Qt documents a separate build option for proprietary codecs and does not ship Widevine. A suitable codec build and a supported Widevine installation/distribution path need qualification before switching music accounts. A successful capability query alone will not establish Spotify/YouTube Music playback. See [Qt's codec and DRM support](https://doc.qt.io/qt-6/qtwebengine-features.html).

The runtime reported Chromium **140.0.7339.225** with security patches through **151.0.7922.71**; its reduced UA reported Chrome 140. Qt backports security fixes and exposes both versions; the bridge logs them at startup. A production build must pin and track that security patch level, rather than assuming either that the UA proves an unpatched engine or that installing Qt means ongoing automatic Chromium updates. See [Qt's Chromium maintenance policy](https://doc.qt.io/qt-6/qtwebengine-overview.html).

The app must bundle Qt frameworks, plugins, resources and its Chromium helper, then sign nested components with the appropriate entitlements. The test uses `macdeployqt` and ad-hoc signing only. Production packaging also needs Qt/Chromium/FFmpeg notices and a compliant Qt distribution arrangement. See [deployment](https://doc.qt.io/qt-6/qtwebengine-deploying.html) and [Qt WebEngine licensing](https://doc.qt.io/qt-6/qtwebengine-licensing.html).

## Integration sequence

1. Add a browser facade to `BrowserSession`, keeping navigation, caption, media and download UI in SwiftUI. Replace direct UI `WKWebView` access with facade methods.
2. Persist the backend per account. Existing records remain WebKit. Chromium gets a separate UUID-based profile directory; switching requires signing in again. Do not copy WebKit cookies/databases or erase existing profiles.
3. Route native notification objects through Relay's existing Quiet/account settings, activity feed and macOS notification delegate, retaining native click/close routing. Handle persistent site permission revocation when settings change.
4. Wire native mute, lifecycle state, uploads/dialogs, popups, downloads and crash recovery. The prototype includes bridge commands, but these are not wired to Relay's normal shell yet.
5. Sample renderer resources off the main thread, handle PID reuse and changing page processes, and display shared engine costs separately. The shell sampler reads raw cumulative ticks on a background task and converts them using the Mach timebase, with PID-reuse checks. Main/page renderer ownership is available; worker and cross-site frame ownership remains incomplete.
6. Qualify media codecs/DRM, WhatsApp reconnects, Google authentication, uploads, interrupted downloads, calls, sleep/wake, Settings responsiveness and teardown. Test Intel and Apple silicon, and the minimum supported macOS version.
7. Complete signed packaging, notices, update-feed configuration and notarization before distribution.

The native bridge lives under `macos/ChromiumBridge`; the Swift adapter now lives in `macos/Sources/RelayMac/ChromiumSession.swift`. The opt-in preview wires it through `BrowserSession` into the existing shell. It is not a fully qualified replacement: native dialog styling, complete resource accounting, remote push delivery, notification lifecycle details and real-provider flows remain work. The default build does not bundle or initialize Qt.

## Reproduce the Qt bridge checks

From the repository root, install isolated build tools and the official SDK into ignored `.build` directories:

```sh
python3 -m pip install --target macos/.build/qt-sdk-tools aqtinstall==3.3.0
python3 -m pip install --target macos/.build/cef-tools cmake==4.4.3 ninja==1.13.2
PYTHONPATH=macos/.build/qt-sdk-tools python3 -m aqt install-qt mac desktop 6.11.2 clang_64 \
  -O macos/.build/qt-sdk -m qtwebengine qtwebchannel qtpositioning qtserialport qttasktree
bash scripts/Test-macOS-chromium.sh
```

Run in a logged-in macOS desktop session. The script builds the universal native bridge, compiles the Swift test host, bundles Qt into an ignored test app and launches disposable localhost fixtures with a 35-second watchdog. `RELAY_QT_SDK`, `RELAY_CMAKE` and `RELAY_NINJA` can select existing SDK/tool paths. Logs are written to `macos/.build/chromium-check/output.txt`. No Relay settings or existing website profiles are read. Test-only keychain flags stay in the fixture runner; Chromium's sandbox is not disabled. This investigation setup uses pinned package versions, not a completed production dependency lockfile.

The earlier Python API probe is retained at `macos/QtProbe/probe.py`. With isolated `PySide6==6.11.2` and `pyobjc-framework-Cocoa==12.2.2` installed, its `--native --no-pump` mode validates the event-loop/embedding approach independently. The compiled bridge test above is the stronger integration check.

The CEF preparation and runner are retained under `macos/CEFProbe`; their pinned upstream sample is altered only inside the ignored investigation SDK. Its test-only ad-hoc signature produced a validation-category warning, so it is not a release-signing precedent.

## Integrated shell preview

```sh
RELAY_EXPERIMENTAL_CHROMIUM=1 RELAY_UNIVERSAL=1 bash scripts/Build-macOS.sh
# Quit Relay before rebuilding or opening the updated app.
open dist/macos/Relay.app
```

The preview uses the existing local signing identity, with explicit Qt helper entitlements. Qt remains dynamically linked. This is a local development build, not a notarized release. All testing builds replace the same `dist/macos/Relay.app`; quit Relay before rebuilding. The experimental Chromium flag controls bundled engines, not the output location. It cannot be combined with distribution mode or an update feed, and experimental bundles cannot be packaged as tester updates.

In an explicitly experimental development build, choose **Browser engine → Chromium Experimental** in an account's rail or Settings menu. Existing accounts default to WebKit, and an account UUID remains unchanged when switching. Each engine retains separate website storage; Chromium requires a separate sign-in. Switching is blocked while that account has active or resumable downloads. Normal builds automatically use the existing WebKit profile without deleting either profile or changing the saved experimental preference. Explicit Delete saved data now erases both engine profiles for the removed UUID.

The shared shell routes navigation, zoom, mute, unread detection, media controls, authentication popups and downloads to the selected engine. Chromium downloads use the existing staging-file/safe-replacement flow. Native notification tokens are retained for click-through from activity entries and macOS banners. Notification preference changes reset cached Chromium notification permissions; Quiet suppresses desktop delivery while retaining activity. Renderer resource sampling runs off the main thread and labels unowned processes separately. No total is claimed to be complete per-account resource usage.

Validation:

```sh
bash scripts/Test-macOS.sh
bash scripts/Test-macOS-browser.sh
bash scripts/Test-macOS-chromium.sh
RELAY_TEST_APP="$PWD/dist/macos/Relay.app" bash scripts/Test-macOS-shell.sh --chromium
```

The Chromium fixture now uses Relay's actual `BrowserSession` and `DownloadCenter`. The shell check uses ephemeral Chromium profiles and local HTML; it exercises four service/Settings cycles, layout changes, mute settings and account restoration/removal without reading or saving real settings. Settings responsiveness passed. Provider authentication, DRM/calls, OS notification delivery and Chromium interrupted-download resume still need qualification.

## Desktop identification

Chromium profiles retain the generated Mac/Chromium version tokens, omit the Qt browser token, and explicitly advertise non-mobile/Desktop client hints. The embedded view is sized from its AppKit host before loading and synchronized when attached. Fixtures verify both JavaScript and HTTP user agents, `Sec-CH-UA-Mobile: ?0`, and viewport width at each zoom level. WebKit Spotify accounts now use the desktop Safari compatibility identifier already used by WhatsApp. These changes affect browser identification and layout; they do not supply Chromium codecs or Widevine.


Calendar Google sign-in has been reported blocked with “This browser or app may not be secure” in Chromium Preview. Its authentication popup retains the same Chromium account profile, but this does not establish provider support. Google documents rejecting embedded-browser sign-in; neither Apple notarization nor external-browser login grants the embedded profile a session. Calendar Chromium sign-in remains unqualified. See [Calendar compatibility notes](macos.md#calendar-browser-compatibility).
