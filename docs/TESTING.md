# Testing and validation

Use full Xcode, not command-line tools alone, for XCTest and packaging:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash scripts/test.sh
```

The wrapper builds the native CLI and selected protobuf compiler, starts loopback HTTP/TLS/live/MQTT/AMQP fixtures, waits for readiness, runs tests and stops its fixtures. It uses ports 18749–18757; stop optional manual TLS fixtures first if they conflict. Required endpoint cases must not be skipped in CI. A bare `swift test` without fixture variables is only a partial run.

The current suite has **262 tests**, covering persistence/recovery, request fidelity, credentials/TLS, imports/bounds, assertions/hooks/runners, schemas, native protocol sessions, CLI behavior, privacy and bulk-tab safety. Tests are grouped under `Tests/RillCoreTests` by behavior domain. The native Kafka mock bridge is test-only and is not independent production-broker acceptance.

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

The required aggregate **Build and test on macOS** always runs. Routine source PRs and main pushes run Apple Silicon/Xcode 26.3, the full fixture-backed suite, packaging/signature/notices checks, the manual kit and all 72 generated-client cases. Weekly scheduled and manually dispatched Swift CI runs additionally cover Apple Silicon/Xcode 26.2 and Intel/Xcode 26.3. Release candidates independently test/package both CPU architectures before staging a draft.

Only PRs containing exclusively the explicit root-documentation allowlist, `docs/` Markdown/CSV/PNG, direct Discussion/Issue YAML forms, or the CI planner/docs validator and their dedicated regression tests skip native builds. Planner-only changes still receive regression tests, workflow linting and Python CodeQL; this exception cannot be mixed with product, dependency or other workflow/script changes. The planner checks both sides of renamed/deleted paths; unknown, empty, workflow, dependency, license, other script and product-source changes require compilation. Documentation checks and planner regression tests still run, and the aggregate rejects failed planning or unexpected skips. Security dependency/Python checks always run. Deep Swift CodeQL runs nightly/on demand rather than on routine PR/main pushes; releases require a successful deep scan of the exact source revision. It is not treated as passing when skipped or missing.

Swift `.build` caches are isolated by OS/CPU, exact Xcode/Swift/SDK fingerprint and both package manifests. Only successful non-PR runs save caches; PRs can restore trusted main caches. Compilation/tests still execute after restore. CodeQL pins the analysis target to arm64 and prepares upstream targets with the same Rosetta host before initialization, rejects any pre-existing first-party compiled module, then compiles all Rill targets in Debug under extraction to avoid tracing dependency setup or release optimization; release packaging uses a fresh optimized build, preserving extraction and release provenance. Cache misses/eviction cause normal cold builds; no paid cache allowance is configured. The first main run seeds the primary cache; do not promise a warm-run duration until measured.

Generated-client validation uses the stable Ubuntu 24.04 image and selects an installed stable .NET 10 SDK, recording the version and pinning it per temporary C# fixture. Missing SDKs fail clearly; no rolling installer or blob-origin download is used. Python automation formatting runs in the fast planner job even when native work is unnecessary.

The old cold Intel job took about 32 minutes (15-minute release build, 5-minute compiler/package stage, 12-minute debug/test build), versus 14–16 minutes on Apple Silicon, with client validation waiting behind the matrix. The routine path removes Intel from the per-PR critical path; full compatibility runs remain available on demand. Timing depends on queue load, cache availability and toolchain/dependency changes.

Packaging and fresh-machine acceptance are described in [RELEASE.md](RELEASE.md). Record exact commit/artifact hash, OS/CPU and service versions for manual outcomes. MVP does not automatically mark partial capabilities verified.
