# Testing and validation

Use full Xcode, not command-line tools alone, for XCTest and packaging:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash scripts/test.sh
```

The wrapper builds the native CLI and selected protobuf compiler, starts loopback HTTP/TLS/live/MQTT/AMQP fixtures, waits for readiness, runs tests and stops its fixtures. It uses ports 18749–18757; stop optional manual TLS fixtures first if they conflict. Required endpoint cases must not be skipped in CI. A bare `swift test` without fixture variables is only a partial run.

The current suite has **254 tests**, covering persistence/recovery, request fidelity, credentials/TLS, imports/bounds, assertions/hooks/runners, schemas, native protocol sessions, CLI behavior, privacy and bulk-tab safety. Tests are grouped under `Tests/RillCoreTests` by behavior domain. The native Kafka mock bridge is test-only and is not independent production-broker acceptance.

## Focus a regression

```sh
bash scripts/test.sh --filter BulkTabTests
bash scripts/test.sh --filter CLITests
```

Keep existing failure/cancellation/resource cases. Write tests for observable behavior, not private implementation details. Use temporary workspaces and synthetic values; never point test helpers at personal workspaces or production endpoints.

## Repository checks

```sh
bash scripts/format.sh --check
python3 scripts/check-docs.py
python3 scripts/collect-dependency-notices.py --check
```

Formatting tools and setup are in [CONTRIBUTING.md](../CONTRIBUTING.md). The docs check validates local links/screenshots, MIT/license packaging inputs and the preserved capability checklist. Dependency notices are generated from exact pinned clean checkouts; do not hand-edit the collected license text.

## Manual verification

```sh
python3 verification/server.py
```

Follow [the kit guide](../verification/README.md) and record results in a copy of [CHECKLIST.csv](../verification/CHECKLIST.csv). Stop the server before running its self-check, which owns the same ports:

```sh
python3 verification/verify.py --cli /absolute/path/to/rill
```

Optional Python gRPC and generated TLS/mTLS need explicit setup. The core kit installs nothing, changes no global trust and uses public dummy credentials. CI runs its default self-check against the newly built CLI on each macOS configuration.

## Visual and performance diagnostics

```sh
bash scripts/render-ui-previews.sh
```

A local WindowServer is required. The actual app renders isolated synthetic light/dark, compact/wide, welcome/loading/body/auth/workflow/response states into ignored `dist/ui-review`. The 100-tab diagnostics check bulk-close stability and one native menu build while 30 store updates occur during active menu tracking. Debug arguments are excluded from release builds. These captures are not a substitute for VoiceOver, input/focus or owner acceptance. Run `bash scripts/render-ui-previews.sh --screenshots` to refresh the two tracked README screenshots from the current app build.

The Close All interaction fix was retested successfully by the owner in installed 0.3.3. Its live sample traced the stall to repeated active context-menu rebuilding, not the ~1–2 ms tab-state operation. Raw process samples remain private and are not release assets. Detailed historical evidence is linked from the performance PR and capability checklist.

## CI and distribution

The required aggregate **Build and test on macOS** depends on every Apple Silicon/Xcode 26.2/26.3 and Intel/Xcode 26.3 job plus 72 compiled/executed generated-client loopback cases. Jobs build release code, verify notices/app signatures, run all tests and validate the kit. Preserve those gates; a passing local count cannot replace them.

Packaging and fresh-machine acceptance are described in [RELEASE.md](RELEASE.md). Record exact commit/artifact hash, OS/CPU and service versions for manual outcomes. MVP does not automatically mark partial capabilities verified.
