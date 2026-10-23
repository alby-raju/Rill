# Validation

The debug application builds successfully. Ten XCTest cases passed on the local Apple Silicon Mac using the installed Xcode toolchain:

- Seven core cases: URL/query preparation, variables and Unicode, unresolved variables, disabled fields and CRLF header rejection, allowed schemes/embedded credentials, auth/body/timeout, atomic workspace round trip and duplicate identity rejection.
- Three loopback integration cases: real HTTP response and assertions, oversized Content-Length rejection, and cancellation of an in-flight request.

The same full-suite command used by GitHub Actions starts the fixture, waits for readiness, runs the tests, and stops the fixture on exit:

```sh
bash scripts/test.sh
```

CI uses the `macos-15` runner with Xcode 16.4. The workflow has read-only repository permissions and needs no repository secrets.

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
