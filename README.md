<div align="center">

<img src="Assets/Relay-preview.png" width="96" alt="Relay logo" />

# Relay

**Chats, mail and music in one window, for Windows and macOS.**

Relay runs the web versions of Messenger, WhatsApp, Telegram, Gmail, Slack, Discord, Google Calendar,
Keep and Messages, plus YouTube, YouTube Music, Spotify, Bandcamp and a terminal. Each account keeps
its own sign-in. Relay adds what a row of browser tabs doesn't have: one place for unread counts,
side-by-side layouts, and playback controls that follow whatever is playing.

[![Latest release](https://img.shields.io/github/v/release/chungus-actual/relay-releases?label=release)](https://github.com/chungus-actual/relay-releases/releases/latest)
![Windows 10+ x64](https://img.shields.io/badge/Windows-10%2B%20x64-0078D4)
![macOS 14+ Apple silicon](https://img.shields.io/badge/macOS-14%2B%20Apple%20silicon-000000)
![No telemetry](https://img.shields.io/badge/telemetry-none-lightgrey)

**[Download for Windows](https://github.com/chungus-actual/relay-releases/releases/latest)** ·
**[Download for macOS](https://github.com/chungus-actual/relay-releases/releases/tag/macos-0.6.12-29)**

<img src="docs/screenshots/hero.png" width="840" alt="Relay with Bandcamp, YouTube Music and a terminal side by side, unread counts on the left rail and playback controls in the title bar" />

<sub>Bandcamp, YouTube Music and a terminal in one layout, with Bandcamp's track in the title bar controls.</sub>

</div>

---

## Screenshots

| | |
|:---:|:---:|
| <img src="docs/screenshots/activity.png" width="100%" alt="Activity page with every service, unread counts and recent notifications" /><br><sub><b>Activity.</b> Every service in one grid, with unread counts and recent notifications</sub> | <img src="docs/screenshots/layouts.png" width="100%" alt="Layout picker showing six arrangements" /><br><sub><b>Layouts.</b> Up to four services at once. Drag the dividers and save the arrangement</sub> |
| <img src="docs/screenshots/palette.png" width="100%" alt="Command palette with search results" /><br><sub><b>Command palette.</b> Jump to any account, workspace, bookmark or action</sub> | <img src="docs/screenshots/terminal.png" width="100%" alt="Terminal with two tabs and three split panes" /><br><sub><b>Terminal.</b> Tabs and splits, next to everything else</sub> |
| <img src="docs/screenshots/themes.png" width="100%" alt="Appearance settings in light mode with the Dune surface and Rose accent" /><br><sub><b>Themes.</b> Light, dark or system, three surfaces, five accents</sub> | <img src="docs/screenshots/companion.png" width="100%" alt="The cat companion's room, opened from the title bar" /><br><sub><b>Companion.</b> An optional cat, dog or rock in the title bar</sub> |

<sub>Screenshots are from Windows with a fresh profile. Unread counts and messages are demo data.</sub>

## Contents

[Screenshots](#screenshots) · [Features](#features) · [Services](#services) · [How it works](#how-it-works) ·
[Install](#install) · [Updates](#updates) · [Keyboard](#keyboard) · [Privacy](#privacy) ·
[Troubleshooting](#troubleshooting) · [Source](#source) · [Notices](#notices)

## Features

| | |
|---|---|
| **Unread in one place** | Each account shows a badge on the rail, and Activity lists recent notifications from all of them. Dismissing one in Relay doesn't mark it read on the site |
| **More than one account** | Add a second Gmail or WhatsApp with its own sign-in, cookies, zoom, notifications and audio. Give any account its own name and an identity color |
| **Layouts** | Up to four services side by side, stacked, in a grid, or one large pane with the rest beside it. Drag the dividers; Relay remembers the arrangement. Save up to 32 named workspaces |
| **Playback controls** | Play, pause and skip YouTube, YouTube Music, Spotify and Bandcamp from the title bar, whichever service you're looking at. On Windows the taskbar thumbnail has the same buttons |
| **Float player** | Move a playing service into its own window that stays above other apps, with play/pause, full screen and dock |
| **Pop-out windows** | Open any account in its own Relay window and dock it back later, with its sign-in and page intact |
| **Command palette** | Ctrl+K (Cmd+K on a Mac) finds accounts, workspaces, bookmarks and actions. Bookmarks always open in the account that saved them |
| **Terminal** | PowerShell on Windows and your login shell on macOS, with up to 16 tabs and four splits per tab. On macOS it can copy fonts and colors from an iTerm2, Terminal or Ghostty profile |
| **Quiet when you need it** | Mute notifications, or snooze them for 30 minutes, an hour, eight hours or until 9 tomorrow, for everything or one account |
| **Background sleep** | Let accounts you aren't using sleep in the background. Playing media and active downloads keep an account awake. The pulse icon on the rail shows CPU and memory use |
| **Downloads** | Files from every service land in one searchable list, kept across restarts |
| **Settings that travel** | Export your accounts, layouts and bookmarks to a file and import it on either platform. Sign-ins aren't included |
| **Themes** | Light, dark or follow the system, with three surfaces (Graphite, Ocean, Dune) and five accents |
| **Companion** | An optional cat, dog or rock in the title bar. Click it to open its room |
| **Problem reports** | Ctrl+Shift+B (Cmd+Shift+B) builds a report with recent diagnostic events and an optional screenshot, saved as a file for you to review and send |

## Services

| | |
|---|---|
| **Chat** | Messenger, WhatsApp, Telegram, Slack, Discord, Google Messages |
| **Mail and planning** | Gmail, Google Calendar, Google Keep |
| **Music and video** | YouTube, YouTube Music, Spotify, Bandcamp, with playback controls in the title bar |
| **Local** | Terminal |

A fresh profile starts with every service unloaded; click one to load it. To add another account of
the same service, right-click its icon and choose Add account, or use Settings > Add account.

Badges come from what each site exposes: the count in its page title, or for Messenger and Gmail,
the unread markers on the page. A site that shows no count can have unread messages without a badge.

## How it works

Every account is the service's own website, running in a browser profile of its own: WebView2 on
Windows, WebKit on macOS. Relay reads the unread count and what is playing from the page, and leaves
sign-in, messages and storage to the site and the browser engine.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/diagrams/account-model-dark.svg">
  <img src="docs/diagrams/account-model-light.svg" alt="How an account works: each account is the real website in its own browser profile (cookies, storage, sign-in); Relay reads the unread count for the rail badge, what is playing for the title bar controls, and notifications for desktop toasts, and shows the account in a pane, up to four at once">
</picture>

The terminal is the exception: it is a local page running a real shell, PowerShell on Windows or
your login shell on macOS. Its sessions keep running when you switch services and end when you
unload the account or quit Relay.

## Install

Get the [latest release](https://github.com/chungus-actual/relay-releases/releases/latest) for Windows,
or the [current Mac build](https://github.com/chungus-actual/relay-releases/releases/tag/macos-0.6.12-29).

**Windows**

| | |
|---|---|
| **Installer** | `Relay-<version>-Setup-x64.exe` installs for your user only, with no admin prompt, to `%LOCALAPPDATA%\Programs\Relay`. If the [WebView2 Runtime](https://developer.microsoft.com/microsoft-edge/webview2/) is missing, setup installs it first |
| **Portable** | `Relay-<version>-win-x64.zip`: unzip anywhere and run `Relay.exe`. Needs the WebView2 Runtime already installed |
| **Needs** | 64-bit Windows 10 or later. The .NET runtime is included |
| **Signing** | Not code-signed. Each release lists SHA-256 checksums in `SHA256SUMS.txt` |
| **Your data** | Settings and browser profiles live in `%LOCALAPPDATA%\Relay`. Uninstalling keeps them |

**macOS**

| | |
|---|---|
| **Download** | `Relay-<build>.zip`. Unzip it, move Relay to Applications and open it |
| **Needs** | macOS 14 or later on Apple silicon. For Intel Macs, the last release is the [0.6.7 universal build](https://github.com/chungus-actual/relay-releases/releases/tag/v0.6.7) |
| **Signing** | Developer ID signed and notarized |
| **Your data** | Settings in `~/Library/Application Support/Relay/macOS/settings.json`; each account's website data in its own WebKit store |

## Updates

Relay updates itself from this repository's releases and never installs an update until you say so.

| | Windows | macOS |
|---|---|---|
| **Checks** | On launch, or with Check updates at the bottom of Settings | Automatically through Sparkle, or with Relay > Check for Updates |
| **Reads** | The Latest release; stable versions only, never a downgrade | The signed feed `macos/appcast.xml` |
| **Verifies** | SHA-256 of the installer or ZIP after download, and again before installing | Sparkle's EdDSA signatures on the feed and the archive |
| **Installs** | When you click the update arrow (Restart to update) | When you accept the update prompt |

The portable ZIP updates in place, with rollback if a file swap fails. Apple-silicon-only Mac updates
are not offered to Intel Macs, which stay on 0.6.7.

## Keyboard

| Action | Windows | macOS |
|---|---|---|
| Command palette | Ctrl+K | Cmd+K |
| Visible accounts, in rail order | Alt+1 to Alt+9 | Cmd+1 to Cmd+9 |
| Reload | Ctrl+R | Cmd+R |
| Zoom in, out, reset | Ctrl+Plus, Ctrl+Minus, Ctrl+0 | Cmd+=, Cmd+Minus, Cmd+0 |
| Report a problem | Ctrl+Shift+B | Cmd+Shift+B |
| Terminal: split right, split below | Ctrl+B, then `%` or `"` | Ctrl+B, then `%` or `"` |
| Terminal: new tab, rename tab, next, previous | Ctrl+B, then `c`, `,`, `n`, `p` | Ctrl+B, then `c`, `,`, `n`, `p` |
| Terminal: expand pane, close pane | Ctrl+B, then `z` or `x` | Ctrl+B, then `z` or `x` |

Press Ctrl+B twice to send Ctrl+B to a program inside the terminal, such as tmux. The full list of
controls is in [Controls](docs/usage.md).

## Privacy

There's no Relay account, server or telemetry. Each service is the real website, running in its own
browser profile on your computer, so your sign-ins and messages stay between you and that service.
Apart from the services you open, Relay only contacts GitHub to check for updates. Bug reports are
saved as a file for you to review and send yourself. More in [Security](SECURITY.md).

## Troubleshooting

| Symptom | Cause, fix |
|---|---|
| Windows warns about an unrecognized app | The Windows builds aren't code-signed. Compare the file with `SHA256SUMS.txt` on the release, then choose More info > Run anyway |
| Setup says the WebView2 Runtime is required | Setup downloads it from Microsoft when it's missing, which needs a connection. Install the [WebView2 Runtime](https://developer.microsoft.com/microsoft-edge/webview2/) yourself and run setup again |
| Messenger shows blank or half-drawn messages | Right-click Messenger and choose Refresh Messenger display. It repaints the chat without reloading or losing a draft |
| A badge stays after I've read the message | Right-click the account and choose Dismiss. Relay hides that count until new unread activity appears; it never marks anything read on the site |
| Gmail's badge is lower than the inbox count | By default a Gmail badge counts new mail since Relay started. Switch the account to All unread in its Gmail settings |
| Links open in my browser instead of Relay | That's the default. Turn on Capture links in Settings to keep them inside Relay |
| Alerts from a background account arrive late | A sleeping account can delay alerts. Keep that account awake from its Settings row or menu |
| No notifications on macOS | Notifications are off by default on the Mac. Turn on Show notifications in Settings and allow Relay when macOS asks |
| Media keys go to Relay on macOS | Turn off Settings > General > Media controls, then quit and reopen Relay. WebKit can still claim the keys while a page plays audio or video |
| Camera or microphone fails on macOS | Allow Relay under System Settings > Privacy & Security > Camera or Microphone, then retry the call |
| Removing everything on Windows | Uninstalling keeps your accounts and sign-ins. Delete `%LOCALAPPDATA%\Relay` as well to remove them |
| Something else | Press Ctrl+Shift+B (Cmd+Shift+B), describe the problem and save the report. It leaves out page titles, URLs, account names and cookies; review the description and screenshot before sharing it |

## Source

This repository has the Windows and macOS source for every release. Each `source-v<VERSION>` or
`source-macos-<VERSION>-<BUILD>` tag is a release snapshot, and `.release-source.json` records its
original commit and file hashes. To build it, see [Development](docs/development.md).

[Download the current Mac source](https://github.com/chungus-actual/relay-releases/archive/refs/tags/source-macos-0.6.12-29.zip)
or [Windows 0.6.12 source](https://github.com/chungus-actual/relay-releases/archive/refs/tags/source-v0.6.12.zip).
Release tags point to their matching public source snapshot.

| | |
|---|---|
| **Windows** | WPF on .NET 10 with WebView2. Build and test notes in [Development](docs/development.md) |
| **macOS** | SwiftUI with WKWebView, macOS 14 or later. Build notes in [macOS](docs/macos.md) |
| **Shared** | `services.json` (the service catalog), `Assets/` (artwork, the terminal page, test fixtures) |

[Controls](docs/usage.md) · [macOS](docs/macos.md) · [Development](docs/development.md) ·
[Bug reports](docs/bug-reports.md) · [Security](SECURITY.md) · [Credits](THIRD-PARTY-NOTICES.md)

## Notices

Service icons are from [Simple Icons](https://github.com/simple-icons/simple-icons) under CC0 1.0;
brand names and logos belong to their owners. The terminal bundles
[xterm.js](https://github.com/xtermjs/xterm.js) and its fit add-on under the MIT License. The Mac app
bundles [Sparkle](https://sparkle-project.org) 2.10.0 for updates. Details in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
