# macOS port

The macOS app is a native SwiftUI shell with WKWebView, alongside the Windows WPF/WebView2 application. Both use the root `services.json` catalog. Both platforms share a version and release page; each retains its native build and package format.

Current release: [0.6.4 (macOS build 20)](https://github.com/chungus-actual/relay-releases/releases/tag/v0.6.4), published September 17, 2026 with the Windows installer and portable ZIP. It adds Discord, fixes the full-width Add account button and its feedback, and corrects Discord's SVG rendering. The universal Mac app is Developer ID signed and Apple-notarized, with a stapled ticket and successful Gatekeeper assessment. Apple accepted submission `74da752b-4fda-4acd-8d4b-78a8b4464fb1`. Windows latest and the signed Sparkle feed both advertise 0.6.4. Published asset bytes and checksums were verified; all seven historical feed enclosures and the existing signing keys were preserved. Release records are under `macos/.build/release-20/`, `macos/.build/publish-v0.6.4/`, and `macos/.build/notary-20/`.

[Windows tag CI](https://github.com/chungus-actual/relay/actions/runs/35284990342) passed the native smoke suite, including Discord routing and unread fixtures, updater replacement/rollback, and installer lifecycle checks. [macOS tag CI](https://github.com/chungus-actual/relay/actions/runs/35284990360) passed model/persistence, provider-script parity, button click checks in both themes, shared release validation, and the universal build. Local WebKit regressions, native shell checks, SVG rendering, signed-update installation/relaunch, and tampered-archive rejection passed. The user confirmed the Add account behavior and corrected Discord logo. Chromium runtime checks were not rerun for this release, and live provider sign-in/calls remain unqualified. Older publication-queue descriptions below are historical.

Build 14 keeps the selected native browser foremost and prevents an outgoing SwiftUI host from reclaiming browsers during a layout change. The offscreen native file-drop regression fails against the prior host at that ownership transition and passes with the correction. It verifies PNG/text bytes, both file pasteboard flavors, trusted events, cancellation, duplicate/background exclusion, and retained drafts. Model/script parity, WebKit browser regressions, isolated development Chromium checks, and universal signing passed. Published archive/feed signatures and downloaded checksums were verified. The user subsequently confirmed that 0.1.12 fixes the reported file-drop routing issue. Desktop-input automation was inconclusive during concurrent user interaction; the retained automated regression runs offscreen without pointer control. Windows runtime checks were not run on this Mac. Release records are under `macos/.build/release-14/`.

The title-bar Relay logo remains restored. Menu-bar icon visibility remains unresolved.

## Discord

Discord is available through **Settings → Add account** in the shared Windows/macOS catalog and opens `https://discord.com/channels/@me`. Each account uses Relay's existing separate browser profile, notification controls, and title-based unread detection. Discord-specific server/channel unread scanning is not implemented. CDN attachments follow the existing external-link/capture setting. Live Discord sign-in, calls, screen sharing, and push delivery still need verification on WebKit, WebView2, and the experimental Chromium engine; synthetic fixtures do not establish provider compatibility.

## Design target

The Settings **Add account** control is a full-size button with hover and pressed feedback. It opens a service-selection sheet with Cancel and Add account actions, matching the Windows button/editor flow while using a native Mac sheet. `bash scripts/Test-macOS-controls.sh` checks left, center, and right clicks in both themes using an offscreen window without moving the pointer or accessing saved accounts.

Maintain design parity with the Windows app. `MainWindow.xaml`, `Appearance.cs`, and the Windows shell/settings components are the visual reference. The custom SwiftUI shell now follows the Windows rail dimensions, caption, activity grid, cards, and appearance controls. Service icons are exported directly from `Assets/ServiceIcons.xaml` during the build. Native macOS window controls, system typography, and keyboard conventions remain. Embedded provider pages may differ between WebKit and WebView2.

## Build and run

Requires macOS 14 or newer and Xcode Command Line Tools with Swift 5.9 or newer. The build fetches pinned Sparkle 2.10.0 binaries and verifies their SHA-256 digest. An optional Chromium shell preview is available; see [the engine findings and preview instructions](chromium-macos.md).

```sh
bash scripts/Build-macOS.sh
open dist/macos/Relay.app
```

The script builds for the host architecture. It uses `RELAY_CODESIGN_IDENTITY` when provided, otherwise a valid certificate named `Relay Local Development`, otherwise ad-hoc signing with a warning. A requested certificate that fails to sign does not silently fall back to ad-hoc signing. This is not a notarized distribution build. Run the app bundle, rather than `swift run`, so the service catalog and bundle identity are available.

### Stable local signing and WebCrypto prompts

Ad-hoc signatures identify a particular executable hash. Rebuilding Relay changes that identity, so Keychain's previous “Always Allow” decision may no longer match. WebKit uses a Keychain master key for stored WebCrypto keys, which WhatsApp uses. A fixed bundle identifier alone does not solve this. See Apple's [code signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

Use the same signing certificate on subsequent builds:

```sh
RELAY_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" bash scripts/Build-macOS.sh
```

For local development without an Apple certificate, run the explicit one-time setup:

```sh
bash scripts/Setup-macOS-signing.sh
bash scripts/Build-macOS.sh
```

Setup creates a ten-year self-signed certificate in the login keychain, authorizes `/usr/bin/codesign` to use its private key, and adds user trust restricted to code signing. macOS may request authorization. It reuses an existing valid identity, refuses to replace an invalid existing certificate, and removes temporary key/export files on exit. It does not modify WebCrypto keys or website storage. Keep using the same certificate for future builds.

Alternatively, create a code-signing certificate using Keychain Access → Certificate Assistant → Create a Certificate. Name it `Relay Local Development`, choose Self Signed Root and Code Signing, and store it in the login keychain. If needed, set its Code Signing trust to Always Trust; leave unrelated trust settings unchanged. This certificate is for this Mac's development builds, not distribution. Keep the certificate and private key private and out of the repository. The build automatically selects it once `security find-identity -v -p codesigning` lists it as valid. Reuse it rather than regenerating it for every build.

Quit Relay before replacing its running bundle. After switching from ad-hoc signing to the certificate, Keychain may ask once more to authorize the new identity. Enter passwords only in the macOS dialog. Do not delete the WebCrypto master key, clear WhatsApp storage, or allow all applications access as a workaround: existing stored keys and sessions should be preserved. The stable self-signed certificate preserves the designated requirement, but does not eliminate prompts between builds: macOS assigns self-signed processes a per-executable `cdhash:` Keychain partition. Inspection of Relay’s existing WebCrypto item confirmed approvals for individual build hashes. “Always Allow” can therefore apply only to that build. Apple-issued development/distribution signing uses a stable team partition; self-signed builds still have this limitation. Do not loosen the item’s access list or reset the key to suppress it. See [Apple securityd partition selection](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/clientid.cpp).

```sh
bash scripts/Test-macOS.sh
bash scripts/Test-macOS-browser.sh
bash scripts/Test-macOS-shell.sh
```

`bash scripts/Test-macOS-browser.sh --file-drop` invokes WebKit's native drag callbacks with temporary PNG/text files in offscreen, nonactivating views. It checks readable file bytes, modern/legacy file pasteboards, service and host replacement, cancellation, duplicate/background delivery, and retained drafts. It does not move the pointer, post keyboard events, access real accounts, or send provider attachments. This regression also runs in the full browser suite; live Finder-to-provider uploads still need tester confirmation.

The first command checks model migration, account identity/order/visibility, loaded/background/notification preferences, keyboard cycling, drag ordering and payload validation, per-account zoom migration/persistence, routing/permission boundaries, bounded crash recovery, safe file replacement, unread parsing/dismissal, and parity with the Windows Messenger/media scripts. The second runs WebKit with synthetic pages, ephemeral cookie stores, and temporary files: native rail click/drag pointer sequences and drag item-provider round trips, separate-account cookies and page zoom, actual blob-download bytes, cancellation, browser history observation, background policy isolation, live title changes, Messenger DOM polling, activity bounds, account dismissal, media actions in main/popup pages, and cleanup. It does not access real accounts or test provider authentication. An optional `bash scripts/Test-macOS-browser.sh --profile-cleanup-check` creates a fresh persistent profile with a synthetic cookie, deletes only that profile, and verifies removal. Existing profiles are not modified. This check passes; no provider sign-in is involved. Run it in a logged-in macOS desktop session. The shell check launches the built app with in-memory fixture preferences and ephemeral pages, exercises repeated service/Settings transitions, layout and menu-bar changes, and checks that unchanged bindings publish no updates. A watchdog fails the run if the main thread stops responding. It never reads or saves real account settings.

Render the shell with unsigned-in fixture accounts, without reading or writing saved preferences:

```sh
dist/macos/Relay.app/Contents/MacOS/Relay --snapshot-directory artifacts/macos-shell
```

This produces eleven view snapshots: activity and settings, light/dark mode, a compact 720-point-wide window with a long hidden-account label, top tabs, the download drawer at wide/narrow sizes, and populated unread badges/activity in normal and compact layouts, and wide/narrow media controls. These render the app's content, excluding native window controls; they are visual inspection aids, not automated pixel comparisons against Windows.

## Available now

- Add multiple accounts for any catalog service, switch between them, and restore the account list and selection on launch.
- Rename, remove, unload, hide/show, and reorder accounts from Settings or the rail context menu. Drag shortcuts in the side rail/top tabs, or use the drag handles in Settings (including hidden accounts). Drop on the top/left half to insert before the target, or bottom/right half to insert after it. Padded icon-only drag previews, insertion markers, and animated spacing/reordering provide feedback; Reduce Motion disables these animations. Rail drags start through AppKit independently of button click tracking. Changes save before taking effect; reordering preserves the selected account and browser sessions. Renaming and hiding retain the same website profile.
- Windows-style activity service grid, original service icons, selected rail markers, and compact/normal/top-tab layouts.
- Persistent System/Dark/Light mode, Graphite/Ocean/Dune surfaces, and Mint/Sky/Iris/Rose/Amber accents using the Windows color values.
- Appearance and service settings cards, with Command-comma to open Settings.
- Per-account unread counts/dots in the rail and activity grid, plus a Dock badge aggregating known counts (or a dot when only uncounted activity is known).
- A recent-activity feed of unread summaries with per-account dismissal and Clear history. Opening an entry selects its account, including hidden shortcuts.
- Lazy browser creation with retained sessions when switching accounts.
- Separate persistent WebKit data stores keyed by saved account UUIDs.
- Back/Forward history buttons, home, reload, and navigation gestures, with current history availability reflected in the caption and Page menu.
- Services menu: Command-1 through Command-9 select visible shortcuts in their current order; Command-Option-left/right cycles them, skipping hidden accounts. Command-Shift-A opens Activity. Command-[ / Command-] navigate history and Command-R reloads.
- Caption media controls for loaded Spotify, YouTube Music, and Bandcamp accounts, including play/pause, previous/next, track/artist display, and click-to-open the account.
- Opt-in native unread-summary notifications, per-account notification preferences, and click-through to the originating account.
- Menu-bar access to accounts, Activity, Downloads, Settings, and Quit; closing the main window retains loaded sessions.
- An explicit Open Relay at login toggle using macOS Service Management, with pending-approval/error status.
- Per-account Keep awake in background preference; disabling it allows WebKit to suspend idle detached pages.
- Per-account page zoom from 50–200%, with a caption slider, shortcut-menu presets, and Page menu commands: Command-equals to zoom in, Command-minus to zoom out, Command-zero for actual size.
- HTTPS browsing, external clicked links in the default browser, and account-sharing authentication popups.
- Camera/microphone requests from service pages use WebKit’s site permission prompt and macOS device authorization. Authentication and unrelated origins cannot inherit a service’s capture permission.
- Native file/directory upload pickers and JavaScript alert, confirm, and prompt dialogs labeled with the requesting origin.
- A shared account-labeled download drawer with progress, cancel, Open, Show in Finder, and Clear. Transfers use their originating WebKit session; blob attachments and download responses are supported.
- Load errors and bounded recovery when the main web content process terminates (1, 3, then 10 seconds; repeated failures require manual reload). Navigation or unloading cancels pending recovery. A 120-second gap between failures resets the retry budget. Popup termination prompts reopening the popup.

Settings are stored at `~/Library/Application Support/Relay/macOS/settings.json`. Cookies and website storage are managed by WebKit's persistent data stores. These are separate website sessions, not OS security boundaries or a Relay-encrypted vault. Windows profiles are not imported. A malformed settings file is preserved and saving is disabled for that launch.

The first launch of this milestone fills in unloaded catalog accounts while retaining existing account UUIDs. New catalog accounts start unloaded. Selecting/loading an account now persists its loaded state, and subsequent launches restore explicitly loaded accounts, including hidden shortcuts. Unload persists the disabled state. Existing accounts without this field retain their old selected-account startup behavior until loaded again. Removed accounts do not reappear on restart. Removal now records the account in Settings → Removed accounts. Restore reuses its original WebKit profile UUID, preferences, shortcut visibility, and prior list position, and leaves it unloaded. A conflicting name gets a “(restored)” suffix. Adding a new account still creates a separate profile. Accounts removed before this feature have no retained account metadata and are not automatically recovered; their website data remains untouched. Removed accounts also have a confirmed Delete saved data action. It removes that profile’s cookies and website storage through WebKit, then clears its metadata. A pending-deletion marker survives interruption and blocks Restore until deletion is retried successfully. Active profiles cannot be erased. This does not delete the provider account or Relay’s shared WebCrypto master key.

Downloads prompt for a destination. Transfer bytes go into a private temporary folder beside that destination, then move into place only after success; an approved replacement leaves the old file intact while transferring. Failed/canceled transfers clean up their partial files. If moving completed bytes fails, Show in Finder exposes the staged file for recovery. Clearing history does not delete saved files. Download history is memory-only, capped at 50 finished transfers. Interrupted transfers with WebKit resume data can resume during the current run; manual pause and restoration after app exit are not implemented. Finish or cancel active transfers before unloading/removing the account or quitting Relay. An abrupt exit can leave a hidden `.relay-download-*` staging folder beside the chosen destination.

WebKit's identifier-based persistent profiles require macOS 14: [WebKit profile API](https://webkit.org/blog/14423/building-profiles-with-new-webkit-api/).

Zoom settings save before updating the page and survive restart, rename, and unload/reload. Existing accounts default to 100%. The caption slider uses 5% steps and keyboard commands use 10% steps, matching the Windows range. Zoom affects the account’s main page; authentication popups retain their own default size. These controls resize website content, not the Relay shell.

## Unread and activity behavior

Loaded accounts observe conventional page-title formats such as `(3) WhatsApp`, `[2] Telegram`, and `Inbox (4)`. Music-service titles are excluded. Messenger uses the Windows DOM extraction script in WebKit's isolated client world: Messenger-specific totals take priority, unrelated Facebook counts are ignored, and virtualized unread rows produce a dot instead of a fabricated total. Only loaded Messenger sessions poll, every three seconds; unload cancels observers/polling and ignores stale asynchronous readings.

Activity records new/increased unread signals rather than message contents. It is bounded to 60 in-memory summaries; no conversation text or page titles are saved. Identical readings and simple reloads do not keep adding entries. Clear removes history without changing badges. Dismiss clears that account's entries and hides the same unread signal until a different unread signal or explicit zero is observed, including across transient missing titles and unload/reload within the current run. It does not mark conversations read at the provider. Hidden shortcuts still contribute if their account remains loaded. Removal deletes that account's activity; unload hides its badge while retaining history/dismissal state.

This is not a complete inbox or native notification capture. A site that does not expose a supported count/marker may have unread messages without a Relay badge; equal-count changes are not reliable evidence of a new message. Browser fixtures validate detection behavior; real-provider unread behavior and localized Messenger labels need further testing.

## Media, notifications, and background behavior

Media controls reuse the Windows bridge, checked verbatim by tests. The bridge installs at document start on music services and reads Media Session metadata/actions, media elements, and provider controls. Polling prioritizes playing accounts, retains the prior account when possible, and stops when music accounts are unloaded. Playback selection includes owned account popups; navigation and closing a popup invalidate stale targets. Native player actions and account isolation pass synthetic fixtures; protected streaming, provider selector changes, and real autoplay restrictions still need live testing.

Notifications default off. Enable Show notifications in Settings to request system permission. Each account's menu can disable its notifications. The viewed account stays quiet while Relay is active. Summaries replace the previous notification for that account; unload/removal or disabling notifications clears delivered/pending entries. Clicking a notification opens its account. Unread summaries omit message contents; forwarded page notifications can contain website-provided titles and message bodies. See the compatibility limitations below. OS notification delivery and click-through need interactive validation.

Loaded accounts default to staying awake, except Google Keep; saved choices take precedence. Turn off Keep awake in background in an account menu to use WebKit's public inactive scheduling policy. WebKit suspends idle pages detached from windows and excludes pages playing media or loading. Relay skips its background unread polls for sleeping accounts and only polls media there when playback is active. Returning to the page makes it active again. This uses WebKit scheduling rather than process termination; it is not an immediate CPU/RAM guarantee. Capture/call and real-provider sleep behavior need interactive testing.

The menu-bar item can be disabled in General settings. Closing the main window keeps Relay running; Quit exits. Login startup changes only when the user toggles it, and its status comes from macOS rather than a saved checkbox. Pending approval has a direct Login Items button. Automated checks do not register login startup or grant notification/device permissions.

## Universal build and CI

```sh
RELAY_UNIVERSAL=1 bash scripts/Build-macOS.sh
```

This builds arm64 and x86_64 slices targeting macOS 14 and includes the shared Windows Relay artwork as a native `.icns`. The default build still targets the host architecture. `.github/workflows/macos.yml` runs model checks and a universal development build, verifies both slices/signature, and packages a zipped app artifact. It uses ad-hoc signing without signing secrets and does not publish a release. GUI/WebKit integration checks remain local. The workflow is prepared but has not been run on GitHub.

## Camera and microphone

Camera and microphone usage descriptions are included in the app bundle. Relay asks WebKit to prompt for requests from the account’s service origins, including owned service popups; it never automatically grants device access. macOS may also request permission for Relay itself. Requests from authentication hosts, unrelated origins, non-HTTPS pages, and closed/unowned sessions are denied. Embedded third-party calling origins are not yet supported.

If access was denied at the OS level, review Relay under System Settings → Privacy & Security → Camera or Microphone, then retry the call. Site permission and OS permission are separate. Permission routing and bundle metadata are tested without activating either device. Real calls, provider support in WebKit, and permission recovery still require interactive testing; this does not establish that every service supports calls in Relay.

## Remaining work

The current cross-platform audit and validation limits are in [platform parity](platform-parity.md). The milestones below describe the initial port; later sections record completed updates, signing and browser changes.

This is an initial port, not feature parity. Provider sign-in, popup flows, persistence of real sessions, and streaming/DRM compatibility need interactive testing. WhatsApp, Spotify, and Gmail receive a desktop Safari compatibility suffix using the installed Safari version (falling back to the OS's Safari baseline). Other services retain the default WebKit identifier. This changes browser detection, not engine capabilities.

Next milestones:

0. Continue visual comparisons against a running Windows build. The main shell, unread/activity UI, and download drawer are ported; media controls, summary notifications, and menu-bar utilities are implemented; shell resource readings and page notification forwarding are implemented; per-service resources and full website-notification capture remain.
1. Verify real provider sign-in, upload/directory selection, JavaScript dialogs, authentication popups, network attachments, persistent-profile reconnects, and local-storage isolation. Synthetic blob downloads and ephemeral cookie isolation pass; those do not establish real-provider compatibility.
2. Validate enabled/live preferences and add native website-notification capture. Validate provider unread signals and localization. Validate interrupted-download resume and profile cleanup with real providers. Download pause remains open.
3. Validate media/Web Audio mute with providers; full engine audio mute and measured per-service/background resources remain.
4. Validate menu-bar/login behavior and run macOS CI. Add signed updates and distribution signing/notarization; local certificate signing, app icons, and universal builds are implemented.

The Windows security and release documentation describes the Windows implementation; its WebView2/DPAPI observations and updater guarantees do not apply to this prototype.


## Notification, audio, and resource controls

The rail has a persistent Quiet toggle. It suppresses desktop delivery without stopping the activity feed. Global and per-account notification switches still apply. Loaded service pages can forward `new Notification(title, {body})` through Relay, with account/origin checks and a one-per-second cap per account. Messages can include website-provided contents. Clicking the desktop notification opens its account. Permission comes from Relay's explicit Settings opt-in; authentication pages and unrelated frames are excluded. Existing unread summaries remain available. This is a page compatibility bridge, not WebKit-native capture: worker/service-worker notifications, notification actions, page click callbacks, and full Notification API semantics are not implemented. Real-provider compatibility and macOS delivery need interactive validation.

The caption and account context menu now offer **Mute media audio**. It persists per account and applies to main pages, frames, and owned popups. Document-start scripts mute HTML audio/video and gate Web Audio destination connections; unmuting restores the page's HTML media mute preference. No microphone capture settings are changed. Synthetic checks cover account isolation, page attempts to unmute, new popup inheritance, Web Audio gates, and restoring output. This is not a browser-engine-wide mute guarantee: worker-generated audio, unsupported audio paths, or pages bypassing the bridge may escape it. Live calls and DRM providers still need verification.

The rail pulse opens measured **Relay shell** CPU and resident RAM, sampled every two seconds with public Mach/getrusage APIs and monotonic time. CPU uses 100% per core. WebKit's separate service/network/GPU processes are explicitly excluded; per-service attribution and heavy-consumer rankings remain open. No process totals are presented as per-account estimates.

## Rail account menus

Right-click empty space in the rail or top-tab strip to open a hidden account and restore its shortcut, or add an account. Services → Hidden accounts provides the same restore action from the menu bar. Each service context menu also offers Add another account; Settings account menus include the same action and media-mute control.


## Interrupted downloads

Downloads with WebKit-provided resume data show Resume and Cancel. Resume uses the originating account's web view and original staging destination; completed bytes are committed through the existing safe-replacement path. Clear preserves resumable transfers. Cancel discards their staging data, and account unload/removal waits until the transfer is completed or canceled. Resume state stays in memory and does not survive app exit. Servers and download types that do not provide resume data still show Failed.

`bash scripts/Test-macOS-resume.sh` runs a localhost-only HTTP fixture that deliberately drops a transfer, then serves its Range request. It checks exact completed bytes, destination preservation before completion, duplicate Resume handling, cancellation while interrupted or resuming, staging cleanup, and Clear behavior. No provider account or external network is used.

## Updates

Sparkle 2.10.0 is bundled and signed with the app. Self-signed builds use the existing `Relay Local Development` certificate. Sparkle update signatures use a separate Ed25519 key in the login Keychain, under account `com.chungus-actual.relay.updates`. Preserve both identities across releases. Back up the update key securely using Sparkle's `generate_keys --account com.chungus-actual.relay.updates -x` tool; never commit the exported private key.

Hosting uses the existing public `chungus-actual/relay-releases` repository, as configured in `macos/Updates.json`. Set `RELAY_UPDATES=1` to embed its dedicated feed at `https://raw.githubusercontent.com/chungus-actual/relay-releases/main/macos/appcast.xml`. `RELAY_UPDATE_FEED_URL` can override that location. The build reads the public key from Keychain; CI can supply it through `RELAY_UPDATE_PUBLIC_KEY`. Configured builds require signed feeds and verification before archive extraction. Automatic installation is disabled. Builds without a feed leave Check for Updates disabled.

The marketing version defaults to `Relay.csproj`, shared with Windows. `RELAY_VERSION` can override it for a development build. Set an increasing positive integer `RELAY_BUILD_NUMBER` for each update, enable distribution signing/updates, and use the universal build option. Then run:

```sh
python3 scripts/Package-macOS-update.py
```

This packages the canonical `dist/macos/Relay.app` and stages archives plus `appcast.xml` under `dist/macos/updates`. It checks the app signature, rejects ad-hoc builds and mismatched update keys, refuses duplicate/regressing build numbers in the local feed, and uses Sparkle's official tool to sign the feed and full archives. Preserve this staging directory between releases. Delta updates are disabled for now. Upload the generated files unchanged; the script does not publish anything. Private GitHub release assets require a separate authentication design and are not directly usable as a public feed.

Starting with 0.6.3, default archive URLs use the shared tag `v<VERSION>` in `relay-releases`. Publish together with the verified Windows installer/ZIP and both checksum manifests using `scripts/Publish-Release.py`; only the complete shared release becomes Latest. The script verifies public archive availability before committing the signed feed unchanged to `macos/appcast.xml`. Historical `macos-v<VERSION>-<BUILD>` archives and their feed URLs remain immutable. See [the shared release procedure](development.md#releases).

The macOS preview feed is live in `relay-releases`; the initial baseline is `macos-v0.1.0-2` and the first update is `macos-v0.1.1-3` (scrolling media titles). Preview releases do not replace Windows latest. `python3 scripts/Test-macOS-update.py` exercises the real Sparkle installer using a temporary self-signed app, a signed localhost feed, and a signed full archive. It verifies replacement, code signing, and relaunch into version 2 without opening Relay profiles. Run it again with `--tamper` to verify an altered archive is rejected and version 1 remains installed. Both checks pass; a production HTTPS update of the full Relay app still needs verification after publishing. Developer ID signing is configured; the first notarization submission is pending (see below).

Gmail WebKit sessions bypass the local document cache on initial/home loads and revalidate on Reload. This prevents a cached unsupported-browser response from surviving the Safari identity correction; cookies, local storage, IndexedDB and stored accounts are preserved. The opt-in `--gmail-diagnostics` launch flag logs browser identity, origin and warning presence before and after a revalidated reload, without logging message contents.

### Gmail unread parity

Gmail reads the inbox navigation badge on both platforms, including while another folder or a message is open. Both poll every three seconds while the service is live, accept grouped unread counts, suppress repeated activity for unchanged counts, and clear the badge at zero. The title is a fallback when navigation is unavailable. Detection does not inspect email content. The macOS browser fixtures cover count changes without title changes and clearing; the Windows smoke suite includes the equivalent fixture. Script equality is enforced by the macOS model checks and Windows source changes trigger that CI job. Windows runtime validation of this change is still pending on a Windows runner.

Gmail badge mode is per account: **New since launch** (default) tracks net unread increases above the first observed inbox count; **All unread** shows the full total. If the total falls below the baseline, the baseline follows it down, so later increases still register. Switching modes resets the baseline and clears that account’s previous activity without notifying. Mode persists; the baseline lives for the app session. This is count-based detection, not message-level arrival tracking: an arrival and a read that cancel out between polls cannot be distinguished. macOS exposes the choice in the Gmail shortcut menu and Settings → Gmail → … → Gmail badge; Windows exposes it in the Gmail settings row.

### Developer ID distribution

The Developer ID Application identity is installed and signing has been verified. Apple notarization credentials are stored locally under Keychain profile `relay-notary`; no credentials are embedded in the repository or application.

Build with `RELAY_DISTRIBUTION=1 RELAY_UPDATES=1 RELAY_UNIVERSAL=1 RELAY_VERSION=<version> RELAY_BUILD_NUMBER=<increasing integer> bash scripts/Build-macOS.sh`. This requires a valid Developer ID Application identity (optionally selected with `RELAY_CODESIGN_IDENTITY`), adds hardened runtime and secure timestamps throughout the bundle, and grants the host camera/microphone entitlements. Local builds remain available without distribution mode.

After local browser checks, `bash scripts/Notarize-macOS.sh` submits the app archive to Apple using the stored profile, records the submission ID/results/log under `macos/.build/notary-<build>`, waits for acceptance, staples and validates the ticket, and checks Gatekeeper. This sends the signed app binary to Apple. Override the profile using `RELAY_NOTARY_PROFILE` if necessary. Only then run `python3 scripts/Package-macOS-update.py`; Developer ID packaging requires a valid stapled ticket and Gatekeeper acceptance. The existing Sparkle Ed25519 key remains unchanged through the signing transition.

Build 5 (0.1.3) has been Developer ID signed locally and submitted to Apple for notarization as `aec5f10e-a48c-4dbc-8bfe-a9cc04a93222`. Acceptance and stapling are pending; it is not yet published.

### Messenger activation

Build 6 (0.1.4) refreshes Messenger layout when its native view becomes visible. The shared provider script also responds to document visibility changes, notifying scrollable chat panes without changing their scroll offsets or reloading the document. Windows calls the same activation hook after restoring its WebView. The WebKit regression fixture detaches and reattaches the view three times and checks refresh delivery, scroll position, draft preservation, and document identity. Windows has the matching smoke fixture but has not been run here; live Messenger verification remains necessary.

Notarization staples a snapshot extracted from the submitted archive, so a newer local testing build can replace the canonical app while Apple scans. The canonical app is stapled only if its code hash still matches that submission. Build 6 is a local testing build and requires its own notarization before distribution.


Build 7 (0.1.5) replaces the activation hook's synthetic scroll events with a one-pixel native scroll, restored on the next animation frame. Build 6 did not resolve the live Messenger blank-message issue; scrolling manually made messages appear. Duplicate activation requests coalesce, hidden-page activation clears pending restoration, and restoration does not overwrite a newer scroll. The provider script is shared in behavior with Windows and checked for source parity. WebKit regressions verify native scroll events at the top, middle, and bottom, duplicate activation, document/draft retention, and preservation of a newer scroll. Full macOS model and WebKit browser checks passed. The Chromium integration suite also passed, but does not exercise this Messenger scroll regression. Windows smoke checks cannot run on this macOS host. Live Messenger confirmation is still required; fixture success does not establish that the provider's rendering defect is resolved. Build 7 is not yet notarized or published.


### Calendar browser compatibility

Every WebKit service now receives the installed desktop Safari version identifier by default, including new services and inherited popup configurations. There is no service allowlist. WebKit still generates the platform and engine tokens; Chromium and Windows WebView2 retain their own engine identifiers. Initial loads and explicit reloads revalidate cached responses without deleting account storage. A browser regression checks the main page and sign-in popup identifiers and shared account data store. Windows retains its native WebView2 browser identification; this adjustment is specific to WKWebView. Live Calendar warning removal and sign-in still require verification.

Google may reject sign-in in embedded browsers, including the Chromium Preview engine, with “This browser or app may not be secure.” A Relay popup shares its originating engine's profile; it is not a system-browser authentication handoff. Switching engines does not transfer Google sign-in cookies. Successful authentication in Safari or Chrome does not sign the embedded profile in. See [Google's supported-browser guidance](https://support.google.com/accounts/answer/7675428) and [embedded-framework sign-in policy](https://developers.googleblog.com/guidance-to-developers-affected-by-our-effort-to-block-less-secure-browsers-and-applications/). Apple notarization does not remove this provider restriction. Prefer the existing WebKit profile for Calendar if it is already signed in; use Calendar in a supported standalone browser if Google rejects a new embedded sign-in.


### Service-switch performance (build 8)

Build 8 (0.1.6) keeps loaded service views attached to a persistent native host and changes their visibility when selecting services or local pages. Previously, the SwiftUI service identity removed and reattached the browser on each switch. This aligns macOS with Windows' existing hidden-view host strategy. Both WebKit and Chromium use the new host; Chromium explicitly follows native hidden/unhidden notifications. Views still detach when their accounts unload or change engine. Layout changes such as switching between side and top tabs may rebuild the surrounding hierarchy. Background media polling respects hidden views even while they remain attached. Repeated updates do not reapply identical appearance or visibility state.

`bash scripts/Test-macOS-browser.sh --switch-performance` compares the old native detach/attach operation against retained hide/show with four disposable WebKit pages (1,000 styled rows per page). Each of four alternating runs discards four warmup switches and measures 40 switches. This isolates native hosting; it does not measure full SwiftUI click-to-display time, live-provider rendering, or physical display presentation. No signed-in profiles are used.

Measured on the development Apple-silicon Mac on September 16, 2026:

| Operation | Detach/attach (two runs) | Retained hide/show (two runs) |
| --- | --- | --- |
| Native switch median | 4.39 / 4.54 ms | 0.19 / 0.22 ms |
| Native switch p95 | 5.53 / 5.23 ms | 0.49 / 0.84 ms |
| Switch through two animation frames, median | 33.26 / 33.06 ms | 14.54 / 14.95 ms |
| Switch through two animation frames, p95 | 41.19 / 33.90 ms | 18.97 / 20.04 ms |

Atomic preferences saves with 12 disposable accounts measured 0.33 ms median and 0.44 ms p95 across 40 writes, so persistence semantics were retained. These measurements do not prove that every live blank-pane/black-flash report is resolved. Memory retention and real-provider behavior still need observation with the user's loaded account set. Windows runtime comparison cannot run on this host.

The WebKit regression suite covers retained window/viewport, visibility, duplicate updates, local-page transitions, resizing, unloading, and preservation of documents, drafts, and scroll positions. Universal WebKit browser identification and Calendar popup profile inheritance are also covered.


Build 8 validation: the arm64/x86_64 Developer ID signed bundle passed strict deep signature verification. Model/script parity checks, the full WebKit browser suite, Chromium integration checks (including retained-view page visibility and document identity), and live SwiftUI shell checks in both engines passed. These runs used disposable fixture accounts. Windows builds/runtime checks and live-provider visual verification were not run. Build 8 remains a local testing build, not a notarized or published release.


### Normal tester builds use WebKit only (build 9)

Build 9 (0.1.7) omits Qt/Chromium and the Browser engine menus. Accounts previously set to Chromium resume the persistent WebKit profile associated with their existing UUID. The stored experimental engine preference and both profile directories are preserved; cookies are not copied between engines. An account used only in Chromium may need to sign in to WebKit. Removed-account data deletion continues to cover both profile directories only when explicitly requested.

Chromium remains available for development through `RELAY_EXPERIMENTAL_CHROMIUM=1`, which stamps an explicit bundle opt-in. Its runtime and menus require both that opt-in and the bundled bridge. The old `RELAY_CHROMIUM=1` flag is rejected; experimental builds cannot enable distribution signing mode or Sparkle feeds, and the update packager rejects them. Normal build/release commands must omit the experimental flag. Windows continues to use WebView2.


Build 9 validation: model/script parity and build-configuration checks, the full WebKit browser suite (including repeated fallback to a disposable persistent WebKit profile with cookie retention), the normal live shell checks, and the separately opted-in Chromium development fixture passed. The universal Developer ID signed bundle passed signature verification and contains neither the Chromium bridge nor Qt frameworks. Bundle disk usage dropped from about 611 MiB (build 8) to 11 MiB. Existing user profiles and signing keys were not modified. Windows runtime checks were not run. Build 9 is not yet notarized or published.


Build 9 publication was authorized on September 16, 2026. Apple submission: `a78f9c62-d3c7-49f7-a03a-75fc1bc67fcc`. A detached one-shot worker at `macos/.build/notary-9/publish.py` waits up to 24 hours for acceptance, then validates/staples the submitted snapshot, packages and verifies the signed archive/feed, publishes `macos-v0.1.7-9`, and updates the feed using the prior GitHub file SHA. It preserves historical enclosure URLs/signatures and Windows latest. Inspect `publish-status.json` and `publish.log` in that directory before taking any further release action; do not submit the same build again or start a duplicate worker. Validation/network failures after acceptance stop publication for inspection. The release remains pending until the status phase is `published`.


### Menu-bar branding (build 10)

The macOS menu-bar extra now uses the same Relay “R” vector mark as the shell, rendered as an 18-point template image. macOS supplies its light/dark/selected foreground. The Dock icon already used Relay artwork; Windows already uses `Relay-tray.ico`. A rendered preview verified the R/dot geometry. Build 10 is 0.1.8. Build 9's publisher was stopped while awaiting Apple and marked superseded, so the logo correction can ship in the next immutable build; its submitted archive and profiles remain untouched.


Build 10 passed the universal signed build and live shell checks. It supersedes build 9 in the publication queue. Apple submission: `b73e5e6a-975d-4e5f-947d-5427b14f6907`. The active detached worker/status/log now live under `macos/.build/notary-10/`; use that status rather than the superseded build 9 worker. Publication remains gated on acceptance, stapling/Gatekeeper, signed-archive/feed verification, and unchanged historical feed/Windows latest metadata. `Notarize-macOS.sh --submit-only` can hand the submitted snapshot to this worker without launching a competing waiter.


Build 11 (0.1.9) retains the Relay logo in the macOS system menu bar and removes the duplicate mark from the window title bar. The Activity rail/top-tab button retains its chat-bubbles icon. Windows source also removes the title-bar mark and adjusts caption width accounting; its tray already uses the Relay logo. Windows runtime verification is unavailable on this host. Build 10's pending publisher was stopped before publication and will be superseded by build 11.


Build 11's universal signed build, model/configuration checks, and live shell checks passed. Normal and compact shell snapshots confirm the removed title-bar mark and retained Activity icon. Its active publication worker/status/log are under `macos/.build/notary-11/`; build 10 is superseded. Apple submission: `1f85b221-0baf-49f8-b45b-097642fa0e2a`. Publication still requires Apple acceptance and all archive/feed checks. The canonical testing app has been reopened as 0.1.9 (build 11).


Build 12 (0.1.10) restores the original title-bar Relay mark on macOS and in Windows source. The menu-bar icon remains unresolved: the user reports it is still invisible after expanding and quitting Hidden Bar, so off-screen placement was not a complete diagnosis. Menu-bar rendering code is unchanged in build 12 while that issue is deferred. Build 11's pending publication is superseded by build 12; submitted archives remain intact.


Build 12 passed the universal signed build and live shell checks; the compact service snapshot confirms the restored title-bar mark. Apple submission: `a20ece7e-1269-4f4d-a8a4-a13f5e970830`. Its active detached worker/status/log are under `macos/.build/notary-12/`, replacing the superseded build 11 worker. The canonical app has been reopened as 0.1.10 (build 12); publication remains gated on Apple acceptance and the archive/feed checks.
