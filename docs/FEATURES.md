# Features and supported limits

This describes the MVP's implemented scope. Automated tests and an implemented control do not establish complete standards conformance or fresh-machine/provider acceptance. The [capability checklist](CAPABILITIES.csv) retains individual acceptance criteria; use the [manual kit](../verification/README.md) to exercise workflows.

## Everyday API work

| Area | Available | Boundaries |
|---|---|---|
| Workspace | Collections, request CRUD/copy/move/order within and between collections, search, tabs/pins/reopen, separate drafts, inherited environments, checkpoints and backups | Checkpoints can lose edits since the last successful write. Closed-tab history retains the last 20 tabs. Backups omit credentials. |
| Tab controls | Close one/all/left/right, one bulk Save All/Discard Changes/Cancel prompt | Explicit bulk actions include pinned tabs. Closing never deletes saved requests; Cancel keeps the whole target set open. |
| Editors | Native undo, find, wrap, zoom, JSON/template styling/completion and lossless JSON formatting | Completion is not a language server. File uploads require local reselection if identity/size/time changes. |
| HTTP | GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS, repeated query fields, headers, raw/form/multipart/binary bodies | GET/HEAD payloads are rejected by this transport. Header/body representability is validated before send. Redirects are same-origin only; timeout is 1–300 seconds. |
| Authentication | Basic, Bearer, header/query API key, reusable profiles, named Keychain secrets, client-credentials OAuth and browser PKCE | Providers may have additional requirements. CLI OAuth is client credentials; PKCE remains desktop/browser-assisted. |
| TLS | System trust, custom DER/PEM anchors and local Keychain client identities | No silent insecure fallback. Explicit insecure profiles need per-send confirmation; CLI also requires `--allow-insecure`. OAuth uses its separate system-trust transport. |
| Inspection | JSON/XML/HTML-source/text/binary/raster previews, headers, checks, effective request, transport timeline, export/history/semantic comparison | HTML scripts/resources never execute. HTTP status and configured validation are distinct. Timing is total/milestone timing, not separately measured DNS/connect/TLS phases. |

Default bounds include a 32 MiB workspace, 16 MiB HTTP response, 512 KiB preview, 32 MiB/50-entry session history and bounded durable snapshots. Preview and retention limits are distinct from transport acceptance; truncation must remain visible. Explicit raw exports can contain sensitive data.

## Ad-hoc CLI requests

Development source supports `rill request METHOD URL` with no workspace setup, repeated header options, UTF-8 body text/files, temporary variable overrides, and explicit raw response export. Saved environments/auth/TLS profiles require an explicit workspace. The shared HTTP engine retains TLS verification, redirect rules, response bounds and unsupported GET/HEAD-body/repeated-header checks. Summaries omit payloads and credentials. See the [CLI guide](CLI.md).

## Direct collection-file execution

Development source supports `rill run COLLECTION.json` for a conservative Postman v2 JSON subset. It prepares the whole selected collection/folder before traffic, uses transient credentials and the shared collection/workflow engines, and supports environment files, temporary overrides, retries, reports and cancellation. Every request has an explicit HTTP 2xx check; scripts, unsupported transport representations and multipart/file bodies block. An exact `--folder` path selects a nested subtree while retaining ancestor auth/script/transport checks; excluded folders are not checked. No personal workspace or Keychain import is required. This is not script compatibility or a native/CSV/TLS-file runner. See the [CLI guide](CLI.md).

## Runs, contracts and interchange

- **Workflow:** status/header/body/JSON assertions, transactional extraction, iterations/pacing/retries, same-collection branching/stop, environment matrix isolation and bounded load metrics. Recovered retries pass the final visit while earlier failed attempts remain visible.
- **Hooks:** opt-in `json-operations-v1` supports finite set/request/header/body/condition/assert/branch/log/crypto/clock/UUID operations. It is not JavaScript or a foreign SDK. Source is capped at 256 KiB, nesting at 16, operations at 1,024, logs at 32/16 KiB, with bounded values and cooperative execution checks. This is not an OS sandbox.
- **Reports:** redacted JSON, Markdown, JUnit and Allure results. Allure needs an external viewer; no HTML dashboard is bundled. Empty/cancelled/exhausted runs cannot pass.
- **Definitions:** Swagger 2/OpenAPI 3 JSON/YAML, local references, request/positive-contract generation and identity-preserving previewed refresh. External references are not fetched automatically.
- **Schema:** an explicit subset of type/required/properties/additionalProperties, enum/const, array items, numeric/string/array/object limits, nullable, allOf/anyOf/oneOf and local JSON Pointer references. Unsupported rules must not silently pass; full dialect conformance is not claimed.
- **Mocks/inspection:** editable loopback route/status/header/body mocks, passive header indicators and separately enabled bounded active probes. This is not full DAST or proof that an endpoint is secure.
- **Formats:** native Rill; cURL/HTTPie commands; HTTPie Desktop 1.0.0; Postman v2.0/v2.1 collections/environments; Insomnia v4 JSON/v5 YAML; HAR; Bruno `.bru` file/folder/ZIP. Support differs by representation. Scoped variables, uncommon auth/body variants, cookies, plugins, transport settings and scripts may warn or reject. Bruno OpenCollection YAML is not implemented. File references are not attached files. Postman unselected upload placeholders are retained with warnings; enabled uploads require local file selection before Send.
- **Client generation:** cURL/HTTPie plus Python requests/httpx, Node fetch/axios, Java HttpClient/OkHttp, Go, Rust and C#. These are frozen-request source programs, not installed SDKs or universal wire-equivalence guarantees. Some header/body/TLS combinations reject explicitly; review generated source before sharing or execution.

