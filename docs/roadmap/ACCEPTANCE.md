# End-to-end acceptance journeys

Run these against freshly authored fixtures and temporary workspaces. A journey is completed only when it has linked automated evidence and, where relevant, a manual installed-app record for the exact commit. This is a checklist to implement, not a report of passing runs.

| Journey | Capability IDs | Exercise and expected outcome |
| --- | --- | --- |
| A01: Everyday workspace | WORK-01–WORK-06, EDIT-04–EDIT-05 | Create empty collection; add/rename/duplicate/move requests; reorder while filtered; open/pin/close/reopen tabs; restart. IDs, saved order, active selection and layout survive; deleting a collection shows count and cancel preserves data. |
| A02: Environment chain | WORK-07–WORK-09, AUTH-03, DYN-01 | Base → local → staging overrides and nested variable/secret references resolve correctly. Missing/cyclic references fail before send. Parent rename/delete retains intended child data. Generators are offline and range-checked. |
| A03: Editing and keyboard | EDIT-01–EDIT-05, UX-01–UX-02 | In light/dark/system modes, edit 100 KB JSON, duplicate keys, XML and templates. Format/search/wrap/zoom/undo preserve data and caret; completion accepts keyboard input. Cmd+N/T/W/K/Enter, Escape, ordering, focus and sidebar resizing work. |
| A04: HTTP fidelity | HTTP-01–HTTP-07, RESP-01 | Loopback server checks every method, existing encoded query/plus/space/fragment/repeated keys, header overrides and exact body bytes. Include structured forms, multipart text/JSON/file and binary streaming. Disabled fields never resolve or send; malformed fields fail clearly. |
| A05: Credentials and TLS | AUTH-01–AUTH-06, TLS-01–TLS-03 | Exercise Basic/Bearer/API key, named profiles, read-only process-environment secret fallback/precedence, Keychain lock/denial/missing secret, client credentials, PKCE state mismatch/cancel, valid/invalid custom trust, hostname mismatch and mTLS. No hidden insecure fallback; exports/logs follow redaction policy. |
| A06: Response and history | RESP-01–RESP-05, HTTP-07 | Inspect JSON/XML/HTML/image/text/binary, copy long headers and export original bytes. Compare semantically equivalent/different JSON. Test chunked/unknown/exact/oversized bodies, bounded previews, retained/truncated snapshots and opt-in durable history restart/deletion. |
| A07: Interchange and snippets | IO-01–IO-09, CODE-01–CODE-04 | Import fixtures for Rill, HTTPie Desktop and commands, cURL, Postman/environment, Insomnia v4/v5, HAR and Bruno file/folder/ZIP. Preview differences; reject unknown/lossy/hostile archives before mutation. Round-trip supported fields and compile/execute representative snippets without contacting the endpoint during generation. |
| A08: Chained run | TEST-01–TEST-02, RUN-01–RUN-05, SCRIPT-01–SCRIPT-04, DYN-01 | Create session → extract ID/header → read/update resource. Check all assertion types, pre/post hooks, signing, branch by ID/name/stop, iterations/delay/retries and stop/continue precedence. Failed post-hook changes never leak; environments stay unchanged. Empty/cancelled/failed runs fail meaningfully; portable reports contain no seeded secrets. |
| A09: Isolation and load | SCRIPT-05, RUN-03, RUN-06, PERF-01 | Attempt infinite loops, host/file/network/env/process access, oversized I/O/logs and resource exhaustion. Run isolated environment matrix and independently known percentile samples and ramp-up pacing. Enforce execution/body budgets, bounded concurrency, correct not-run outcomes and cancellation without leaking tasks. |
| A10: Definition lifecycle | SPEC-01–SPEC-07 | Import Swagger/OpenAPI JSON/YAML with folded/literal text, local refs/anchors/aliases and server variables. Generate requests/tests. Change operation/server/shared schema/example, preview refresh and preserve unchanged local edits and identity. Missing refs/headers or unsupported schema checks never silently pass. |
| A11: Simulation and inspection | MOCK-01–MOCK-02, SCAN-01–SCAN-02 | Generate/edit mock route, start/stop and handle port conflict. Assert configured route/body/status/headers. Run passive header checks without extra traffic; explicitly enable active probes and verify method restrictions, one-parameter probes, max-ten sample and cancellation. |
| A12: GraphQL and streams | GQL-01–GQL-04, STREAM-01–STREAM-02 | Query with variables/headers, introspect or handle disabled introspection, show schema and prefix completions. Exercise subscription init/ack/ping/pong, WebSocket fragmentation/binary and SSE named/id/data events. Bad handshake, malformed/oversized event, timeout, leave/view switch and cancel close resources. |
| A13: Request diagnostics and secrets | AUTH-03, RESP-03–RESP-04, CODE-04, RUN-04–RUN-05, SAFE-04, SHARE-02 | Seed distinguishable secrets in auth/header/query/body/environment/hook/error paths; inspect effective-request masking and each output policy. Portable reports/support/share must not contain disallowed values; raw local export/include-credentials paths require explicit disclosure/choice. |
| A14: Recovery under failure | BASE-02, SAFE-01–SAFE-04, WORK-05 | Force-terminate with an unsaved draft, recover latest successful checkpoint and preserve saved copy. Backup/restore through corrupt JSON, duplicate IDs/references, disk errors and hostile ZIP paths. Retain previous workspace and prevent stale editor overwrite; diagnostics contain no workspace content. |
| A15: Native protocols | GRPC-01–GRPC-05, MQTT-01–MQTT-03, KAFKA-01–KAFKA-02, AMQP-01, EVENT-01–EVENT-02 | Load proto/descriptors/well-known imports and reflection v1/v1alpha; exercise all four gRPC modes, metadata/deadlines and TLS/plaintext. Use real MQTT3/5 QoS0/1/2 TCP/TLS/WS brokers including negative acknowledgements, Kafka consume-latest/no-commit/ack publish/SASL, AMQP existing queues/ack/default exchange, and valid/invalid CloudEvents. Bound every timeline and close all sessions. |
| A16: Headless equivalence | CLI-01–CLI-05, RUN-05 | Execute the full CLI matrix below from a fresh temporary workspace without GUI. Compare desktop/shared-engine outcomes; assert exit codes, stdout/stderr redaction, reports, Ctrl+C, invalid arguments and missing inputs. |
| A17: Workspace integrations | SHARE-01–SHARE-03, PLUGIN-01 | Git status/init/commit only on explicit action; sanitized read-only share rejects wrong/missing tokens and does not publish history/profiles/secrets. Pull into explicit destination with validation. Discover/enable new native plugins only at defined trust boundaries; malformed descriptors fail clearly. |
| A18: Installed release | BASE-01, UX-01–UX-03, REL-01–REL-05 | Install signed/notarized/stapled app and CLI on every supported OS/CPU. Launch offline, upgrade existing data, confirm Keychain access and bundled compiler/runtime resources. Check VoiceOver, keyboard-only use, reduced motion, contrast and all layout sizes. Confirm versions/docs/notices/checksums and row-by-row sign-off match artifacts. |

