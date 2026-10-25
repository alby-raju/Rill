# Development builds and release preparation

**0.4.0 is the MVP development version (build 7), targeting macOS 15+.** Packages are architecture-specific. CI validates Apple Silicon and Intel source/toolchains; that is not a fresh-installed-artifact result on every supported OS.

Paid Developer ID signing/notarization are **deferred at the owner's request**. Do not describe an ad-hoc development package as a notarized public release. No membership purchase is needed to build/test locally, and publication is a deliberate maintainer step after successful CI and review.

## Build and verify

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash scripts/test.sh
python3 scripts/check-docs.py
python3 scripts/collect-dependency-notices.py --check
bash scripts/release-artifacts.sh
```

The packaging pipeline stages a clean `dist/Rill.app` with the app/CLI, official protobuf compiler/includes, first-party icon/offline help, MIT license, third-party notices/resources and required Swift runtime compatibility libraries. Nested code and the app receive verified ad-hoc signatures. It creates an architecture-specific compressed DMG, SHA-256 checksum and provenance record containing source revision/dirty state and dependency/notice hashes.

Use only a clean expected revision for a reviewable artifact. Verify its version, signature, checksum, resources and bundled CLI. Build separately on Intel and Apple Silicon; do not label a single-architecture artifact universal. Keep generated output out of Git.

## Future signed distribution

When enabled by the owner, configure a Developer ID Application identity in the signing Mac's Keychain and an existing notarytool Keychain profile. Never commit passwords, private keys or signing material. Set `RILL_SIGN_IDENTITY` and `RILL_NOTARY_PROFILE`, then run `bash scripts/sign-and-notarize.sh` against the prepared app.

The signing script applies hardened-runtime signatures, submits/notarizes/staples/assesses the app and distribution DMG. That path needs real credentials and actual Gatekeeper acceptance before a signed-release claim. Do not run the development artifact script after distribution signing; it rebuilds an ad-hoc app. Keep the signing identity stable across upgrades and verify Keychain access on an actual upgrade.

## Before a public release claim

Record exact commit/hash, OS/CPU, service versions and results for:

- Fresh installed offline app/CLI/compiler/resource use and upgrade/recovery behavior.
- Actual Keychain permission/lock/denial and TLS/OAuth provider behavior.
- Keyboard-only navigation, VoiceOver, focus, contrast, reduced motion and supported window sizes.
- Independent real brokers/gRPC services and supported producer import/export round trips.
- Every relevant [capability acceptance criterion](CAPABILITIES.csv), with explicit owner-approved deviations where needed.
- Consistent version/help/docs/licenses/notices/checksums/provenance.

Use the [manual kit](../verification/README.md) and [testing guide](TESTING.md), then record separate real-service/fresh-machine evidence. Passing tests, screenshots or an MVP label cannot substitute for those gates. Release notes are maintained in [CHANGELOG.md](../CHANGELOG.md).

## GitHub development prereleases

Run **Development release** manually on `main`, supplying a new tag matching the source version, such as `v0.4.0-dev.1`. Run the **Security** workflow manually on the intended main revision and wait for deep Swift analysis before starting release preparation (the nightly run also qualifies if it analyzed that exact revision). The release workflow rejects other branches, mismatched/reused tags and revisions without successful build, dependency scan and both CodeQL checks. Routine PR security checks do not substitute for deep Swift analysis. It tests and packages on separate Apple Silicon and Intel runners, audits dependencies, verifies notices, and attests each DMG using GitHub OIDC (no stored signing key).

Only after both builds pass does it create a **draft prerelease** containing both installers, checksums, provenance, verification kit, MIT license, third-party notices and dependency pins. A failed build creates no release. A failed draft upload may leave an incomplete draft: inspect/delete that unpublished draft before retrying; never replace a published tag. Review all assets and replace the notes' maintainer placeholder with highlights, limitations and actual acceptance results, then publish explicitly:

```sh
gh release edit v0.4.0-dev.1 --draft=false --prerelease --repo alby-raju/Rill
```

Repository release immutability freezes published assets and their tag. Do not publish until every intended asset is attached. Use a new version/tag to correct a published release. This is a development preview, not a stable/notarized distribution claim.

Download the assets into one directory, then verify:

```sh
shasum -a 256 -c SHA256SUMS
gh attestation verify Rill-0.4.0-arm64-development.dmg --repo alby-raju/Rill
```

The attestation proves the GitHub build identity and artifact digest; it does not establish Apple trust or guarantee absence of vulnerabilities. Preserve the workflow run, exact source revision and acceptance evidence with release notes.
