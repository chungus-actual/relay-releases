# Updates and checksums

The [latest release](https://github.com/chungus-actual/relay-releases/releases/latest) contains Windows and macOS packages. Relay also checks for updates in the app. Published downloads remain available in the [release history](https://github.com/chungus-actual/relay-releases/releases).

Relay 0.6.7 supports Windows x64 and macOS 14+ on Apple silicon and Intel. Future Mac releases will target Apple silicon; the [0.6.7 universal Mac download](https://github.com/chungus-actual/relay-releases/releases/tag/v0.6.7) remains available for Intel Macs.

## Verify a download

Download the checksum file from the **same release** as the package. Compare the full SHA-256 value, not just its beginning or end.

On Windows, open PowerShell in the download folder and substitute the package filename:

```powershell
Get-FileHash '.\Relay-<version>-Setup-x64.exe' -Algorithm SHA256
```

Compare the result with the matching entry in `SHA256SUMS.txt`. The portable ZIP has its own entry in that file.

On macOS, open Terminal in the download folder and substitute the Mac build number:

```sh
shasum -a 256 'Relay-<build>.zip'
```

Compare the result with the matching entry in `SHA256SUMS-macos.txt`. Some older Mac-only releases use `SHA256SUMS.txt`.

Checksums detect damaged or changed downloads. Windows packages are unsigned; checksums alone do not independently authenticate the publisher. The Mac app is Developer ID signed and notarized, and its in-app updater verifies signed archives.

## Update feed

[`macos/appcast.xml`](../macos/appcast.xml) is the live Sparkle feed. It is maintained by the release publisher and preserves historical download URLs. There is no need to download it to install Relay manually.

[Download Relay](../README.md) · [Security](../SECURITY.md)
