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

## Checks

Run `python scripts/Test-platform-parity.py` on either platform to compare the embedded Messenger layout/unread, Gmail unread, and media scripts. Both CI workflows run it; it supplements the existing Swift script comparisons and native browser suites. See [platform parity](platform-parity.md) for the latest local validation and engine differences.

| Area | Coverage |
| --- | --- |
| Accounts | Original/extra account naming, profile retention, duplicate names, isolation, persistence |
| Audio | Independent accounts, popups, reconnect, crash recovery, real muted-audio detection, background playback controls |
| Updates | Release selection/origin, checksum/size rejection, portable replacement and rollback, CI installer handoff |
| Downloads | Two accounts, saved bytes, completed-handle release, drawer, history clearing |
| Recovery | Deliberate fixture renderer/browser crashes, retry cap, disconnect cancellation |
| Shell | Minimum sizing, full account names, navigation overflow, native chrome, themes, menus, horizontal/vertical rail layout and drag previews |
| Unread | Messenger-specific counts, unread markers, unrelated Facebook totals, per-account dismissal, restored hidden shortcuts |
| Resources | Private resident RAM, CPU normalization/sustained thresholds, memory scales, PID churn, process scope, top consumers, sampling lifecycle |
| Services | Unread parsing, origin boundaries, storage isolation, rapid switching, disconnect/reconnect |
| Background | Suspension, media/download guards, startup registration against an isolated store |
| Notifications | Document notifications, capture, suppression; service-worker/push behavior remains unverified |
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
3. On the signing Mac, build with `RELAY_DISTRIBUTION=1 RELAY_UPDATES=1 RELAY_UNIVERSAL=1 bash scripts/Build-macOS.sh`, notarize/staple with `bash scripts/Notarize-macOS.sh`, and package with `python3 scripts/Package-macOS-update.py`. The default macOS asset URL now uses the shared version tag.
4. Download the three Windows assets from the successful private tag release into a fresh directory. Write `SHA256SUMS-macos.txt` for the new `Relay-<BUILD>.zip` and unchanged signed `appcast.xml` in `dist/macos/updates`.
5. Run `python3 scripts/Publish-Release.py --version <version> --windows-dir <directory> --validate-only`, then repeat without `--validate-only`. The publisher verifies Windows CI digests, the extracted Mac archive's signature/ticket/Gatekeeper, Sparkle signatures, historical feed URLs, and all uploaded bytes. It publishes all six assets together as Latest, then advances the signed Mac feed with a compare-and-swap update.

Published releases and tags are immutable. Failure after publication requires inspection; never replace published assets. The older Windows-only PowerShell release/mirror scripts reject versions 0.6.3 and above to prevent incomplete shared releases. Publication uses the operator's GitHub CLI login and the existing local signing keys; credentials are never embedded in either app. Windows continues to select its platform-specific installer/ZIP from Latest, and macOS continues to use the existing signed Sparkle feed.

Portable update/rollback and installer checks run on Windows CI. Local desktop-input tests require coordination; prefer the offscreen macOS native-drop regression. Preserve local profiles and certificates throughout release work.

## Assets

- App icons: `scripts/New-Icon.ps1`.
- Service icons: `Assets`; [credits](../THIRD-PARTY-NOTICES.md).

Memory API: [GetProcessMemoryInfo / EX2](https://learn.microsoft.com/en-us/windows/win32/api/psapi/ns-psapi-process_memory_counters_ex2). Older-system fallback remains approximate.
