# Validation

The latest development validation includes 245 passing local tests, including real CLI interruption/listener cleanup, native loopback protocol fixtures and a packaged CLI smoke check. See [M8](milestones/M8.md), [M9](milestones/M9.md) and [release gates](RELEASE.md). The original ten XCTest cases passed on the local Apple Silicon Mac using the installed Xcode toolchain. The [M0 reliability slice](milestones/M0.md) extends these with storage, redaction and streaming-budget regressions:

- Seven core cases: URL/query preparation, variables and Unicode, unresolved variables, disabled fields and CRLF header rejection, allowed schemes/embedded credentials, auth/body/timeout, atomic workspace round trip and duplicate identity rejection.
- Three loopback integration cases: real HTTP response and assertions, oversized Content-Length rejection, and cancellation of an in-flight request.

The same full-suite command used by GitHub Actions starts the fixture, waits for readiness, runs the tests, and stops the fixture on exit:

```sh
bash scripts/test.sh
```

CI uses macOS 15 Apple Silicon with Xcode 26.2/26.3 and Intel with Xcode 26.3 (Swift 6.2.3+). The workflow has read-only repository permissions and needs no repository secrets.

To run the fixture manually instead, start it in one terminal:

```sh
python3 scripts/http-fixture.py
```

Run the complete suite in another:

```sh
RILL_TEST_BASE_URL=http://127.0.0.1:18749 swift test
```

If command-line tools are selected and XCTest is unavailable, select the installed Xcode toolchain just for the test command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer RILL_TEST_BASE_URL=http://127.0.0.1:18749 swift test
```

Without the fixture environment variable, the three transport cases are skipped. No public API service is contacted by the tests.

The release package is ad-hoc signed for local development. Visual interaction, Keychain prompts, installed-app launch, accessibility behavior, signing for distribution, and notarization have not been manually verified. Tests do not establish interoperability with the advanced protocols listed in the old archive.

The CI matrix also builds the app bundle, validates its Info.plist and verifies its ad-hoc signature. The bundle explicitly allows user-selected HTTP endpoints through App Transport Security; both ordinary requests and OAuth use an ephemeral URLSession configuration with a TLS 1.2 minimum. HTTPS certificate/hostname checks remain controlled by system trust or the explicitly selected request TLS profile. OAuth endpoint restrictions remain enforced independently. Local packaging and all 130 tests pass; actual installed-app HTTP interaction remains a manual acceptance item. See [Apple’s ATS exception documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloads).
