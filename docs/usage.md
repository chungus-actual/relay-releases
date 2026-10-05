# Controls

| Control | Action |
| --- | --- |
| Service icon | Focus its visible pane, or replace the focused pane |
| Layout → + | Open another account alongside the current one; disabled at four |
| Layout icon below Activity | Drawn presets for single pane, side by side, stacked, grid, main on left, or main on top |
| Layout → reset icon | Restore the current arrangement’s default proportions |
| Drag divider | Resize adjacent panes; proportions are saved |
| Divider arrow keys / double-click | Adjust sizes / reset a divider |
| Pane title / menu | Focus, choose another service, reload, move, show alone, or close |
| Close pane | Hide that pane while retaining its loaded account and sign-in |
| Drag icon | Reorder with a sliding preview |
| Right-click empty rail | Open a hidden account and restore its shortcut |
| Right-click icon | Load, unload, audio mute, dismiss, add account, rename, move, hide |
| Settings → Top tabs | Move the rail above the apps |
| Settings → Load / Loaded | Load / unload an account |
| Settings → Add account | Add an isolated account |
| Settings → Capture links | Keep external links inside Relay; off by default |
| Settings → General → Inline predictive text (macOS) | Allow macOS inline suggestions in Relay services; off by default; restart to apply |
| Settings → Eye | Show / hide shortcut |
| Settings → Moon | Allow sleep / keep awake |
| Settings → Rename / Remove | Rename any account; remove extras while retaining browser storage |
| Settings / right-click service → Report a problem | Description, diagnostic events, optional screenshot, and private report export |
| Right-click Messenger → Refresh Messenger display | Repaint visible chat panes while retaining drafts and scroll position |
| Bell | Mute captured notifications |
| Downloads | Searchable local history across restarts; progress, cancel, resume when available, open, folder |
| Download → Folder | Open its destination; select the file when present |
| Clear downloads | Clear completed history; files stay |
| Pulse | Hover: CPU and memory; leading consumers during high usage |
| Chevron | Compact sidebar |
| Service name | Full address / copy |
| Navigation menu | Controls at narrow widths |
| Right-click service → Zoom | Slider / reset |
| Playback buttons | Current title, previous, play/pause, next for YouTube, YouTube Music, Spotify, and Bandcamp |
| Update arrow | Restart to update |
| Tray → Quit | Exit |

| Shortcut | Action |
| --- | --- |
| Alt+1…9 | Visible accounts |
| Ctrl+R | Reload / retry |
| Ctrl+Shift+B | Report a problem (Cmd+Shift+B on macOS) |
| Ctrl+ / Ctrl− | Zoom in / out |
| Ctrl+0 | Reset zoom |
| Ctrl+Shift+Up/Down or Left/Right | Move focused shortcut |

## Behavior

- Fresh profiles start with every service unloaded. Saved choices carry over on later launches.
- Dismiss clears that account’s Relay badge and recent activity; it does not mark messages read on the website. Fresh unread evidence restores the badge.
- Messenger prefers its own unread totals and chat markers over Facebook’s general notification count. Visible unread rows alone show a dot, since the chat list is virtualized.
- A small moon below the service icon indicates confirmed suspension. The top-right badge is reserved for notifications.
- Original accounts keep their existing profiles, including after renaming. Clear an original account’s name to restore the provider name.
- Extra accounts have separate cookies, storage, zoom, notifications, and audio settings.
- External web links open in the default browser unless Capture links is enabled. Service navigation and supported sign-in routes stay in the account profile.
- Each download keeps its folder action while active or finished, even if the file has been moved or deleted.
- Music controls and the current title follow the playing account across pages and stay available while paused. Playback detection uses audio, MediaSession, and provider controls; unavailable skip actions are disabled.
- Packaged builds check the public release feed on launch and cache verified downloads. Installation waits for “Restart to update.” Local batch builds stay local.
- Audio mute includes account popups and survives reconnect/recovery.
- On macOS, **Inline predictive text** applies to Relay's WebKit service pages and their popups. Enabling it follows **Show inline predictive text** in macOS Keyboard settings; disabling it blocks those suggestions in Relay. It does not change other apps, spell checking, autocorrect, or a website's own suggestions (such as Gmail Smart Compose). Quit and reopen Relay after changing it; existing pages and drafts stay untouched until then. Experimental Chromium services do not support this setting.
- Renderer/browser crashes: up to three retries per two minutes; disconnect cancels retries.
- Downloads: up to 200 local history records across restarts; active transfers stay awake.
- Disconnect/recovery interrupts that account’s active downloads.
- Facebook top navigation is hidden only on Messenger routes; other Facebook routes retain it.
- Google sign-in popups return completed Gmail, Calendar, or Messages app navigation to the original service; ordinary app popups stay separate.
- Google Keep supports isolated accounts and Google sign-in handoff. It starts unloaded, with background sleep allowed.
- Gmail and Calendar open app routes directly. Reload/reconnect bypass remembered public landing pages.
- Caption shows known base domains; the address menu retains the complete URL.
- Greeting rotates in the title bar every five minutes; [numbered list and rules](greetings.md).
- Resource sampling: Relay and its browser processes, every two seconds while visible.
- Memory: private resident RAM; shared pages excluded. Older systems fall back to an approximate working-set total.
- Memory amber/red: 2/4 GiB, lowered to 10%/20% of physical RAM on smaller systems (minimum 0.5/1 GiB).
- CPU amber/red: 20%/50% sustained across three samples (about six seconds); readings remain live.
- High-usage attribution groups identified account processes; shared and unassigned browser work remains labeled separately.
- Sleeping services may delay alerts. Active media and downloads prevent sleep.
- Profile location: `%LOCALAPPDATA%\Relay`.
- Closing to tray and launch at login: Settings.

