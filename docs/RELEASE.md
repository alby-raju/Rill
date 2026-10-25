# Release preparation

Paid Developer ID signing and notarization are deferred at the owner’s request (2026-10-25). No membership purchase is needed for current development work. Keep the distribution instructions below for later; do not publish a notarized-release claim.

Rill 0.3.0 is a development build targeting macOS 15 or later. Required CI builds/tests Apple Silicon with Xcode 26.2/26.3 and Intel with Xcode 26.3. This validates source/toolchains, not installed artifacts on all OS versions.

Run `bash scripts/test.sh`, the roadmap audit and dependency notice check. `bash scripts/release-artifacts.sh` builds an ad-hoc signed app, bundled native CLI/protoc/includes/Swift runtime compatibility libraries/help/icon/licenses, compressed DMG, SHA-256 checksum and provenance with source commit and dirty-state marker. It does not notarize or publish. Artifacts are architecture-specific; do not label one architecture universal. Build separately on Intel and Apple Silicon.

For distribution, obtain a Developer ID Application certificate in the signing machine's Keychain and store notarytool credentials in a Keychain profile. Set `RILL_SIGN_IDENTITY` and `RILL_NOTARY_PROFILE`, then run `bash scripts/sign-and-notarize.sh`. Credentials and certificates never enter the repository. The script signs nested code with hardened runtime, submits the app, staples and assesses it, then creates/signs/submits/staples the distribution DMG. Keep signing identity stable across upgrades and verify Keychain access on a real upgrade. Never use the development artifact script after signing: it rebuilds an ad-hoc app.

Before publishing, complete docs/roadmap/ACCEPTANCE.md on fresh Macs, including offline installed launch, real Keychain permissions, upgrade/recovery, VoiceOver/focus/contrast/reduced motion, real TLS/OAuth and independently operated broker/gRPC endpoints. Record artifact hashes, OS/CPU, results and any owner-approved deviations against each capability. A passing suite does not establish full Relay parity. No release tag or public release is created automatically.

## 0.3.0 development release notes

Redesigns the full-height welcome/workbench, branded startup experience, native selectors, buttons and focused fields, grouped auth/TLS panels, body editor and workflow empty states. Blank requests start without a body. Includes reproducible synthetic UI previews for compact/wide and light/dark layouts. See [UX evidence](milestones/UX-refresh.md).

## 0.2.0 development release notes

Adds native gRPC/MQTT/AMQP/Kafka workbenches, a shared native CLI, explicit Git workspace operations, sanitized token-protected sharing, reviewed data-only extension services, offline help and original Rill icon. The new package includes the CLI, official protoc and required compatibility runtimes. Protocol subsets and resource bounds remain documented in milestone evidence. Signing and manual release acceptance are pending until performed with actual credentials/devices.
