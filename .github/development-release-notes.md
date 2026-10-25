Rill MVP development preview for macOS 15 or later.

- `arm64`: Apple Silicon; `x86_64`: Intel. These are separate installers.
- Ad-hoc signed, **not Apple Developer ID signed or notarized**. Gatekeeper may block installation. Source builds remain available; no system-wide security changes are required or recommended.
- Includes the app, CLI and bundled protobuf compiler. See the README, feature limits and manual verification kit before relying on a protocol or import format.
- Verify downloads with `shasum -a 256 -c SHA256SUMS` from the downloaded asset directory. GitHub build provenance can be checked with `gh attestation verify FILE.dmg --repo alby-raju/Rill`.
- MIT license; bundled dependencies retain their own licenses. `THIRD_PARTY_NOTICES.txt` and `Package.resolved` accompany the installers.

Maintainer: replace this paragraph with highlights, known issues and actual manual acceptance results before publishing. Publication freezes the assets and associated tag when repository release immutability is enabled. Never describe this build as notarized or fully conformance-tested.
