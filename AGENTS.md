# Release repository

This public repository hosts Relay downloads, user documentation, and the macOS update feed. Application source, builds, tests, signing, and publishing are maintained in `chungus-actual/relay`.

- Do not copy application source or build/release workflows into this repository.
- Published releases, tags, signed archives, checksums, and historical download URLs are immutable. Fixes require a new release.
- Preserve `macos/appcast.xml` at its existing path. The source repository's verified publisher updates this feed; documentation cleanup must leave its bytes unchanged.
- Keep installation instructions accurate for both Windows and macOS. Do not advertise unverified platform support.
- Verify local documentation/image links and confirm release assets, tag refs, and the feed are unchanged after repository cleanup.
- Keep the artwork and bundled third-party license notices with the public documentation.
