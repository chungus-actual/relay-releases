# Controls

| Control | Action |
| --- | --- |
| Service icon | Open account |
| Drag icon | Reorder with a sliding preview |
| Right-click empty rail | Open a hidden account and restore its shortcut |
| Right-click icon | Load, unload, audio mute, dismiss, add account, rename, move, hide |
| Settings → Top tabs | Move the rail above the apps |
| Settings → Load / Loaded | Load / unload an account |
| Settings → Add account | Add an isolated account |
| Settings → Capture links | Keep external links inside Relay; off by default |
| Settings → Eye | Show / hide shortcut |
| Settings → Moon | Allow sleep / keep awake |
| Settings → Rename / Remove | Rename any account; remove extras while retaining browser storage |
| Bell | Mute captured notifications |
| Downloads | Current-session downloads; progress, cancel, resume when available, open, folder |
| Download → Folder | Open its destination; select the file when present |
| Clear downloads | Clear completed history; files stay |
| Pulse | Hover: CPU and memory; leading consumers during high usage |
| Chevron | Compact sidebar |
| Service name | Full address / copy |
| Navigation menu | Controls at narrow widths |
| Right-click service → Zoom | Slider / reset |
| Playback buttons | Current title, previous, play/pause, next for active music |
| Update arrow | Restart to update |
| Tray → Quit | Exit |

| Shortcut | Action |
| --- | --- |
| Alt+1…9 | Visible accounts |
| Ctrl+R | Reload / retry |
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
- Renderer/browser crashes: up to three retries per two minutes; disconnect cancels retries.
- Downloads: recent 50 completed entries, current session; active transfers stay awake.
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

[Security](../SECURITY.md) · [Development](development.md)
