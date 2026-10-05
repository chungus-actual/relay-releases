# Development

## Local

- SDK: `global.json`; project-local `.tools/dotnet` supported.
- Launch: [Launch.cmd](../Launch.cmd).
- Output: `dist/dev`; bundled runtime; normal settings/sign-ins.
- Rebuild: quit the running copy first.
- Iterations: no installer, version bump, or release required.

```powershell
.\Launch.cmd -SmokeTest
```

- Test output: `dist/dev-smoke`.
- Test profiles: fresh `.test-data` folders.
- Fixtures: intercepted pages and generated downloads; no account sign-in.
- Results/screenshots: `artifacts`.

## Repository layout

- `windows/Sources/Relay/`: WPF shell and Windows application code.
- `windows/Tests/RelayChecks/`: Windows smoke checks, fixtures, and memory soak harness.
- `windows/app.manifest`: Windows application manifest.
- `macos/Sources/RelayMac/` and `macos/Tests/`: macOS application and checks.
- `Assets/` and `services.json`: shared artwork and service definitions.
- `scripts/`, `installer/`, and `docs/`: build/test tooling, installer, and documentation.
- `Relay.csproj`: Windows build entry point and default version shared by both platforms.
- `Launch.cmd`: rebuild and launch the local Windows app from the repository root.
- `bin/`, `obj/`, `.tools/`, `.test-data/`, `artifacts/`, and `dist/`: ignored local build, test, and distribution output.

## Checks

Run `bash scripts/Test-macOS-terminal.sh` for real PTY input/output, native keyboard delivery, resize and Ctrl+C, tabs and nested splits, rename/focus retention, account isolation, view reload/pop-out/dock retention, navigation restrictions, output bounds, restart, and process cleanup. It uses temporary shell homes and disposable WebKit storage; dark/light terminal previews and results are under `macos/.build/checks` when redirected there. macOS CI runs this suite. Terminal assets are shared directly with Windows; the small C PTY bridge is built by SwiftPM and linked into standalone browser checks.


Run `python scripts/Test-platform-parity.py` on either platform to compare the embedded Messenger layout/unread, Gmail unread, and media scripts. Both CI workflows run it; it supplements the existing Swift script comparisons and native browser suites. See [platform parity](platform-parity.md) for the latest local validation and engine differences.

Shell scripts use LF line endings on both platforms. On macOS, run `bash scripts/Test-macOS-shell.sh` after building to check settings changes and retained sessions; macOS CI runs this against its development app. Windows can run the portable Python checks, but native Mac checks require the macOS toolchain and frameworks.

| Area | Coverage |
| --- | --- |
| Accounts | Original/extra account naming, profile retention, duplicate names, isolation, persistence |
| Audio | Independent accounts, popups, reconnect, crash recovery, real muted-audio detection, background playback controls |
| Updates | Release selection/origin, checksum/size rejection, portable replacement and rollback, CI installer handoff |
| Downloads | Two accounts, saved bytes, completed-handle release, drawer, history clearing |
| Recovery | Deliberate fixture renderer/browser crashes, retry cap, disconnect cancellation |
| Workspace | One to four panes, all arrangements, bounded divider drag, persistence, stale focus, duplicate close, unload cleanup, retained documents, visible-pane suspension guard |
| YouTube | Separate profile/origin routing, media bridge installation, player fallback, pause/next, cleared controls, video title badge suppression |
| Shell | Minimum sizing, full account names, navigation overflow, native chrome, themes, menus, horizontal/vertical rail layout and drag previews |
| Unread | Messenger-specific counts, unread markers, unrelated Facebook totals, per-account dismissal, restored hidden shortcuts |
| Resources | Private resident RAM, CPU normalization/sustained thresholds, memory scales, PID churn, process scope, top consumers, sampling lifecycle |
| Services | Unread parsing, origin boundaries, storage isolation, rapid switching, disconnect/reconnect |
| Background | Suspension, media/download guards, startup registration against an isolated store |
| Notifications | Document notifications, capture, suppression; service-worker/push behavior remains unverified |
| Bug reports | Bounded diagnostic events, private-data exclusions, opt-in PNG capture/removal, frozen retries, intake receipts/deduplication; `python -m unittest discover -s reporting -v` |
| Companions | Three species, fitted wardrobe geometry, grooming/expiry/replacement, per-companion outfit retention, native outfit menu, reduced motion, timers, and dark/light pose sheets |
| Messenger | Full-width/fragmented headers, nested pane height and resize, CSP, style changes, route restoration; synthetic layouts |
| Google auth | Gmail/Calendar popup profile and cookie sharing, Google-to-YouTube session redirects in popups and the main view with link capture off, persistent-cookie reconnect, app-route return, landing-page retry, compose isolation; real phone/passkey authentication remains a manual check |

