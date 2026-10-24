# Rill roadmap

Bring the new native macOS workbench to the capability breadth described in the supplied Relay 1.0.0 archive, while keeping Rill's implementation, visual design and architecture independent. This is a delivery plan, not a claim that the current app has those features.

Audited 2026-10-24 against Rill commit `abd4371`. The baseline is 122 capability rows, 173 production Java file entry points, 29 Java test files and 25 documentation/build/resource inputs. The source archive stays outside this repository. Only file names, hashes and requirement descriptions are recorded; no reference source, assets, test implementations or bundled dependencies are incorporated.

## Start here

- [Capability register](docs/roadmap/CAPABILITIES.md): every tracked requirement, current state, milestone, acceptance criteria and reference keys.
- [Editable checklist](docs/roadmap/capabilities.csv): machine-readable source of truth; one permanent ID per scope item.
- [Evidence inventory](docs/roadmap/reference-inventory.json): archive fingerprint, indexed paths/hashes and links from reference areas to capability IDs.
- [Parity boundaries and audit findings](docs/roadmap/PARITY-BOUNDARIES.md): limits and conflicts we must preserve or explicitly improve.
- [Acceptance journeys](docs/roadmap/ACCEPTANCE.md): cross-feature workflows that must work before the relevant milestone closes.

The inventory demonstrates that every scoped file has a roadmap owner. It does not prove that every behavior inside a file was reviewed or that Relay's release claims have been reproduced. Before implementing a row, inspect its reference area for overlooked edge cases, record new requirements under new IDs, and write fresh Rill tests. Discovery can expand the register; it must never silently shrink it.

## Current position

Rill has a SwiftUI workspace, basic HTTP request composition/execution, inherited environments, Basic/Bearer credentials in Keychain, status/body checks, Rill JSON import/export and session-only history. Its 72 automated tests and the GitHub macOS build/test workflow pass. The UI, installed app, Keychain prompts and advanced protocol interoperability have not been manually signed off.

This is a narrow foundation, not a percentage-complete implementation of Relay. Some apparent similarities are incomplete: a raw form-encoded body is not a structured form editor; selecting a GraphQL content payload is not an IDE; saving JSON is not a recoverable workspace; generic headers do not replace reusable API-key/OAuth/TLS tools.

Statuses are `planned`, `partial`, `verified`, or `deviation`. The initial audit marked no rows verified; current progress and evidence are tracked in the capability register and the [M0](docs/milestones/M0.md) and [M1](docs/milestones/M1.md) implementation records. A verified row needs linked code, automated behavior evidence and manual evidence where needed. A deviation needs owner approval and a documented replacement/omission with its user impact. A deadline or a release label cannot turn planned work into verified work.

## Delivery sequence

Milestones are scope gates, not calendar commitments. After each milestone's first implementation PR, estimate the remaining slices from actual complexity and test results. Each capability belongs to exactly one milestone in the checklist, even when its internal work spans several PRs.

| Milestone | Outcome | Prerequisites | Completion gate |
| --- | --- | --- | --- |
| M0 | Reliable foundation and governance | Current baseline | Persistence/cancellation/resource policy documented and exercised; required CI proposed/configured through explicit repo change; content-free diagnostics; independent implementation policy. |
| M1 | Daily workspace, editors and recovery | M0 | Collections, ordering, tabs/drafts, inherited environments, editing and crash/backup/restore journeys pass without data loss. |
| M2 | Complete HTTP, credentials and response inspection | M1 | Multipart/binary/form/auth/TLS, named secrets, inspectors and durable bounded history pass loopback and TLS fixtures. |
| M3 | Interoperability and code generation | M1–M2 | Every listed import/export family has fixtures, preview/warnings and loss-aware behavior; representative snippets compile or execute. |
| M4 | Repeatable tests and automation | M1–M2 | Extraction, collection runs, isolated hooks, dynamic values, reporting, matrix and performance journeys pass bounded deterministic fixtures. |
| M5 | Specifications, contracts, mocks and scanner | M2–M4 | OpenAPI refresh preserves local work; schema subset is explicit; generated tests/mocks and bounded opt-in scans pass. |
| M6 | GraphQL and live streams | M2; M4 execution primitives | Query/schema/completion/subscriptions, WebSocket and SSE lifecycle tests pass, including failure and cancellation. |
| M7 | gRPC and event brokers | M2; M6 lifecycle primitives | Four gRPC modes, MQTT versions/transports/QoS, Kafka, AMQP and CloudEvents have automated and real endpoint evidence. |
| M8 | Headless and workspace integrations | M1–M7 engines | Native CLI command matrix, Git, read-only sharing and plugin contract pass headless and isolation tests. |
| M9 | Native polish and distributable parity release | M0–M8 | Accessibility/manual target-Mac matrix, signed/notarized artifacts, offline docs and row-by-row capability sign-off complete. |

