# Roadmap: CLI-first API testing

Updated 30 October 2026. **This is a proposed delivery plan, not a list of shipped features or promised dates.** Current behavior is documented in [features and limits](docs/FEATURES.md) and the [CLI guide](docs/CLI.md).

Rill has reached an MVP development milestone. The next goal is a fast, local API testing workflow that moves from a collection file to a trustworthy CI result with minimal setup. Prioritize reproducibility, useful failure explanations and smooth migration over accumulating protocol names.

## 1.0 scope and release-critical sequence

The owner selected **local API development and CI first** on 29 October 2026. Hosted team collaboration and Linux/Windows desktop applications are outside this first release target. The existing desktop/CLI is macOS-only; portable CLI support requires its own proof before Linux or Windows CI can be advertised. Do not call this unrestricted parity with every Postman/HTTPie product surface.

The [capability audit](docs/1.0-CAPABILITY-AUDIT.md) and its [122-row inventory](docs/1.0-capability-audit.csv) separate implementation starting points from unclosed acceptance. The preserved baseline remains 3 verified, 118 partial and 1 governance deviation; partial is not a count of absent features.

Deliver focused PRs in this order, reusing the shared engines:

| Gate | Concrete outcome | Evidence required before closing |
| --- | --- | --- |
| G0 — Daily-workbench reliability | Contained selectors, stable panes, reliable drafts/imports and keyboard flow | Compact/wide light/dark native checks, persisted choices, Escape/click-away, recovery/upgrade and owner accessibility acceptance. Fix regressions before adding more protocols. |
| G1 — File-based execution | `run collection.json` without desktop setup; explicit unsupported-feature diagnostics | Ordered/nested Postman v2 requests, collection/environment/override precedence, scripts blocked before traffic, no source/workspace/Keychain mutation, cancellation and reports. Then add supported native inputs and complete acceptance. Reference roadmap CLI-01/02/05 and original CLI/RUN/IO IDs. |
| G2 — Reproducible headless inputs | Iteration data, process secrets and file-based TLS usable in documented CI environments | JSON/CSV and empty/disabled variable cases, reproducible order, mTLS/custom CA/redirect boundaries, redaction and paths with spaces. Existing RILL_SECRET_ support is reused. CLI-02/03 and AUTH/TLS acceptance apply. |
| G3 — Workflow compatibility | A published supported script/variable/assertion/chaining subset that behaves as documented | COMPAT-02 architecture decision before a foreign runtime; worker resource/host-access limits if selected; pinned differential corpus for order, mutations, requests and exit status. Unsupported behavior cannot look successful. |
| G4 — HTTP session and investigation depth | Explicit cookie/login chains, useful offline reports and repeatable comparisons | Domain/path/secure/expiry/isolation tests and no ambient cookie leakage; escaped hostile-content HTML reports; baseline/run drift scenarios; preserve existing reports. Cookie/session work is a new delivery item, not an already completed original capability. |
| G5 — Acceptance and distribution | Installable, reproducible 1.0 artifacts with an honest capability matrix | Review all original rows with behavior evidence or explicitly approved scope deviations, independent real-service cases, measured 600/5,000-request baselines, installed macOS/CPU coverage, exact-source security gates, provenance and explicit signing status. No version-only promotion. |

Mock discoverability/lifecycle follows the first reliable file-run/compatibility increments, reusing the existing server. Existing GraphQL/gRPC/broker capabilities remain supported acceptance work; this scope does not remove their criteria or promote synthetic fixtures into interoperability evidence. WorkbenchStore decomposition remains a measured maintenance task, not a prerequisite for each user-visible fix.