## Memory soak

```powershell
powershell -File scripts/Soak.ps1 -Seconds 600
```

- Synthetic switching, reconnects, and popups.
- Memory/process counts and retired-control collection: `artifacts/memory-soak`.
- Forced collections: test boundaries only.
- Previous result: [0.4.2 report](memory-soak-2026-09-12.md).
- Real signed-in workloads remain a separate check.

## Packages

```powershell
powershell -File scripts/Build.ps1 -SmokeTest -Installer
```

- Outputs: installer, portable ZIP, SHA256 manifest in `dist`.
- Dependencies: locked; build caches stay under `.tools`.
- Inno Setup: checksum-pinned portable compiler.
- WebView2 bootstrapper: valid Microsoft signature required.
- `-Package`: portable ZIP only.

## Releases

Starting with 0.6.3, both platforms publish under one immutable `v<VERSION>` release in `chungus-actual/relay-releases`.

1. Update `Relay.csproj` (the shared default version), `macos/Info.plist` marketing version and increasing build number, and `docs/releases/<version>.md`.
2. Run macOS model/script-parity checks, commit/push main, and push the matching annotated `v<VERSION>` tag. Windows CI builds and smoke-tests, verifies portable update/rollback and installer lifecycle, then publishes its three verified artifacts in the private source repository. Check the macOS CI run as well.
3. On the signing Mac, build with `RELAY_DISTRIBUTION=1 RELAY_UPDATES=1 bash scripts/Build-macOS.sh`, notarize/staple with `bash scripts/Notarize-macOS.sh`, and package with `python3 scripts/Package-macOS-update.py`. Mac releases from 0.6.8 target Apple silicon; the 0.6.7/build 23 archive remains universal. The default macOS asset URL uses the shared version tag.
4. Download the three Windows assets from the successful private tag release into a fresh directory. Write `SHA256SUMS-macos.txt` for the new `Relay-<BUILD>.zip` and unchanged signed `appcast.xml` in `dist/macos/updates`.
5. Run `python3 scripts/Publish-Release.py --version <version> --windows-dir <directory> --validate-only`, then repeat without `--validate-only`. The publisher verifies the private Windows release digests, the extracted Mac archive's signature/ticket/Gatekeeper, Sparkle signatures, historical feed URLs, and all uploaded bytes. It first exports the matching private release tag as a public source snapshot and immutable `source-v<VERSION>` tag, then creates the public release tag at that snapshot. GitHub’s automatic source archives therefore contain the release code. Public snapshots omit `AGENTS.md` and `.github/` repository automation and record original file hashes in `.release-source.json`; no private Git history or ignored local files are copied. It publishes all six binary/update assets together as Latest, then advances the signed Mac feed with a compare-and-swap update.

When hosted runners cannot start because of billing or spending limits, use locally built and tested native packages. Run the Windows build/smoke/package and portable updater checks locally; record the source commit, checks that passed, and checks that could not run. Installer lifecycle checks need an isolated Windows account or runner, so do not run them against an everyday profile or mark them as passed when skipped. Upload the installer, portable ZIP, and checksum manifest to a private transfer draft if needed, download them again, and compare all three SHA256 hashes. Publish the verified files under the matching immutable source tag in the private repository, then use the same signing-Mac publisher in step 5. This route does not require Actions artifact storage or a hosted CI run; Mac notarization, native signature checks, Sparkle verification, historical-feed preservation, and upload verification still apply. A `windows-candidate-<version>` draft is transfer staging, not a public release.