### M0 — Make the foundation trustworthy

Owner roles: platform/core maintainer and repository maintainer.

1. Establish one shared preparation/execution/outcome contract; give all long operations cancellation and ownership rules. Separate transport limits, preview limits and retention limits.
2. Validate loaded workspace references, migrations and concurrent writes; preserve unreadable originals and expose saving/recovery failures. Define the secret-bearing fields and default redaction policy.
3. Extend tests beyond known Content-Length to unknown/chunked/oversized payloads, stale selection races, invalid auth/header fields and error recovery. Add content-free diagnostics.
4. Preserve PR/history protection and the owner-approved administrator-bypass/one-review configuration; make the stable Swift CI job a required check as a separate repository-setting task. Add a supported toolchain/architecture test matrix after verifying runner availability.

Exit evidence: core invariants and resource policy, deterministic regression tests, CI success and diagnostic redaction fixture. Do not start a transport implementation that bypasses these shared primitives.

### M1 — Finish everyday workflows and recovery

Owner role: macOS product/UI maintainer with persistence support.

1. Finish collection lifecycle, request move/duplicate fidelity, saved drag/keyboard order, tabs/pins/reopen/session restore and global search.
2. Separate saved requests from drafts; add clear save/discard/cancel and undo/confirmation paths. Implement checkpoints, backup and transactional restore before expanding the workspace schema significantly.
3. Add environment inheritance and nested-variable resolution with cycle/missing-value handling, plus fresh request templates.
4. Build the editor controls: syntax/template styling, completion, search, zoom, wrap, lossless formatting and undo; persist layout and provide a wide side-by-side workspace option.

Exit evidence: acceptance journeys A01–A03 and A14, manual light/dark keyboard/focus checks and force-termination recovery. Autosave alone does not satisfy draft recovery.

### M2 — Finish HTTP, trust and inspection

Owner roles: transport maintainer and platform security/Keychain maintainer.

1. Lock down method/query/header/body semantics, structured forms, multipart streaming, binary uploads and repeated-header behavior; retain raw response bytes.
2. Add API-key/reusable auth profiles, named secret references, client-credentials OAuth, browser PKCE and custom trust/mTLS profiles. Test locked Keychain and certificate errors, not only successful auth.
3. Add format-specific safe response previews, raw/test/timeline/effective-request inspectors, persistent history controls and semantic comparison. Keep payloads and secrets out of portable reports by default.

Exit evidence: A04–A06 and A13; local HTTP/TLS/OAuth fixtures; Keychain prompts and signed-identity behavior manually checked. Clearly label any unsupported transport behavior instead of flattening it.

### M3 — Bring existing API work into Rill

Owner role: ecosystem/conversion maintainer.

1. Preview native Rill, cURL/HTTPie commands and HTTPie Desktop, Postman, Insomnia, HAR and Bruno inputs before a transactional import.
2. Implement export counterparts with format/version support tables; reject lossy auth/body conversions before writing. Retain foreign script source disabled only where representable; never promise foreign SDK compatibility.
3. Generate all requested client snippets from a single frozen prepared request without sending it. Validate escaping, credentials, exact multipart bytes and target-specific constraints with compiler/runtime fixtures.

Exit evidence: A07; a fixture per listed format/version/body/auth family, archive traversal/expansion tests and executable or compiled snippet samples. A successful JSON parse is not a successful migration.

### M4 — Make workflows executable and repeatable

Owner role: execution/runtime maintainer.

1. Add all declarative assertions/extractions and the ordered runner with iterations, pacing, explicit retries, stop/continue policy, meaningful empty/cancelled states and bounded outcome retention.
2. Implement independent opt-in hook APIs, isolated run-local variables, deterministic signing helpers, dynamic generators and branching. Choose the runtime only after proving isolation/resource controls; never embed the old Java engine.
3. Produce redacted JSON/Markdown/JUnit/Allure output from shared outcomes. Add environment matrix isolation and bounded load/percentile tools.

Exit evidence: A08–A09; adversarial infinite-loop/host-access scripts, retry/branch/cancel limits, secret-seeded reports, matrix isolation and independently checked percentile calculations. Keep clock/random sources injectable for tests.

### M5 — Close the specification feedback loop

Owner role: API definition/validation maintainer.

1. Parse OpenAPI/Swagger JSON/YAML with explicit limits; generate requests and store source identity/snapshots.
2. Refresh with a visible diff and transactional apply, retaining local edits for unchanged operations. Implement the published schema subset with explicit unsupported cases and bounded reference handling.
3. Generate linked positive tests and documented mock routes. Add local mock editing/start/stop, passive checks and explicit bounded active probes with clear target controls.

Exit evidence: A10–A11; source-refresh identity regression tests, schema subset conformance fixtures, mock behavior and exact scanner request-budget checks. Broader standards conformance remains a separate claim.