[Security](../SECURITY.md) · [Development](development.md) · [Bug reports](bug-reports.md)

## Multiple services in one window

Open a service, then open the **Layout** icon below Activity and use **+** to choose more accounts. Pick a drawn layout thumbnail and drag the dividers to set pane sizes. With top tabs, the same icon sits beside Activity. Right-click Layout to hide it; right-click empty rail space and choose **Show Layout button** to restore it. This preference survives restarting Relay. The flyout shows service icons inside the previews, disables unavailable actions, and closes with Escape or an outside click. Layout changes ease into place; divider dragging follows the pointer directly. Reduced-motion settings disable the transitions. The pane order, arrangement, and proportions survive restarting Relay. Resizing preserves the existing browser documents, drafts, playback, and sign-ins. Each account can appear once; use a separate account if you need another instance of the same service.

Click a browser or its service icon to focus it; a thin accent outline marks the active pane. The main navigation and zoom controls apply to that pane; media controls continue to target the playing account. Selecting another service from the rail replaces the focused pane, or focuses that service if it is already visible. In **Layout**, select a service icon to target a pane without closing the popover. The adjacent controls change its service, move it earlier or later, expand it to the whole workspace, or close it. The compact **Pane actions** control in the main title bar also exposes these actions. Panes have no separate title bars. Unloading or removing an account also removes its pane. Activity and Settings temporarily hide the workspace; selecting a service restores it.

YouTube is a separate service from YouTube Music, with its own account profile. Both start unloaded. YouTube video-title numbers do not become unread badges.


## Companions

Enable **Settings → Appearance → Companion**, then choose **Puke**, **Roof**, or **Rock**. One companion appears at a time. Companion selection lives in Settings, and the choice survives restarting Relay.

Puke is an orange tabby. Roof is a brown dog with floppy ears. Puke mostly naps. Roof spends more time watching the room: after about 45 quiet seconds he takes a 30-second nap, then wakes with a stretch. Both have occasional activities after 90–150 idle seconds. Music can bring out a seated paw wave or head bob; Roof is more likely to wake for it. Rock is a gray stone with eyes and stays still, even during music.

Click the companion to open their room. The nine actions include **Pet**, **Feed**, **Play**, the outfit control, **High five**, **Box** (Puke/Rock) or **Dig** (Roof), **Litter** (Puke) or **Walk** (Roof), **Game**, and **Groom** (Puke), **Shake** (Roof), or **Polish** (Rock). Puke licks a paw and wipes his face; Roof gives a quick head-and-tail shake; Rock gets a few quiet sparkles. Roof eats from a bowl of kibble, plays with a bone, and digs a small patch with alternating paw strokes. Rock also offers **Admire**, **Ponder**, and **Rinse**, with stationary props. Click the companion inside the room to interact, or the floor to choose where Puke or Roof plays. All nine actions support keyboard navigation.

The **Outfit** control keeps its category label; its tooltip and checked menu identify the current look: **Classic**, **Bandana**, **Hoodie** (**Cap** for Rock), or **Shades**. Click to cycle, or right-click to choose directly. Each companion remembers its own outfit while switching during this session; disabling the companion or restarting clears that wardrobe. Idle activities never change clothes. Clothing follows standing, seated, stretching, and sleeping poses, and selected shades stay on during naps. Reduced motion keeps grooming reactions static while allowing them to finish.

