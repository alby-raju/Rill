Rill MVP development preview for macOS 15 or later.

- `arm64`: Apple Silicon; `x86_64`: Intel. These are separate installers.
- Ad-hoc signed, **not Apple Developer ID signed or notarized**. Gatekeeper may block installation. Source builds remain available; no system-wide security changes are required or recommended.
- Includes the app, bundled CLI, and a separate CLI-only ZIP for each architecture with required resources and completions. See the README, feature limits and manual verification kit before relying on a protocol or import format.
- Verify downloads with `shasum -a 256 -c SHA256SUMS` from the downloaded asset directory. GitHub build provenance can be checked with `gh attestation verify FILE.dmg --repo alby-raju/Rill`.
- MIT license; bundled dependencies retain their own licenses. `THIRD_PARTY_NOTICES.txt` and `Package.resolved` accompany the installers.

## 0.4.6 preview highlights

- Ad-hoc HTTP requests support offline inspection, nested JSON, body streaming, response header selection and JSON/XML formatting.
- The CLI adds explicit CONNECT and SOCKS5 proxies, scoped HTTPS proxy CA trust, numbered same-origin redirect traces, and resumable downloads using strong ETags.
- Encrypted HTTPS sessions can retain selected headers and authorization for the exact origin.
- Cross-origin redirects remain blocked. Enterprise proxy deployments and installed workflows require further acceptance.

Maintainer: add the actual installed-artifact acceptance results before publishing. Publication freezes the assets and associated tag when repository release immutability is enabled. Never describe this build as notarized or fully conformance-tested.