Development source now implements the first **G1 conservative direct Postman v2 file-run** increment with whole-input preparation, explicit HTTP 2xx checks, transient secrets, environments/overrides, reports and cancellation. Scripts and unsupported inputs block before traffic. Exact nested Postman folder selection now preserves source order and inherited checks in both run and preflight. G1 remains open for native inputs and complete acceptance; data/TLS and compatibility depth follow. The gates above add a release order to the milestone details below; they do not mark their unchecked tasks shipped. A PR, passing CI and documented behavior establish an increment; release evidence closes shipping status.

## At a glance

| Order | Milestone | User outcome | Status |
| --- | --- | --- | --- |
| 1 | CLI file runner and migration diagnostics | Run collection/environment files without importing into a desktop workspace | In progress: preflight and conservative Postman file runs |
| 2 | Workflow compatibility and trustworthy reports | Understand which scripts work and why a run passed or failed | Planned |
| 3 | First-class mock workbench | Find, edit and run local mocks directly from the app or CLI | Planned |
| 4 | Performance and failure investigation | Keep large workspaces responsive and compare repeatable runs | Planned |
| 5 | Linux CLI and CI distribution | Run HTTP suites and mocks in Linux CI without a Mac | Discovery required |
| 6 | Windows CLI and desktop portability decision | Native Windows automation, followed by an evidence-based GUI decision | Discovery required |

Milestones are delivery groups, not a promise to fit each into one PR. Use independently reviewable PRs within each group. Mark work in progress only after an implementation PR exists; mark it shipped only with tests, documentation and release evidence. Keep this file authoritative; the Wiki and roadmap discussion link here rather than duplicating its task list.

## 1. CLI file runner and migration diagnostics

- [ ] **CLI-01 — Direct file runs.** Add `rill run collection.json` for supported Postman and native formats, with an isolated temporary workspace. No writes to the desktop workspace and no mandatory GUI setup. Support explicit collection/folder selection and preserve nested folder order.
- [ ] **CLI-02 — Environment and data inputs.** Add `--environment-file`, repeatable `--env-var key=value`, globals, JSON/CSV iteration data and optional final-environment export. Document deterministic precedence, disabled values, empty values, missing-variable errors and opt-in secret export. Preserve existing saved-workspace commands.
- [ ] **CLI-03 — Headless TLS.** Add client certificate/key/PKCS#12, passphrase-file, custom CA and explicit insecure options. Validate matched identities; support certificate selection per destination and define redirect/hostname behavior. File runs must not require importing identities into a personal Keychain. Never print private keys or passphrases.
- [ ] **CLI-04 — CLI installation and discoverability.** Shell completion, permanent install guidance, `doctor`, useful per-command help, actionable errors and CI-friendly exit codes. Provide a CLI-only macOS archive; evaluate Homebrew after reproducible standalone packaging works.
- [ ] **CLI-05 — Explain before sending.** Add a validation/dry-run mode that reports unsupported imports/scripts, unresolved inputs, selected environment and redacted execution plan without sending requests. Unsupported behavior must not produce a misleading success.

Ad-hoc development-source increment: `rill request METHOD URL` sends a single request through the shared HTTP engine, with temporary variable overrides and explicit optional saved profile selection. This addresses one-off calls without fulfilling CLI-01 direct collection-file execution.

First CLI-01/02 increment: development source provides conservative Postman v2 `run` with environment files, overrides, whole-input preparation, explicit HTTP 2xx checks, reports and cancellation. Multipart/file bodies and foreign scripts block; Exact nested Postman folder selection now works in run/preflight; native inputs, data and headless TLS remain open.

First CLI-05 increment: development source provides offline Postman `preflight` with redacted script/variable/import diagnostics and optional unencrypted PEM pairing/expiry inspection. It does not send requests, produce a full execution plan or establish Newman compatibility. The complete file-run milestone and other items remain open.

Acceptance: a sanitized suite shaped like the owner's 600-request collection runs from collection/environment files with four temporary variable overrides, mTLS and a simultaneous terminal/JSON report. Test from paths with spaces, without the desktop app running, and verify input files and personal workspace remain unchanged. Never publish the owner's collection, internal endpoints, environment or certificates as fixtures.

