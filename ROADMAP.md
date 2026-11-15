# Roadmap: CLI-first API testing

Updated 15 November 2026. This roadmap lists pending implementation and acceptance work. See [features and limits](docs/FEATURES.md) and the [CLI guide](docs/CLI.md) for current behavior, and the [capability audit](docs/1.0-CAPABILITY-AUDIT.md) for implementation history.

## 1.0 scope and release-critical sequence

Prioritize local API development and CI on macOS. Hosted team collaboration and Linux/Windows desktop apps are outside the 1.0 scope.

| Gate | Remaining acceptance |
| --- | --- |
| G0 — Daily-workbench reliability | Verify selectors, keyboard and dismissal behavior, layouts in light/dark and compact/wide windows, persisted choices, draft recovery, upgrades and owner accessibility. |
| G1 — File-based execution | Run the independent installed suite for Postman and native files. Verify selection, precedence, fail-closed preflight, cancellation and reports without mutating inputs, the desktop workspace or Keychain. |
| G2 — Reproducible headless inputs | Verify the owner-suite workflow from paths with spaces using JSON/CSV data, empty and disabled variables, four temporary overrides, real-service mTLS/custom CA, redaction and simultaneous terminal/JSON reporting. |
| G3 — Workflow compatibility | Extend the pinned Newman comparison and independently verify script order, variable mutation, request order and exit status. |
| G4 — Session and investigation | Independently verify realistic login chains, cookie isolation and expiry, hostile-content report escaping, baseline drift diagnosis and reproducible CI runs with scoped inputs and deadlines. |
| G5 — Acceptance and distribution | Close the original acceptance criteria with behavior evidence or approved deviations. Verify fresh installs, upgrades, recovery, real services, performance baselines, architecture-specific packaging and provenance, and exact-source security gates. |

## 1. CLI file runner and migration diagnostics

- [ ] **CLI-04 — CLI installation.** Verify standalone installation and shell integration on both macOS architectures and evaluate Homebrew distribution.

## 2. Workflow compatibility and trustworthy reports

- [ ] **COMPAT-01 — Construct-level diagnostics.** Use grammar-aware classification for supported, translated and unsupported script constructs, with source coordinates. Verify the inventory independently.
- [ ] **COMPAT-04 — Differential conformance.** Expand the pinned Newman corpus and compare independent workflows on matched fixtures, including scripts that must block before traffic.
- [ ] **REPORT-01 — Failure investigation.** Add safe expected/actual details where redaction permits and copyable reproduction commands for supported failures.
- [ ] **REPORT-02 — Shareable local HTML report.** Add explicit, bounded and safely escaped response diffs to the offline report.

## 3. First-class mock workbench

- [ ] **MOCK-04 — Sanitized recording replay.** Validate and replay recorded fixtures with provenance and credential redaction.
- [ ] **Independent mock acceptance.** Verify installed-app discovery, editor-independent lifecycle, port conflicts, oversized requests, scenario reset, and equivalent replay from an exported project in the CLI.

## 4. Performance and features that earn repeat use

- [ ] **PERF-01 — Remaining baselines.** Measure native interaction, many-tab and script-heavy workloads, and compare matched workloads against independent reference measurements.
- [ ] **PERF-02 — Responsive desktop.** Profile and address main-thread bottlenecks in collection indexing, editor/response construction and history updates. Cover Close All Tabs and installed-resource launch in regression checks.
- [ ] **PERF-03 — Efficient runner.** Extend connection reuse and stream the remaining buffered report formats. Evaluate bounded concurrency with isolation and deterministic reporting.
- [ ] **FLOW-01 — API change workflow.** Connect reviewed OpenAPI changes and impacted requests to generated examples and mocks, then verify the linked contract-run and report workflow.
- [ ] **FLOW-02 — Migration and reproducibility.** Extend text-oriented project files, semantic diffs, read-only discovery and exact file/line diagnostics.

Calibrate the initial performance targets against the remaining baselines. Measure p95 warm metadata listing at 600 requests against 200 ms, p95 search and Close All Tabs interaction against 100 ms of main-thread work, and stable benchmark regressions against 20%. Publish workload, throughput, latency and memory together.

## 5–6. Linux and Windows: CLI first, desktop separately

- [ ] **PORT-01 — Portability spike.** Identify framework and dependency blockers and prove HTTP, TLS verification, local mocks and filesystem operations on Ubuntu and Windows. Choose initial OS and CPU targets.
- [ ] **PORT-02 — Portable HTTP/runner foundation.** Separate portable models, importers, runner, reporting and CLI from Apple adapters and optional protocols. Choose portable networking, crypto, credential, filesystem and signal adapters.
- [ ] **PORT-03 — Linux CLI preview.** Deliver Ubuntu x86_64 HTTP collection runs, supported scripts, reports, mTLS and local mocks, then arm64 and an OCI image. Add conformance tests, provenance and install guidance.
- [ ] **PORT-04 — Native Windows CLI preview.** Deliver Windows x86_64 builds with PowerShell quoting, UTF-8 and path handling, cancellation, proxy/CA/mTLS support and CI verification.
- [ ] **PORT-05 — Desktop portability decision.** After CLI evidence, compare a shared web UI, a cross-platform toolkit and native shells. Prototype editor performance, accessibility, packaging, updates and secure IPC.

## HTTPie comparison plan

Use HTTPie Terminal 3.2.4 and documented desktop workflows as the references. [HTTPie Terminal](https://httpie.io/docs/cli/usage) · [HTTPie Web and Desktop](https://httpie.io/docs/desktop)

| Order | Pending work | Evidence |
| --- | --- | --- |
| 1. Terminal requests | Evaluate opt-in cross-origin redirects and richer hop details. Verify TLS-wrapped proxies with a trusted external service and compare long-lived streams, resumable downloads and encrypted session behavior with an independent terminal workflow suite. | Compare request bytes, output, exit status and saved state against the same loopback fixtures. Verify transport and credential isolation independently. |
| 2. Desktop workflows | Add live request preview, selective HTTPie import/export and broader workspace round-trips. Improve variable navigation, keyboard flow, accessibility and large-response inspection. | Compare task completion and errors in installed apps, with exact OS, CPU and build versions. |
| 3. Repeatable API testing | Promote an ad-hoc request to a test and verify a continuous workflow from reviewed OpenAPI requests to generated mocks, contract runs and baseline comparison. | Reproduce a request or response change in CI and locate it from the failure report. |
| 4. Distribution and ecosystem | Prove Linux and Windows CLI install and upgrade workflows. Evaluate FreeBSD, cross-platform desktop, browser access, optional sync and extensions separately. | Run the same workflow suite on each supported platform. |

## Delivery and acceptance policy

Use focused PRs with fixtures, relevant performance evidence, and help and documentation updates. Preserve the [122 original capability criteria](docs/CAPABILITIES.csv) and their independent acceptance states. Verify both macOS architectures, relocated app launch and provenance at release. Keep the owner's workspace and credentials out of published fixtures.