Published releases and tags are immutable. Failure after publication requires inspection; never replace published assets. The older Windows-only PowerShell release/mirror scripts reject versions 0.6.3 and above to prevent incomplete shared releases. Publication uses the operator's GitHub CLI login and the existing local signing keys; credentials are never embedded in either app. Windows continues to select its platform-specific installer/ZIP from Latest, and macOS continues to use the existing signed Sparkle feed.

Portable update/rollback and installer checks run on Windows CI. Local desktop-input tests require coordination; prefer the offscreen macOS native-drop regression. Preserve local profiles and certificates throughout release work.

Windows tag builds publish their three verified files directly from the build runner after smoke, updater, and installer checks succeed. Release publication does not depend on GitHub Actions artifact storage. Diagnostic uploads and development package uploads on both platforms are optional; quota failures remain visible in the job logs without failing otherwise successful validation.

## Assets

- App icons: `scripts/New-Icon.ps1`.
- Service icons: `Assets`; [credits](../THIRD-PARTY-NOTICES.md).

Memory API: [GetProcessMemoryInfo / EX2](https://learn.microsoft.com/en-us/windows/win32/api/psapi/ns-psapi-process_memory_counters_ex2). Older-system fallback remains approximate.


The productivity features share the version-1 setup fixture in `Assets/Fixtures/relay-setup-v1.json`. Windows `ProductivityChecks` and macOS `testProductivity` cover schema/URL validation, repeated imports, account reference mapping, snooze expiry, saved layouts, search, and download-history clearing/deduplication. Windows smoke checks also exercise retained browser documents, scoped bookmark navigation, real WebView2 notification suppression, settings filtering, palette command activation, and dark/light native snapshots. macOS shell/browser fixtures cover retained workspace sessions and restored download records; the snapshot runner includes both palette themes. Downloads use a separate atomic `downloads.json` beside platform settings and are never included in a setup export. Existing workflow filters include Windows, macOS, and Assets changes.

For focused native productivity checks, run `dist/dev-smoke/Relay.exe --productivity-check` after a local smoke publish. This uses fresh isolated profiles and exercises the same `CheckProductivity` checks included in the full smoke suite, plus bookmark manager actions, palette visibility, native launcher-click activation and external-window dismissal, layout text, and outfit category labeling. Results are in `artifacts/productivity-ui-checks.txt`; previews include saved-place empty/populated/narrow states, the editor, layout picker, and outfit control.


Windows suspension smoke coverage combines one real WebView2 request with deterministic API-boundary outcomes. Native refusal is allowed, but missing requests, API exceptions, mismatched Relay/native state, false sleeping indicators, lost unread counts or documents, and stale completions still fail. Every run covers decline/retry, acceptance, duplicate suppression, and reselection during an outstanding request. Inspect `artifacts/suspension-diagnostics.txt` for the actual runtime and native outcome; deterministic acceptance is not reported as proof that the engine suspended.

Run `Relay.exe --media-terminal-check` from a local build for focused isolated Windows media, terminal, and theme checks. Terminal coverage includes account-owned tabs, mixed-direction splits, real keyboard input and native focus, pane/tab/view close behavior, stale messages, process isolation, and teardown; `artifacts/terminal-tabs-split.png` shows the nested layout. The main smoke suite includes these checks. Results are in `artifacts/media-terminal-checks.txt` for a focused run; browser assertions, terminal previews, native titlebar captures, and six dropdown/menu theme combinations also go to `artifacts`. Both native browser suites execute `Assets/Fixtures/media-playback-checks.js`. On a Mac, run `bash scripts/Test-macOS-browser.sh --media` for media routing, floating ownership, popup/floating appearance, audio-state clearing, and notification replay regressions.
