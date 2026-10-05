# Service icons

Messenger, WhatsApp, Telegram, Gmail, Google Calendar and Google Messages vector paths are from Simple Icons (develop snapshot fetched 2026-09-11); Slack, Google Keep, and Discord are from Simple Icons 11.0.0.

Source: https://github.com/simple-icons/simple-icons
License: CC0-1.0, full text in Assets/Services/LICENSE.txt. Brand names and logos belong to their respective owners.

The SVG paths are converted to frozen WPF Geometry resources and bundled locally; no icon font, runtime SVG library, CDN requests, or icon package is required.

Discord's path uses explicit command and arc-flag separators for WPF and macOS CoreSVG compatibility; the original coordinates are preserved.

Relay artwork is original project artwork, generated from scripts/New-Icon.ps1.

## Embedded terminal

The Windows and macOS terminals bundle [xterm.js](https://github.com/xtermjs/xterm.js) (`@xterm/xterm` 5.5.0) and `@xterm/addon-fit` 0.10.0 under the MIT License. Licenses are distributed in `Assets/Terminal/LICENSE-xterm.txt` and `Assets/Terminal/LICENSE-addon-fit.txt` (inside `Contents/Resources/Terminal` in the Mac app). Assets are vendored from their pinned npm registry archives; the terminal does not fetch scripts from a CDN at runtime.
