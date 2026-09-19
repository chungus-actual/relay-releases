# Platform parity — September 18, 2026

Baseline: main at 99062f0 (shared release 0.6.4). The Windows checkout was fast-forwarded from 0.6.2, preserving its local Google authentication changes.

## Shared behavior checked

| Area | Result |
| --- | --- |
| Catalog, version and icons | Both hosts use services.json and the shared version; Discord is included in 0.6.4. |
| Messenger layout and unread detection | Embedded scripts match, including retained-chat activation. |
| Gmail unread modes | Embedded extraction matches; both expose New since launch and All unread. |
| Music controls | Embedded media bridge matches for music providers. |
| Google authentication | Both recognize HTTPS accounts.google.com and accounts.youtube.com handoffs. Ordinary YouTube URLs, HTTP handoffs and lookalike hosts remain external with capture off. macOS authentication pages remain excluded from service media permissions. |
| Messenger CDN attachments | Windows now matches macOS: HTTPS fbcdn.net/fbsbx.com and their subdomains remain in the account for downloads, including popup requests. Attachment popups remain retained until download completion/cancellation instead of interrupting transfers when WebView2 automatically closes the window. This does not add the CDNs to service ownership. Other providers and lookalike domains retain existing routing. |

Source agreement is not proof of identical provider behavior across browser engines.

## Validation

- Portable script comparison: all four script pairs passed. Both CI workflows now run the comparison.
- macOS build-configuration checks: 5 passed on Windows.
- Shared release validation: 2 passed on Windows.
- Windows Release build and final self-contained development smoke suite: passed, including Google popup/main-view redirects, account isolation, actual Messenger CDN bytes from main/popup requests, automatic popup cleanup, Discord/unread fixtures, and the existing download/recovery checks. Logs: artifacts/parity-build.log and artifacts/smoke-test.txt. An initial suspension assertion failed once and did not recur in subsequent runs.
- macOS model check attempted through scripts/Test-macOS.sh: unavailable because swiftc is not installed on this Windows host.
- macOS native build, WebKit browser checks, and experimental Chromium checks: not run here. Added model and WebKit regressions cover Google handoff link/popup routing and external-host boundaries; they require a Mac to validate.
- Real provider authentication, calls, push notifications, uploads and DRM playback remain manual checks. No saved user accounts were used.

## Remaining platform differences

| Area | Windows | macOS |
| --- | --- | --- |
| Browser | WebView2 | WebKit in distributed builds; Chromium is experimental |
| Notifications | Native WebView2 document notifications | Page bridge and unread summaries; incomplete Notification API and worker coverage |
| Audio mute | Browser-view mute | HTML media/Web Audio bridge; not engine-wide |
| Resource display | Browser-process measurements and heavy consumers | Relay shell measurements only |
| Background suspension | WebView2 TrySuspend/Resume with activity guards | WebKit scheduling; no equivalent immediate suspension guarantee |
| Downloads | Pause/resume where supported | Interrupted-transfer resume where WebKit provides data; pause remains open |
| Updates | Windows installer/portable replacement | Signed Sparkle archives and native update flow |

Native window controls, keyboard conventions, tray/menu-bar behavior and signing remain platform-specific. macOS menu-bar icon visibility still has an unresolved report. See [macOS details](macos.md) for the engine limits and historical validation.
