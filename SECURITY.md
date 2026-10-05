# Local storage and credential handling

Relay delegates service authentication and browser storage to WebView2. It does not implement a password vault, collect sign-in field values, import existing browser credentials, or call a password-manager API. Host objects and web messaging are disabled. Service navigation is HTTPS, apart from the blank-page placeholder used for popups.

## What is stored

- Settings: plain JSON under %LOCALAPPDATA%/Relay/settings.json. Theme, enabled/live/notification preferences, zoom, selected service, shortcut order, and visibility. No password fields are defined in this schema.
- Cookies, sessions, and site storage: WebView2's browser data beneath %LOCALAPPDATA%/Relay/Browser. Each service has a separate WebView2 profile. These separate website sessions; they are not independent Windows security boundaries.
- Recent Activity entries: up to 60 entries in Relay memory, not intentionally saved by Relay. Websites and Windows notification infrastructure may retain their own data.
- Error diagnostics: plaintext errors.log plus errors.log.1 through errors.log.3, each capped at 1 MiB. Oversized entries are truncated and oldest archives are replaced. Exception context may include paths or other diagnostic information; this is not an encrypted log.

## At-rest protection: observed, not a blanket guarantee

On the installed WebView2 runtime 152.0.4191.66, a fresh isolated smoke profile contained an os_crypt key with a DPAPI wrapper. A deliberately synthetic persistent cookie appeared by name in its Cookies database while its known value was not visible as plaintext. A synthetic localStorage key was directly readable in the profile's storage files. No real account profile, password, or encryption key was decrypted or inspected for this check.

This is evidence of runtime-managed protection for the tested cookie, not proof that all browser data is encrypted. Site localStorage, IndexedDB, caches, and diagnostic files must not be treated as a Relay-encrypted vault. The application currently has no master password, Windows Hello lock, encrypted-profile container, or separate key lifecycle.

Microsoft documents Windows DPAPI protection for Edge's saved-password encryption keys and also explains its limits against code running with the user's authority. Do not assume every Edge feature or protection is identically available in WebView2; Relay relies on the installed runtime's behavior and has not independently audited its cryptography.

## Password managers

WebView2 supports optional built-in password save/autofill. It defaults off and Relay currently leaves it off. Enabling that in a future setting would store data in Relay's browser profiles, not automatically reuse an existing Edge/Chrome password store.

WebView2 also has APIs for enabling extensions and loading unpacked extension directories into individual profiles. That is a possible route for third-party password managers, not proof of compatibility. Relay currently enables no extensions and has no extension UI, vault-unlock integration, or native-messaging support implemented. Specific managers must be tested before advertising support. Clipboard paste is available as an ordinary web-field interaction; desktop auto-type depends on the manager and the site's form.

## Updates

- Feed: the public `chungus-actual/relay-releases` repository over HTTPS; source remains private.
- Stable versions only; exact asset names and GitHub paths, bounded metadata/archive sizes, no downgrades.
- SHA-256 is checked after download and again by the install helper. Packages remain local until acknowledged restart.
- Portable archives reject traversal, duplicate paths, symlinks, and oversized expansion. Destination links are rejected. File replacement uses atomic swaps with rollback on failure.
- CI actions and tool downloads are pinned; dependencies use a lock file. Public mirroring verifies downloaded checksums and uploaded asset digests before publishing.
- Installers are unsigned. The release manifest is not independently signed: a compromised release publisher could replace both package and checksum. SHA-256 provides integrity, not independent publisher authentication.

## References

- [WebView2 user data](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/user-data-folder)
- [Password save/autofill setting](https://learn.microsoft.com/en-us/dotnet/api/microsoft.web.webview2.core.corewebview2profile.ispasswordautosaveenabled?view=webview2-dotnet-1.0.3650.58)
- [Extension loading API](https://learn.microsoft.com/en-us/dotnet/api/microsoft.web.webview2.core.corewebview2profile.addbrowserextensionasync?view=webview2-dotnet-1.0.3856.49)
- [Microsoft's password-manager security model](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-security-password-manager-security)