### Full target command shape — not yet supported

```sh
rill run ./collection.json   --environment-file ./environment.json   --ssl-client-cert ./client.crt   --ssl-client-key ./client.key   --insecure   --env-var runLinks=true   --env-var runDelivery=true   --env-var runManagementExtras=true   --env-var runCleanup=true   --detail   --report ./results.json --report-format json
```

Option names are provisional. A file runner is not sufficient for Newman equivalence: the suite's scripting and execution semantics must also satisfy milestone 2.

## 2. Workflow compatibility and trustworthy reports

- [ ] **COMPAT-01 — Published compatibility inventory.** Detect collection/folder/request script inheritance; report every supported, translated and unsupported construct with its location. Current foreign scripts are retained as source, not executed as Postman JavaScript.
- [ ] **COMPAT-02 — Explicit execution strategy.** Evaluate bounded translation to native workflows versus an optional isolated JavaScript worker. Publish an ADR covering portability, dependency size, runtime limits and failure semantics before choosing. No unrestricted evaluation inside the app process.
- [ ] **COMPAT-03 — Priority suite semantics.** Scope the supported subset around variable scopes and mutation, pre-request/test ordering, assertions, extraction, conditional skip/branching and request chaining. Async requests, external libraries and arbitrary Node APIs are separate compatibility decisions, not implicit promises.
- [ ] **COMPAT-04 — Differential conformance.** Compare synthetic suites against a pinned Newman version using the same local server. Match request order/count, enabled/disabled requests, variable resolution, skipped cases, assertion outcomes and exit status. Unsupported scripts fail validation by default; explicit omissions remain visible in reports and cannot be described as full compatibility.
- [ ] **REPORT-01 — Better failure investigation.** Stable machine report schema with versioning; failure-only detail, source location, expected/actual values with redaction, retry history, timings and copyable reproduction commands. Add NDJSON events and retain existing JSON/JUnit/Markdown/Allure exports.
- [ ] **REPORT-02 — Shareable local HTML report.** Offline report with suite/folder navigation, filters, timing charts and response diffs. Escape all server-controlled content; bound retained data and make payload inclusion explicit.
- [ ] **REPORT-03 — Reproducible CI runs.** Config files, deterministic seeds, total/request/script deadlines, cancellation, fail-fast/continue policies, explicit update/overwrite behavior, GitHub Actions annotations and reusable CI examples. Credentials and input files must work without interactive prompts.

Acceptance: a run with unsupported scripts cannot look green; intentional assertion, transport, timeout and configuration failures remain distinguishable. Verify reports with hostile HTML/control characters and secrets. Do not publish a Newman compatibility percentage without a defined corpus and denominator.

## 3. First-class mock workbench

**Already available:** app menu **Request → API Definitions / Contracts / Mocks… → Mocks**, plus CLI `mock-serve --routes FILE`. The current UI edits route JSON, binds to loopback and stops its server when the tool window closes. This milestone improves discoverability and capability; it does not add a second mock engine.

- [ ] **MOCK-01 — Dedicated navigation.** Add a visible Mocks entry, persistent saved mock projects, an empty-state walkthrough, route forms with JSON editing, start/stop controls, running status and copyable base URL/cURL.
- [ ] **MOCK-02 — Predictable lifecycle.** Keep a mock running when its editor closes; stop on explicit action or app termination. Surface port conflicts, running servers and unsaved changes. No implicit background daemon or automatic exposure to LAN.
- [ ] **MOCK-03 — Useful responses.** Request matching by method/path/query/header/body; ordered scenarios, seeded examples, latency/error injection and bounded request journals. Define unmatched-route behavior and deterministic reset. Bound concurrent connections, journal retention and payload sizes.
- [ ] **MOCK-04 — Contracts and fixtures.** Generate routes from supported OpenAPI examples and saved responses, validate fixture structure, and replay sanitized recordings. Record provenance and redact credentials before saving; interactive examples are not proof of full schema conformance.
- [ ] **MOCK-05 — One app/CLI format.** Export/version the same route/project definition; CLI readiness output, ephemeral port discovery, CI teardown and reset controls. Request matching and scenario results must agree across app and CLI.