## Live and broker protocols

| Tool | Available subset | Not implied |
|---|---|---|
| GraphQL | Query/variables, explicit introspection, offline schema/prefix completion; graphql-transport-ws subscriptions with init/ack/ping/pong/complete | Full IDE/language server, legacy subscriptions-transport-ws, automatic resume/resubscribe |
| WebSocket / SSE | Native bounded sessions, text/binary/ping, fragmented frames, incremental named/id/data SSE events | Automatic reconnect/replay guarantees; SSE retry metadata does not start hidden traffic |
| gRPC | Selected proto/descriptor sources, well-known imports, reflection v1/v1alpha, all four call modes, metadata/deadlines, system TLS/plaintext | Full external protobuf conformance. Custom HTTP TLS profiles are not shared with this baseline. CLI sends one message and half-closes; desktop supports interactive streaming. |
| MQTT | 3.1.1/5 over TCP/TLS/WS, QoS0/1/2, acknowledgement/rejection and retained publishing | Persistent-session replay, crash-surviving exactly-once delivery, will configuration, topic aliases, shared subscriptions or enhanced auth |
| AMQP | 0-9-1, SASL/PLAIN, verified TLS, existing queue consume/ack and default-exchange confirmed publishing | Non-destructive queue browsing, arbitrary exchange/topology administration or all authentication families |
| Kafka | Native librdkafka-backed latest-only consumption without offset commit/store, acknowledged publish, plaintext/TLS and SASL/PLAIN | Group balancing, admin/schema registry, SCRAM/custom trust/client identity support or an atomic cluster snapshot. The selected native client is beta. |
| CloudEvents | Structured JSON 1.0 envelopes, parsed data and supported transport content type | Binary bindings or an arbitrary extension catalog; MQTT3 cannot carry the structured metadata configuration |

Sessions/timelines have deadlines and bounded retention. Typical event payloads cap at 1 MiB and timelines at 1,000 events/8 MiB; library allocation/decompression can happen before Swift inspects a decoded message. Exact adapter bounds are enforced in code. Independently operated services still need acceptance evidence; synthetic broker fixtures are not production brokers.

## CLI and integrations

[CLI.md](CLI.md) covers the command matrix, terminal summaries/detail, JSON migration, exit codes, reports and explicit output rules. MQTT/AMQP/Kafka are desktop workbenches in this MVP.

Git init/status/export/commit operate only on an explicitly selected portable checkout; no remote commands run. Review entered fields/bodies/environment values before committing. Read-only sharing defaults to token-protected loopback; explicit LAN HTTP is plaintext. Native extension API v1 approves exact hashes of data-only request-template/mock-route services. It never loads arbitrary Java/native executable plugins.

## Release acceptance

Developer ID signing/notarization are deferred. Fresh supported-Mac installs, upgrades/Keychain behavior, VoiceOver/keyboard/contrast/reduced motion, independent real services and full capability sign-off remain separate release gates. See [RELEASE.md](RELEASE.md) and [ROADMAP.md](../ROADMAP.md).

### Collection import and navigation (0.4.4 development)

Explicitly empty GET/HEAD raw bodies in Postman and HTTPie Desktop JSON imports become explicit no-body requests, with an import warning. Nonempty or structured GET/HEAD bodies are rejected; payloads are not silently discarded. The current HTTP transport still does not send GET/HEAD bodies.

Sidebar collection headers can be collapsed and expanded. Their state is saved locally; search temporarily expands collections without overwriting the saved state. Selection and the open request editor remain independent of sidebar expansion.

### Grouping-only import containers (0.4.5 development)

Flattened imports omit parent containers that contain only subfolders; child collections retain their breadcrumb names and inherited authentication. Intentional empty leaf folders and parents with their own requests remain. Existing saved collections are not automatically deleted; the change applies to new imports.
