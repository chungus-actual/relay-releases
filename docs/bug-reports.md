# Bug reports

Open **Settings → Report a problem**, or right-click a service icon and choose **Report a problem**. The shortcut is **Ctrl+Shift+B** on Windows and **Cmd+Shift+B** on macOS; macOS also has a Help-menu command.

Describe the problem, expected behavior, and reproduction steps. Review the diagnostics and optional image, then choose **Save report**. This build leaves online submission disabled while hosting is being chosen. Share the saved JSON privately with the maintainer; the intended destination is the private `chungus-actual/relay` repository.

Reports include the app/OS/browser details, the selected provider's loading and visibility state, and up to 200 recent diagnostic events from this Relay session. These events record navigation and rendering/recovery actions. Raw error logs, page titles, URLs, account names, cookies, browser profiles, and sign-in data are not collected. Descriptions and optional screenshots can contain private information, so review them before sharing. Intake codes are never saved in a report.

**Capture page** captures the chosen visible WebView2 or WebKit page. **Attach PNG** accepts an existing PNG up to 6 MiB, including an OS screenshot. **Remove image** excludes it from the report. Experimental macOS Chromium currently requires attaching a PNG because its bridge has no page-snapshot API. A page snapshot can itself repaint a drawing glitch; use an OS screenshot when that happens.

For Messenger rendering problems, right-click the visible Messenger account and choose **Refresh Messenger display**, or use the macOS Help menu. It briefly moves visible scroll panes by one pixel and restores their positions, unless a newer scroll has already occurred. This can refresh retained content without reloading the document or clearing a draft. It is a workaround; the reported WebKit drawing defect has not been reproduced against a signed-in account.

## Enabling private submission later

The standard-library Python service in `reporting/intake.py` accepts `POST /reports`. Deploy it on your chosen host behind an HTTPS reverse proxy. It listens on `127.0.0.1:8787` by default; `PORT` changes the port. Configure proxy request-size limits to allow the service's 9 MiB maximum, a suitable upstream timeout, and connection/rate limits. Keep request bodies and intake headers out of proxy logs.

Provide these environment variables on the host, outside the repository and application bundles:

| Variable | Value |
| --- | --- |
| `GITHUB_TOKEN` | Token restricted to the private repository, with Contents and Issues write access |
| `RELAY_INTAKE_KEY` | Random intake code of at least 24 characters, distributed privately to testers |
| `RELAY_REPORT_REPOSITORY` | `chungus-actual/relay` (default) |
| `RELAY_REPORT_BRANCH` | `bug-reports` (default); create this branch before starting intake |

Run `python3 reporting/intake.py`. Startup verifies that the repository is private and the reports branch exists. Each submission rechecks repository privacy. Set `reporting.json` to your HTTPS `/reports` endpoint and destination label before building clients; both platforms bundle this configuration. Do not place either credential in that file. Clients reject plain HTTP, embedded URL credentials, and fragments, and do not follow upload redirects.

When enabled, **Send report** sends only the reviewed report and a separately entered intake code. A confirmed receipt contains the same report ID and `stored: true`. Once sending starts, the report content is frozen so **Retry send** and **Save report** retain exactly those bytes after an uncertain outcome. Close and reopen the form to create a new report with different content.

Each accepted report is an immutable `reports/<id>.zip` on the reports branch, containing `report.json` and optionally `screenshot.png`. A best-effort GitHub issue links to the ZIP. The ZIP is the durable receipt: if issue creation fails, or the connection is lost after the ZIP commit, a retry confirms storage without creating another issue. Review the reports branch for ZIPs without issues. Reusing an ID with different content returns a conflict. The code allows one active submission and up to ten accepted attempts per minute per process.

Keep the repository private for as long as it contains reports, and use a separate private repository if the source repository may become public. A privacy check at submission time cannot protect reports from a later visibility change.

## Validation

Run `python -m unittest discover -s reporting -v` for schema/bounds, private-repository enforcement, receipts, duplicate/racing submissions, uncertain network outcomes, issue failures, and HTTP authentication/busy-slot recovery. The tests use a fake GitHub service and a loopback HTTP server; they do not upload data.

Windows smoke checks cover diagnostic exclusions, bounded events, real WebView2 capture, removed images, invalid descriptions, hidden-page capture, and the Messenger deep-DOM refresh. Swift model checks cover serialization, bounds, cleared attachments, and script parity. `bash scripts/Test-macOS-browser.sh --messenger-visibility` checks real WebKit scrolling, retained drafts/documents, repeated activation, newer scrolls, large chat DOMs, and stale routes. See [platform parity](platform-parity.md) for what has actually run on each host.