### M6 — Add interactive API sessions

Owner role: streaming/GraphQL maintainer.

1. Add GraphQL query/variables, schema loading/introspection and baseline prefix completion.
2. Implement generic WebSocket and SSE sessions with bounded parsers and event storage, teardown, cancellation and clear connection states.
3. Build GraphQL subscriptions with `graphql-transport-ws`, init/ack/ping/pong and cancellation on the shared lifecycle foundation.

Exit evidence: A12; deterministic servers exercise acknowledgement failure, malformed/fragmented/oversized messages, closure and switching views. Reconnect/replay behavior must be documented and tested rather than assumed.

### M7 — Complete protocol breadth

Owner role: protocol maintainer; each client is a separate PR series.

1. Record architecture/license/support decisions for native gRPC/protobuf and broker dependencies using current upstream evidence at implementation time. Avoid selecting library versions in this planning document.
2. Ship gRPC proto/descriptor/reflection and all four call modes, followed by MQTT 3.1.1/5 and TCP/TLS/WebSocket/QoS cases, Kafka consume/publish/auth and AMQP existing-queue flows.
3. Add structured CloudEvents and consistent event controls. Reuse bounded lifecycle outcomes without forcing every protocol into an HTTP request model.

Exit evidence: A15; real local brokers/services plus scripted wire-level rejection/ack/fragmentation tests; verify packaging on every claimed architecture. Real broker interoperability is a release gate, not inferred from fake timelines.

### M8 — Expose the engines outside the main window

Owner roles: tooling/integrations maintainer and platform maintainer.

1. Publish a new native CLI around the engines already delivered. Keep transport and run logic out of command parsing; cover every command family in A16.
2. Add explicit workspace Git operations, sanitized token-protected read-only sharing and safe share pull/import.
3. Define a native local plugin/extension contract with descriptor listing and service registration. Decide trust and enablement boundaries explicitly; compatibility with Java plugins is not required.

Exit evidence: A16 plus A17; headless subprocess tests verify outputs, report files, cancellation and exit codes; sharing tests reject missing/wrong tokens and prove history/profile/secret exclusion.

### M9 — Deliver a native product, not a feature inventory

Owner roles: macOS/release maintainer and capability reviewer.

1. Audit VoiceOver, keyboard-only use, focus, reduced motion, code scaling, light/dark contrast and compact/wide layouts. Write offline help and public API docs alongside features, then reconcile all visible controls with actual support.
2. Package app/CLI/runtime/compiler resources, new icon and DMG; sign nested executables, notarize/staple and test installed offline launch/upgrades/Keychain behavior. Validate every supported macOS/CPU claim on actual artifacts.
3. Review all 122 rows individually. Close each with implementation/test/manual evidence or owner-approved deviation. Run every acceptance journey and audit release metadata, notices and checksums.

Exit evidence: A18 and a release sign-off record linked to the exact commit/artifacts. No parity release while any baseline capability remains planned/partial without an approved explicit deviation.

## Implementation architecture and PR workflow

Keep serializable workspace/run models independent of SwiftUI. Introduce cohesive modules as needed for workspace persistence/migrations, transport sessions, auth/secrets, runners/hooks, API specifications and import/export. Desktop and CLI consume the same services. Avoid a single growing view/store or a service that knows every protocol.

Each implementation PR references capability IDs and includes behavior, new tests, manual evidence where appropriate, documentation and any changed limits. Update checklist status and readable register in the same PR. No reference test source is reused: its named scenarios guide newly authored fixtures and assertions. Before choosing a protocol/parser/runtime dependency, record its maintained upstream, license, Swift/macOS/CPU compatibility, update strategy and failure/resource behavior in a new decision note.

A reviewer must check the relevant evidence group, not just its headline row. If another behavior is found, add a new ID and milestone. Do not delete a row to make a milestone appear complete. Any intentional behavioral difference stays visible in the register and boundaries document.

## Beyond baseline parity

These are candidates to scope separately, not capabilities verified in the Relay archive: schema-aware GraphQL completion, negative/boundary contract-case generation, wider schema conformance, deeper converter fidelity, managed cookie jars/proxy controls, richer protocol security/admin tools and update distribution. Backlog them after the baseline is accounted for; they do not justify postponing recovery, correctness or accessibility.

## Keep the plan auditable

```sh
python3 scripts/audit-roadmap.py
# Optional, with the separately retained original archive:
python3 scripts/audit-roadmap.py --archive /path/to/relay.zip
# After editing the CSV:
python3 scripts/audit-roadmap.py --render
```

The audit checks IDs, milestone/status vocabulary, evidence ownership, generated-register consistency and local evidence paths. With the archive it additionally checks the exact fingerprint, full scoped inventory and per-file hashes. It cannot establish behavioral completeness or safety; acceptance evidence and human review do that.