Acceptance: create and run a mock without discovering a hidden submenu, close its editor while requests continue, inspect calls, reset a scenario, export it and reproduce the same behavior with the CLI. Exercise port collisions, cancellation, oversized requests and process termination.

## 4. Performance and features that earn repeat use

- [ ] **PERF-01 — Establish baselines first.** Reproducible 600/5,000/10,000-request workspaces, many tabs, large bounded responses and scripted suites. Measure cold/warm startup, metadata commands, import/validation time, search, tab operations, memory, request overhead and report generation. Record reference hardware/OS, release build, warm/cold conditions and distributions.
- [ ] **PERF-02 — Responsive desktop.** Profile main-thread work; use incremental indexing, lazy editor/response construction, batched state updates and bounded history. Regressions must cover the previously slow Close All Tabs action and the installed-resource launch crash.
- [ ] **PERF-03 — Efficient runner.** Reuse connections and compiled plans where safe, stream large reports and avoid retaining duplicate bodies. Bound concurrency; preserve sequential workflows by default. Parallel execution requires explicit isolation and deterministic reporting.
- [ ] **PERF-04 — CI/build speed.** Measure critical paths, cache toolchains/dependencies using explicit keys, cancel stale PR runs and separate docs checks from native compilation. Preserve exact-source release tests, installed GUI checks, vulnerability scans and deep release analysis.
- [ ] **DIFF-01 — Run comparison.** Baseline versus current run: status/assertion changes, schema drift, normalized JSON/header diffs and latency changes. Configurable ignore rules and clear treatment of missing data.
- [ ] **FLOW-01 — API change workflow.** OpenAPI change review → impacted requests → generated examples/mocks → contract run → local report. Reuse current definition, contract and mock support rather than replacing it.
- [ ] **FLOW-02 — Better migration and reproducibility.** Portable text-oriented project files, semantic diffs, read-only discovery, import previews and exact file/line diagnostics. Evaluate HTTPie interoperability against documented exports; do not claim to reproduce its complete app behavior.

Initial performance targets are hypotheses to calibrate after PERF-01: p95 warm metadata listing under 200 ms for 600 requests; p95 search/close-all interaction under 100 ms of main-thread work; no more than 20% regression in stable reference benchmarks. Publish workload, throughput, latency and memory together. Do not claim to beat Postman/Newman/HTTPie until comparable public benchmarks substantiate it.

## 5–6. Linux and Windows: CLI first, desktop separately

Swift supports Linux and Windows, but today's Rill core is not portable: it imports Darwin, Security, Network and CryptoKit, uses macOS Keychain identities and an Apple Transport Services gRPC transport, and links the CLI to a broad protocol dependency graph. The desktop also uses SwiftUI/AppKit. Changing `Package.swift` alone will not port it.

- [ ] **PORT-01 — Time-boxed spike and architecture decision.** Spend 3–5 engineer-days identifying target/dependency blockers and proving an HTTP request, TLS verification, local mock and filesystem operation on Ubuntu and Windows. Choose initial supported OS/CPU versions and measured distribution costs.
- [ ] **PORT-02 — Portable HTTP/runner foundation.** Split portable models, importers, runner, reporting and CLI from Apple adapters and optional brokers/gRPC. Abstract process/filesystem/signals, credential providers and transport capabilities. Select portable networking/crypto deliberately; preserve TLS behavior and redaction.
- [ ] **PORT-03 — Linux CLI preview.** Start with Ubuntu x86_64 HTTP collection runs, supported scripts, reports, mTLS and local mocks; then arm64 and an OCI image. Automated Linux conformance tests, artifacts, provenance and installation guidance are required before claiming support.
- [ ] **PORT-04 — Native Windows CLI preview.** Windows x86_64 executable, PowerShell quoting/UTF-8/paths, cancellation, proxy/CA/mTLS behavior and CI. WSL is a useful Linux delivery option, not native Windows support.
- [ ] **PORT-05 — Desktop decision after CLI evidence.** Compare a shared web UI over a local engine, a maintained cross-platform toolkit, and native shells. Prototype editor performance, accessibility, packaging, updates and secure IPC. Keep the native Mac experience while evaluating; do not promise a SwiftUI recompile for Linux/Windows.