## CLI command coverage matrix

Names below describe the reference commands to match functionally; the native CLI executable and naming may differ if documented. Alias compatibility is an explicit decision, not grounds to omit the operation.

| Family | Reference command/flag outcomes to cover | Gate |
| --- | --- | --- |
| Discovery | help/version, list, search | CLI-01–CLI-02 |
| Execute | run-request, run-collection, run-folder alias; environment/TLS/quiet; iterations/delay/retries/continue-on-failure | CLI-02, CLI-05 |
| Reports | JSON/Markdown/JUnit report path, Allure directory, unsuccessful empty/cancelled/failed result | CLI-05 |
| Recovery | backup, restore, diagnostics | CLI-02, SAFE-01–SAFE-04 |
| Interchange | collection-import | CLI-02, IO-02–IO-08 |
| API definition | openapi-list, openapi-import local/URL, openapi-refresh, contract-check | CLI-02–CLI-03 |
| API protocols | graphql endpoint/query/file/variables/headers; grpc target/method/proto/data/metadata/deadline/TLS | CLI-03 |
| Streams | sse headers; ws send/wait and cancellation | CLI-03 |
| Simulation | perf request/count/concurrency/environment; mock-serve port | CLI-03 |
| Inspection | history-diff exchange IDs | CLI-03 |
| Workspace | git-status, git-init, git-commit message; plugins | CLI-04 |
| Auth/sharing | oauth-client token endpoint/client/scope; share-serve bind/port; share-pull URL/token/destination | CLI-04 |

## Required evidence for closing a capability

1. Implementation PR and stable capability IDs; supported subset and resource/error behavior documented.
2. New independent tests for success, failure and cancellation/resource limits where applicable; protocol/parser conformance fixtures appropriate to the claim.
3. Relevant journey results, toolchain/OS/CPU/service versions and redacted evidence for any manual UI/Keychain/TLS/broker/package check.
4. Updated CSV status and verification links, regenerated readable register and successful roadmap audit. Approved deviations also link an owner-approved decision.

Do not use an aggregate passing-test count, mocked UI demonstration or feature-menu screenshot as substitute for behavior evidence.