The room follows your local clock: dawn from 6–8 a.m., daytime from 8 a.m.–6 p.m., dusk from 6–8 p.m., and night from 8 p.m.–6 a.m. The window shows sunrise, sun and clouds, sunset, or moon and stars, with matching light across the room. This works in either app appearance and refreshes when you reopen the room.

While the room is open, companions occasionally share an original thought or an attributed philosopher quotation. The first arrives after 18–30 quiet seconds; later thoughts are spaced 90–150 quiet seconds apart and stay for ten seconds. Activities dismiss speech, and closing the room pauses its schedule.

Outfits and reactions are temporary. Switching companions clears the previous activity; turning the companion off retains your selection. Reduced-motion preferences keep reactions still. Quiet states update slowly, and animation pauses while Relay is inactive. There are no care meters or required chores.


## Find your way and saved places

Open the command palette with **Ctrl+K** on Windows or **Command+K** on macOS, or use the search button. Right-click that button to hide it; restore it from the rail context menu or **Settings → Appearance → Command palette button**. The keyboard shortcut remains available when the button is hidden. On Windows, clicking the button again dismisses the palette and keeps Relay active. The selected companion appears beside the heading, using Relay's normal colors and surfaces. Type an account, provider, workspace, bookmark, or action; abbreviated fuzzy queries also work. Use arrow keys and Enter/Return to choose, or Escape to dismiss. Hidden accounts are searchable without changing their shortcut visibility.

Use **Layout → Save workspace** to name the current panes, proportions, arrangement, and focused account. **Saved workspaces** and **Settings → Workspaces & bookmarks** open management controls for editing or deleting saved places. Switching a workspace reuses existing browser sessions and loads any missing accounts. Changing the live layout does not overwrite a saved workspace. Up to 32 workspaces can be saved.

Use **Workspaces & bookmarks → Add bookmark** to choose an account, name, and HTTPS address directly. You can also save the current page from an account's menu or the palette's **Bookmark current page** action. Bookmarks always open in their originating account; they never borrow another account's sign-in. Search, open, edit, and delete them under Workspaces & bookmarks, grouped by account. Duplicate addresses within an account update the existing bookmark. Up to 200 bookmarks can be saved. Removing an account removes its bookmarks and its panes from saved workspaces; unloading it keeps those saved places.

## Snoozing, identity, and portable settings

Right-click the notification bell, use an account's menu, or open Notifications in Settings to snooze for 30 minutes, one hour, eight hours, or until tomorrow at 9 AM. Global and account snoozes survive restart and expire automatically. Resume now clears the selected snooze; permanent quiet mode and per-account notification preferences remain independent. Snoozed activity still appears in Relay. Expiry does not replay suppressed notifications.

Relay uses ordinary system notification delivery, so OS permissions, Focus/Do Not Disturb, and user-configured OS exceptions remain authoritative. Snoozing adds suppression; Relay does not change OS settings or request priority interruptions. It does not claim to display the OS's current Focus state. macOS also clears already delivered Relay notifications when snoozing; Windows suppresses new notifications and leaves existing notifications under the OS's control.

Settings can be searched by section, control, or account name. **Account identity** (Rename on account menus) includes an optional Mint, Sky, Iris, Rose, or Amber color, shown with the account initial and caption. Names remain visible in tooltips and search, so identity does not depend on color alone.

**Export settings** writes a versioned JSON setup that works on both platforms: account names/order/visibility, identity colors, zoom, audio and notification preferences, awake preferences, Gmail badge mode, appearance, palette-button visibility, companion selection, quiet mode, capture-links preference, saved workspaces, and bookmark URLs. Cookies, credentials, browser profiles, download paths/history, temporary snoozes, and OS-specific settings such as login registration are excluded. Imports validate the complete file and show a count summary before applying. They merge accounts, preserve current sessions and sign-ins, keep unrelated accounts, and leave new accounts unloaded. Re-importing the same setup does not duplicate accounts or saved places.

Downloads keep up to 200 local history records across restarts, searchable by file or account name. Completed files can be opened or revealed; moved/deleted files remain labeled in history. Active transfers restored from history are marked interrupted and do not retain browser handles. Transfer resumption remains available only when the running browser supplies it; downloads do not resume automatically after Relay exits. Clearing finished history never deletes downloaded files. History is separate from exported settings and malformed history is preserved instead of overwritten.

## Service pop-out windows

Use the service titlebar's window button to choose **Pop out in Relay** or **Open in default browser**. Terminal pops out directly because it has no external browser page. The shortcut's context menu also offers pop-out. Each account can have its own resizable window; selecting its shortcut brings that window forward, including when minimized.