### Planning estimates, not delivery commitments

Assume one experienced full-time engineer, existing Swift tests reused, supported HTTP workflow subset first, normal review/QA/docs included, no cloud collaboration or wholesale protocol parity. These are engineering judgments with roughly ±50% uncertainty until PORT-01; parallel contributors do not reduce calendar time linearly.

| Work | Incremental effort |
| --- | --- |
| Shared portability foundation | 4–6 engineer-weeks |
| Linux HTTP CLI preview after foundation | 3–5 engineer-weeks |
| Native Windows HTTP CLI preview after foundation | 4–7 engineer-weeks |
| Both CLI previews, shared foundation counted once | **11–18 engineer-weeks total** |
| Broader broker/gRPC/credential-provider parity across both OSes | Additional 8–16 engineer-weeks; dependency feasibility unproven |
| Desktop apps on both OSes after CLI foundation | Additional 24–40 engineer-weeks for shared UI, integration and platform QA; re-estimate after UI prototype |

Recommended sequence: strengthen the Mac CLI → Linux CI runner → Windows CLI → decide whether user demand justifies cross-platform desktop work. Portability discovery can overlap the early CLI work; GUI implementation should not delay a reliable command-line runner.

## What would make users choose Rill?

1. **Lower migration effort:** file-based runs with explicit compatibility diagnostics instead of finding silent omissions after CI goes green.
2. **Local, reproducible work:** app, CLI, mocks and reports share one engine and portable inputs, without requiring an account or hosted workspace.
3. **Faster investigation:** failures explain location and cause, and runs can be compared or reproduced from a report.
4. **Measured responsiveness:** large workspaces remain usable and the CLI adds little overhead; publish evidence rather than performance slogans.
5. **Focused scope:** improve these workflows before pursuing hosted collaboration, AI-generated tests, plugin marketplaces or more protocol breadth. Reassess those from demonstrated demand.

These are proposed advantages to prove, not claims that competing tools lack local storage, CLI runners or mocks. Newman already supports file/environment/certificate/report flags; HTTPie documents local storage and collection variables. See [Newman options](https://learning.postman.com/docs/collections/using-newman-cli/newman-options), [HTTPie desktop documentation](https://httpie.io/docs/desktop), and [Swift platform support](https://www.swift.org/platform-support/).

## Delivery and acceptance policy

Continue fresh-install/upgrade/recovery, Keychain, real-provider interoperability, keyboard/VoiceOver and supported-window acceptance alongside these milestones. Keep per-architecture macOS packaging/provenance and the relocated release-app launch regression gate. Paid Developer ID signing/notarization remains deferred at the owner's request.

Preserve the [122 original capability criteria](docs/CAPABILITIES.csv); this roadmap does not change partial/verified/deviation states into sign-off. Each enhancement needs an issue or PR referencing its ID, fixtures, relevant performance evidence, help/documentation updates and explicit limitations. Roadmap checkboxes describe shipped enhancements only after review, CI and release evidence. Feature requests can be proposed in [Discussions](https://github.com/alby-raju/Rill/discussions); implementation bugs belong in [Issues](https://github.com/alby-raju/Rill/issues).