Pop-out moves the existing service into a Relay window, preserving its sign-in, page state, and running terminal tabs/splits. **Dock in Relay** or closing the child window returns it to the main layout. Switching to other services or Settings leaves it running. **Unload**, removing the account, or quitting Relay closes its window and session. Window placement is temporary and is not restored on restart. Opening a saved layout docks its included accounts. A service uses either a regular pop-out or the floating media player at a time.

## Floating playback and audio sources

When a loaded service has active or previously played media, use **Float player** beside the titlebar playback controls. The same signed-in browser moves into a resizable, movable window that stays above Relay and other applications. Use **Play / pause**, **Full screen**, or **Dock** there; closing the player also docks it. Switching services or opening Settings keeps the floating player running. Navigation, unloading, or browser recovery closes the floating presentation. Only one service floats at a time. Preloaded media and silent decorative autoplay loops do not create transport controls; music playing in a separate desktop application is not shown here.

Videos in the main document fill the player; audio services retain their service controls. Same-origin frames can supply transport media, but embedded/cross-origin players may retain the full service page or expose only the provider's own controls. Media opened in a separate service popup must be opened in the main service before using Float player.

Service/account shortcuts show a speaker only during active, unmuted audio playback. Idle audio contexts, silent video streams, paused/ended media, and muted accounts do not display it. WebKit checks audio-bearing media and samples Web Audio output; Windows and experimental Chromium use their browser engine's audio indicator. Short control-free notification audio is excluded from Relay's transport controls and releases its finished playback source, while subsequent service notifications can reuse the same audio object.

## Embedded terminal

Choose **Terminal** from the service rail or Settings. The compact glyph toolbar provides New tab (+), Split right, Split below, Expand/restore pane, Restart shell, and Close terminal view. Hover a glyph for its name and shortcut. New tabs and split shells belong to the active terminal account; they do not add accounts or service shortcuts. Each tab retains independent shells and a nested layout, with up to four resizable panes per tab and sixteen tabs per account. Windows starts PowerShell; macOS starts your account's login shell in your home directory. Drag a divider, use its arrow keys, or double-click to reset its size. The colored outline follows the shell you click or focus.

Double-click a tab or split-shell name to rename it inline; you can also focus its label and press **F2**. Press **Enter** to save or **Escape** to cancel; clicking elsewhere also saves. Names stay with their running sessions across tab/service switches and closing/reopening the terminal view, without changing the account name.

A tab's **×** closes that tab and its shells. Each split pane has its own **×**, which ends only that shell and its child processes. The toolbar's **Close terminal view** removes the account from Relay's visible layout while keeping its sessions running; selecting the account restores them. Sessions also keep running across service and tab switches. **Unload**, removing the account, or quitting Relay ends all its shells; **Restart shell** affects only the focused shell. Shell sessions and terminal tab layouts are not restored across Relay restarts.

Keyboard prefix: press **Ctrl+B**, release it, then **%** to split right, **"** to split below, **c** for a new tab, **comma (,)** to rename the current tab, **n/p** for the next/previous tab, **z** to expand/restore the focused pane, or **x** to close that pane. Press **Ctrl+B twice** to send Ctrl+B to an application such as tmux inside WSL. You can run `cmd`, `pwsh`, or `wsl` from the initial shell if installed.

Windows uses an embedded terminal with Relay's palette and appearance; Windows Terminal profile import is not supported. Terminal sessions and saved layouts containing terminal sessions stay local and are omitted from cross-platform setup exports.

On macOS, the same bundled terminal interface uses native PTYs. iTerm and Ghostty are not required. When compatible profiles are detected, **Import profile…** appears in the terminal toolbar. Select an iTerm2 or Terminal profile, or Ghostty configuration, to copy its installed font (including Nerd Fonts), colors, cursor settings, and supported scrollback/spacing settings. Each Terminal account remembers its imported snapshot. **Reimport current profile…** refreshes the snapshot; **Rescan profiles…** finds newly configured sources; **Relay defaults** resets it. Imports update all panes without restarting shells. The login shell already reads its usual shell startup files. App-specific commands, key bindings, backgrounds/transparency, and environment overrides are not imported. Ghostty imports explicit appearance settings, local config includes, and single named/file themes; automatic light/dark theme pairs and its byte-based scrollback limit are not translated. Missing fonts fall back to installed Nerd Fonts and Menlo; Relay does not install fonts. Pop-out windows retain the same shells, tab names, splits, and output; docking or reloading the terminal view does not restart them. Unload and quit terminate the shell session's foreground and background jobs. Programs that deliberately detach into a new OS session are outside that cleanup boundary.
