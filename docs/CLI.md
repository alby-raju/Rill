# Native CLI

Requires macOS 15+. Build with `swift build --product RillCLI`; discover the executable directory with `swift build --show-bin-path`, then run its `RillCLI --help`. The packaged app includes `Rill.app/Contents/Helpers/rill`. Use that path directly or create a personal shell alias. The build product uses a distinct name because macOS filesystems commonly ignore filename case.

```
rill init --workspace ./workspace.json
rill list --workspace ./workspace.json
rill run-request REQUEST_ID --workspace ./workspace.json --report ./report.json
rill run-collection COLLECTION_ID --workspace ./workspace.json --iterations 2
rill graphql --endpoint https://example.test/graphql --query 'query { version }'
rill git-init --repo ./portable-workspace
rill share-serve --workspace ./workspace.json --token-file ./share.token
rill share-pull http://127.0.0.1:PORT/workspace --token-file ./share.token --destination ./received.json
```

`--help` is the authoritative complete command/option list. `--workspace` defaults to the desktop workspace for saved-workspace commands; ad-hoc `request` only reads an explicitly supplied workspace. Use a copy for automation. Selection by name must be unambiguous; IDs avoid duplicate names. Environment inheritance, named secrets, authentication, TLS and runners use RillCore. Insecure TLS profiles additionally require `--allow-insecure` on each invocation. Read-only metadata commands do not need Keychain; execution and credential-bearing imports may prompt through macOS.

Exit codes: 0 success; 2 usage/configuration; 3 runtime/transport; 4 failed checks; 130 cancellation. Ctrl+C cancels owned work; report flush uses a separate bounded task. Reports support JSON, Markdown, JUnit and Allure directories. Retry attempts are retained, while recovered retries do not make the final run fail. `--quiet` suppresses normal output. Payloads stay out of ordinary summaries; `--show-messages` explicitly displays stream content and `--output` explicitly saves raw output. Output files are exclusive unless `--overwrite` is supplied; the active workspace cannot be replaced by an output flag.

Imports and API refresh preview by default; `--apply` persists reviewed results. Restore retains a pre-restore copy. Sharing strips bodies, field values, auth/TLS profiles, schemas, hooks and history, but names/hosts/paths remain visible. LAN sharing is explicit plaintext HTTP; use only a trusted network or a TLS reverse proxy. Tokens are required and are not printed. Git exports omit Keychain values and history but retain entered bodies, fields and environment values: review before committing. No remote Git commands run.

Extensions are versioned JSON manifests, not executable code. Discovery lists stable IDs and services; enable approves an exact manifest/content hash. Changes invalidate approval. Templates import with fresh IDs, detached profiles and disabled hooks. Mock-route services export validated JSON for the existing mock server. A manifest contains `apiVersion: 1`, `id`, `name`, `version`, and `services` with `id`, `kind` (`requestTemplate` or `mockRoutes`) and a JSON basename in `file`. The service files use Rill's RequestDraft or MockRouteFile encoding. Do not put secrets in extension files.

The CLI is intentionally explicit: it does not install itself, push Git changes, refresh tokens automatically or execute foreign scripts. gRPC sends one supplied message then half-closes; desktop supports interactive streaming. MQTT/AMQP/Kafka remain desktop workbenches. See [features and limits](FEATURES.md) and [release acceptance](RELEASE.md).

## Direct Postman v2 file runs (development source)

```sh
rill run ./collection.json --environment-file ./environment.json \
  --env-var baseUrl=http://127.0.0.1:8080 --env-var optionalValue= \
  --report ./results.json --report-format json --json
```

This first file-run increment executes the supported Postman v2/v2.1 JSON subset through RillCore, in depth-first source order, without creating a desktop workspace or importing credentials into Keychain. Enabled globals provide fallback values; collection variables override them, followed by enabled environment-file values, iteration-data rows and repeatable `--env-var` options (last occurrence wins; empty values are valid). Secret-typed input values stay in a transient in-memory credential provider. Ambient process-secret fallback and personal Keychain credentials are not read by this file-run path.

Before any request, the entire selected collection/folder and supplied environment are checked for static blockers and every supported request is prepared to validate expanded URLs, headers, credentials and resource limits. Nonempty foreign scripts, missing/cyclic variables, unsupported transport/import representations and multipart/binary/upload bodies block the run. Referenced upload files are never opened. Supported native dynamic templates may be generated during preparation and again at execution; no deterministic-seed promise is made.

**Success policy: HTTP 2xx checks, not Postman assertions.** Every executed request receives an explicit 2xx status check. Scripts in the selected subtree or its ancestors reject the run rather than executing without their tests. A passed run does not establish Newman or full Postman compatibility. Status-check failures exit **4**, transport/runtime failures **3**, invalid/blocked inputs **2**, and cancellation **130**; successful runs exit **0**.

Options reuse `--iterations`, `--delay`/`--retry-delay` (milliseconds), `--retries`, `--continue-on-failure`, `--timeout` (1–300 seconds), `--report`/`--report-format json|markdown|junit`, `--allure`, `--detail`, `--quiet` and `--json`. Limits remain 10,000 planned/executed steps with bounded retries, variables and response retention. JSON summaries have `schemaVersion: 1`, `passed`, `cancelled`, `exhausted`, executed `attempts`, `folderSelected`, `collectionSelected`, `inputFormat` and optional `iterationDataRows`; static blockers return versioned redacted preflight checks with `sendsRequests: false`. Argument, file and preparation errors use stderr and exit 2. Ctrl+C flushes an explicitly requested unsuccessful report before exit when possible.

Ordinary reports omit payloads/credentials. `--output FILE` explicitly exports the last received response if retained; unavailable retention is an error, not a silently omitted artifact. Outputs are exclusive unless `--overwrite` is supplied and cannot replace collection/environment/globals/iteration-data/TLS inputs or the desktop workspace. Inputs remain unchanged. Multipart/file bodies and final-environment export remain future increments; their options are not silently ignored. Saved-workspace commands remain available separately.

### Explicit Postman globals

```sh
rill preflight ./collection.json --globals ./globals.json --environment-file ./environment.json --json
rill run ./collection.json --globals ./globals.json --environment-file ./environment.json \
  --iteration-data ./cases.csv --env-var region=local --report ./results.json --json
```

`--globals FILE` reads one explicit Postman globals JSON export for `run` (Postman format) or offline `preflight`. Native file runs and other commands reject it. The file must be a UTF-8 JSON object (optional BOM), with `_postman_variable_scope: "globals"` and a `values` array. Each row requires a unique nonempty string `key` and string `value`; empty values are valid. `enabled: false` or `disabled: true` skips the row, including contradictory flags; a disabled value leaves a lower scope available. Duplicate names and malformed rows block even when disabled or overridden. An empty `values` array is allowed. The file is limited to 32 MiB and 10,000 rows, with the shared JSON depth bound. Runs also enforce merged variable limits of 1,024 entries, 128-byte names, 1 MiB per value and 4 MiB total decoded key/value text before traffic. Use a regular file; selected input symlinks are rejected by the shared bounded reader.

Precedence is globals < collection < environment < iteration row < explicit CLI override. Recursive templates resolve against the effective merged values, not a separate per-scope scripting API. Secret-typed globals use the same transient credential provider as other Postman inputs; overriding the variable selects the higher-scope value. This supports template inputs and does not execute `pm.globals`, JavaScript mutation or Postman Vault. The broader-to-narrower input scope order follows [Postman's variable scope documentation](https://learning.postman.com/docs/use/send-requests/variables/variables/); CLI overrides remain Rill's explicit final input layer.

Globals participate in exact folder selection and whole-run preparation, including every iteration-data row. Missing/cyclic references and invalid merged inputs block before requests. JSON run summaries and preflight checks include `globalsSupplied`; names and values are omitted from normal diagnostics. Raw response export can contain resolved values returned by the server. Globals files are read-only and protected from report/raw/Allure overwrite, including destination symlink aliases. No personal workspace or Keychain is read or changed. Offline preflight still does not accept iteration data or establish full runtime compatibility.

### Run one Postman folder

```sh
rill preflight ./collection.json --folder '/Payments/Refunds' --json
rill run ./collection.json --folder '/Payments/Refunds' \
  --environment-file ./environment.json --report ./refund-results.json --json
```

`--folder` is an absolute path of case-sensitive folder names relative to the collection root; omit the collection name. It selects that folder's full subtree in depth-first source order, including nested folders. Escape a literal `~` as `~0` and a literal `/` in a name as `~1`; for example, folder `Payments/Legacy` is `/Payments~1Legacy`. No globbing, trimming, fuzzy matching or filesystem lookup occurs. Each segment must match exactly one sibling folder; missing paths, duplicate matches, request leaves and malformed escapes exit 2 before traffic. Paths are bounded to 32 folder levels and 4,096 UTF-8 bytes; an empty selected subtree is blocked.

Collection variables, supplied environment values and overrides keep their existing precedence. Collection/ancestor authentication and settings remain attached, so inherited scripts, unsupported folder variables or unapplied transport settings still block. All selected requests are prepared before traffic. Excluded requests/folders are neither inspected nor executed; a passed folder run says nothing about the rest of the collection. Both preflight checks and run JSON summaries include `folderSelected`, terminal output labels the selected scope, and diagnostic item indices point to the original input JSON. Omitting `--folder` continues to check/run the entire collection. Source JSON is never rewritten.

### Run a native Rill file

```sh
rill run ./workspace.json --format native --collection Smoke --environment CI \
  --env-var baseUrl=http://127.0.0.1:8080 --report ./native-results.json --json
```

Native input is opt-in with `--format native`; the default remains Postman v2 (`--format postman`). The native v1 file is decoded and validated in memory with the shared workspace reader, without opening a workspace session, draft store or Keychain. The source is not rewritten, including any legacy timeout normalization. `--collection NAME_OR_ID` selects one exact, unique flat native collection; omit it to run all requests in file order, including unfiled requests. Native breadcrumb names are literal names, not hierarchical paths. `--folder`, `--globals` and `--environment-file` are Postman-only options.

`--environment NAME_OR_ID` resolves a unique native environment and its enabled parent values; otherwise the file's selected environment is used, or no environment when none is selected. Repeatable `--env-var` overrides those values, with last occurrence winning and empty values allowed. Native file runs bind named-secret descriptors to explicitly supplied `RILL_SECRET_` process values using the existing name normalization (uppercase; dots/hyphens become underscores). Undeclared secret references can use that same process provider. No personal Keychain value, saved request credential companion or identity is read, and no secret is saved. Plaintext credentials/values already present in the supplied file remain sensitive plaintext. OAuth profiles use a supplied token; this command does not acquire or refresh it.

Selected native assertions, extraction, GraphQL/contracts and enabled finite `json-operations-v1` hooks use the shared workflow engine. Foreign script source blocks the selected run; JavaScript is not executed. Configured checks retain their meaning, including an explicitly expected non-2xx status. If an executed response has no native checks, the runner adds an explicit HTTP 2xx check. The terminal labels this policy; it does not claim Postman assertion compatibility.

Before traffic, the complete native file schema and selected hook/profile/contract/TLS configuration are validated. Multipart/binary bodies and file references block without opening referenced files. Saved Keychain client-identity references require an explicit file identity instead of a lookup. System trust and embedded custom anchors are supported; an insecure selected profile requires `--allow-insecure` on this invocation unless explicit file trust replaces it. Unlike static Postman preparation, native request expansion occurs per step so response-derived variables, extraction and hook mutations can drive later requests. Later expansion/configuration errors can therefore occur after earlier requests have run; reports retain partial outcomes. The same execution budgets, retries, cancellation, redaction, protected output paths and exit codes apply. Offline `preflight` remains Postman-only.

### CA trust and mutual TLS from files

Both file formats support explicit TLS inputs on macOS 15+, without importing or looking up a client identity in the personal Keychain:

```sh
rill run ./collection.json --ca-cert ./ca.pem \
  --ssl-client-cert ./client.pem --ssl-client-key ./client.key \
  --ssl-client-origin https://api.example.test --report ./results.json --json

rill run ./workspace.json --format native --ssl-client-p12 ./client.p12 \
  --ssl-passphrase-file ./passphrase.txt --ssl-client-origin https://api.example.test
```

`--ca-cert FILE` accepts DER or a pure PEM certificate bundle. These anchors replace system roots; add `--include-system-roots` to include both. `--insecure` explicitly disables server certificate/hostname verification and cannot be combined with `--ca-cert`. The terminal marks it, and JSON includes `tlsPolicy`. Without an explicit trust override, Postman runs use system trust and native requests retain their selected trust profiles. Supplying only a client identity does not change native trust or waive `--allow-insecure` for an embedded insecure profile. Client certificate chains never become server trust anchors automatically.

Choose one unencrypted PEM certificate/key pair or one PKCS#12 identity. RSA and EC PEM identities are fixture-tested. In a PEM bundle, the leaf is first and intermediates follow. Encrypted PEM keys are unsupported; use PKCS#12 and `--ssl-passphrase-file` for an encrypted container. The password defaults to empty when no file is supplied. A password file is UTF-8 single-line text, preserving spaces and removing at most one trailing LF or CRLF. Passwords are not accepted as command-line values. CA/certificate/key files are each limited to 1 MiB, certificate bundles to 16 certificates, PKCS#12 to 4 MiB and one identity, and password files to 4 KiB. Invalid, mismatched, expired/not-yet-valid identities and wrong passwords fail setup before traffic, with redacted diagnostics. Platform crypto import is synchronous; input bounds are not a separate worker sandbox.

`--ssl-client-origin` is mandatory with an identity and accepts one exact HTTPS origin, including an optional port, with no credentials, query, fragment or path beyond `/`. Default port 443 is normalized. The identity is offered only to that destination and matching TLS challenges; `--insecure` does not relax this scope. Same-origin redirects remain allowed, cross-origin redirects remain unfollowed, and a run supports one identity/origin. Native saved identity requirements can be fulfilled by the supplied files without consulting their saved Keychain references. If a native request requires an identity outside the configured origin, it fails configuration before that request is sent; earlier workflow steps may already have run.

Identity material stays in process memory and URL credentials are not persisted. JSON's optional `clientIdentityConfigured` describes configuration, not proof that a server requested or received it; `tlsPolicy` describes explicit trust overrides (or system trust for configured Postman runs), not every native request profile. Normal output omits key/password contents and certificate subjects. Explicit raw response export can still contain sensitive server content. TLS inputs are read-only and protected from report/raw-output overwrite. Setup errors exit 2, TLS transport failures exit 3, and cancellation exits 130. File execution options apply to `run`; offline `preflight` retains its existing PEM pair inspection and does not negotiate TLS or inspect PKCS#12.

### JSON/CSV iteration data

```sh
rill run ./collection.json --iteration-data ./cases.json --env-var region=local --json
rill run ./workspace.json --format native --collection Smoke \
  --iteration-data ./cases.csv --report ./results.json --json
```

`--iteration-data FILE` accepts UTF-8 JSON or CSV, including an optional UTF-8 BOM. The `.json`/`.csv` extension selects the parser; `--iteration-data-format json|csv` overrides it. Every data row is one iteration in file order. Data files determine the count and cannot be combined with `--iterations`; a format override requires a data file. Empty datasets block rather than passing an empty suite.

JSON must be a nonempty array of objects. Values become string variables: strings retain their text, numbers retain their exact spelling/precision, booleans become `true`/`false`, null becomes the text `null`, and objects/arrays become compact JSON with sorted object keys. These are template values, not a JavaScript or Postman iteration-data API. For example:

```json
[
  {"userId": 123, "tag": "first", "optional": ""},
  {"userId": 456, "tag": "second"}
]
```

CSV requires one header record with unique nonempty variable names and the same number of cells in every subsequent record. LF/CRLF record endings, quoted commas, doubled quotes and quoted multiline text are supported. Values and spaces are preserved; headers are not trimmed. A trailing record ending does not add an extra row. Blank records are not skipped: for one column they represent an empty value; otherwise they fail column-count validation. Unterminated quotes, unexpected text after a closing quote, bare CR endings, duplicate headers and malformed JSON block without echoing data content.

Data keys/headers use 1–128 ASCII letters, digits, underscores, dots or hyphens. Limits are 4 MiB of input and total decoded key/value text across rows, 10,000 rows, 1,024 variables per row/effective snapshot, 1 MiB per value, and 10,000 planned/executed request steps across the run. CSV parsing also caps all cells (including headers) at 100,000; JSON retains the existing bounded parser's depth/node/number limits. Merged variable size/count limits for every row are checked before traffic.

Initial precedence is globals (Postman only), collection/inherited environment values, then the current row, then explicit `--env-var` overrides (last override wins). Empty data values override environment values; a missing JSON key falls back to the environment. Each row starts from the same base snapshot, so extraction/hook changes from another row cannot leak in. Native workflow changes still flow between requests within the row, and failed-attempt updates remain rolled back. Retries and branches stay on the current row and share the run's execution/retention budgets. Runs without a data file keep their existing iteration-state behavior.

Postman runs prepare every selected request for every row before sending, so even a later row with an invalid expanded URL blocks the whole run. Native runs retain per-step expansion for response-derived variables/hooks; later errors can follow earlier traffic and are recorded in partial reports. Reports use the existing one-based `iteration` number, and JSON summaries include `iterationDataRows` when data is supplied. Normal output omits row values; explicit raw response export may contain them. Data files are read-only and protected from report/raw-output overwrite. Offline `preflight` does not yet accept iteration-data options.

For macOS CI after checkout and Xcode setup:

```sh
swift build --product RillCLI
products="$(swift build --show-bin-path)"
"$products/RillCLI" run ./fixtures/collection.json \
  --environment-file ./fixtures/environment.json --report ./results.json --json
```

Use sanitized fixtures and explicitly supplied protected environment files for CI credentials. This example requires macOS; it does not establish Linux/Windows support.

## Ad-hoc HTTP requests (development source)

```sh
rill request GET https://example.test/health --json
rill request POST 'https://example.test/items' -H 'Content-Type: application/json' \
  -d '{"name":"{{name}}"}' --env-var name=fixture --output ./response.json
rill request GET '{{base}}/health' --workspace ./workspace.json \
  --environment Local --auth-profile Service --tls Corporate
```

`request METHOD URL` uses the shared HTTP engine without creating a request or reading the desktop workspace. It accepts GET, POST, PUT, PATCH, DELETE, HEAD and OPTIONS (case-insensitive). Saved environments/authentication/TLS profiles require an explicit `--workspace`; only metadata is loaded, with named credentials resolved by the existing credential provider when needed. Nothing is saved back.

Use repeatable `-H`/`--header name:value`, `-d`/`--data TEXT` or `--data-file FILE` (UTF-8, at most 1 MiB). Body options are mutually exclusive; GET/HEAD bodies and repeated header names remain rejected. Temporary `--env-var key=value` overrides saved environment values; the last occurrence wins and empty values are valid. `--timeout` is 1–300 seconds. Insecure profiles still require `--allow-insecure`; certificate/environment file flags are not supported here.

Normal output is a redacted HTTP status/timing/response-byte summary. `--json` emits `schemaVersion: 1`, `status`, `duration` (seconds) and `bodyBytes`; it never includes URLs, headers or payloads. `--quiet` suppresses it. Raw response bytes require `--output FILE`, with `--overwrite` for existing files; workspace and body input paths are protected. Response downloads retain the shared 16 MiB limit. HTTP non-2xx and transport failures exit 3; invalid configuration exits 2; cancellation exits 130. This command does not run saved hooks/assertions or produce collection reports. No cookie jar or foreign script runtime is introduced.

## Terminal run experience

`run-request`, `run-collection` / `run-folder`, and `contract-check` now default to a human summary. This replaces the previous three-boolean stdout object; automation consuming it must add **`--json`**. Other metadata commands retain JSON. `perf` also defaults to a readable summary; add `--json` for its complete structured samples.

```sh
rill run-collection Smoke --workspace ./workspace.json
rill run-collection Smoke --workspace ./workspace.json --detail --continue-on-failure
rill run-request Health --workspace ./workspace.json --json
rill perf Health --workspace ./workspace.json --count 100 --concurrency 4 --detail
```

The summary shows final request visits, checks across all attempts, retries, recovered visits, skipped/cancelled work, received body bytes and response latency (mean/min/max/nearest-rank p95). A branch may revisit a request; visits are not unique requests. Planned steps describe the original collection/iteration plan, not a completion denominator for branching flows. A recovered retry passes the visit while its failed checks remain counted in the all-attempt check totals. Request results show up to 30 visits and failure diagnostics show up to 200 terminal failures.

`--detail` shows attempt/iteration, method, saved request name, HTTP status, elapsed time, body size and individual numbered checks, including failed attempts later recovered by retries. Up to 200 attempt records and 50 retained checks per record are displayed; omissions are explicit. `--report FILE` retains the existing full bounded JSON/Markdown/JUnit artifact; `--allure DIRECTORY` remains supported. Check labels and runtime values remain omitted because they can contain secrets. Request names are visible metadata; URLs, headers, payloads and raw error strings are never printed by these views. Terminal controls and bidirectional overrides in names are stripped.

Performance reports show throughput, p50/p95/p99 and min/max latency, plus optional per-sample detail. Performance latency includes failed executed samples; unexecuted/cancelled samples are excluded. Collection response latency includes only attempts that received an HTTP response. Neither report invents timing or success values for missing responses.

TTY sessions show append-only progress on stderr as each attempt completes. Redirected output and `--json` have no progress; `--quiet` suppresses normal output and progress. Colors are automatic only on a capable TTY, respecting `NO_COLOR` and `TERM=dumb`; override with `--color always|never`. Color is supplementary: every result has a text state. Existing exit codes, cancellation/report flushing and payload export behavior are unchanged.

## Offline collection preflight (since 0.4.4)

Included since 0.4.4. Build `RillCLI` from source or use the packaged CLI to inspect a local Postman v2 collection without importing or sending it:

```sh
swift run RillCLI preflight ./collection.json \
  --environment-file ./environment.json \
  --env-var runCleanup=true \
  --ssl-client-cert ./client.crt \
  --ssl-client-key ./client.key \
  --json
```

`--env-var` is repeatable; precedence is collection variables, then enabled environment values, then overrides (last override wins). Empty override values are valid. Other run commands reject these new file options rather than silently ignoring them. Globals, data-aware offline preflight and a complete execution plan remain future work. Development source provides Postman v2 and explicit native v1 file runs with JSON/CSV data as described above.

Preflight blocks nonempty foreign scripts at collection/folder/request scope, unsupported importer representations, omitted transport settings, unresolved/cyclic/over-budget template references, invalid environments and empty collections. Script-produced variables are not inferred. Diagnostics identify JSON locations using indices, without echoing request names, arbitrary keys, URLs, variable values or script text. Terminal output shows the first 20 diagnostics by default; `--detail` expands it. At most 1,000 diagnostic records are retained; the total blocker count remains visible. Static variable analysis is bounded and conservative; it recognizes the supported `$uuid`, `$timestamp`, `$email` and `$randomInt a b` syntax without generating values. Unsupported dynamic names and malformed arguments remain blockers. It does not evaluate JavaScript or arbitrary body-file contents.

Optional PEM certificate/key inspection uses the fixed system `/usr/bin/openssl` with bounded input/output and deadlines. It checks PEM parsing, public-key pairing and certificate notAfter expiry only. It does not verify notBefore validity, certificate chains, hostname, revocation, server trust or actual mTLS negotiation. Only unencrypted PEM private keys are supported in this increment; encrypted keys, PKCS#12 and CA options remain future work. No private key or password is printed or imported into Keychain.

Exit 0 means these static checks passed, **not** that the suite executed or matched Newman semantics. Blocked/invalid input exits 2; cancellation exits 130. JSON output has `passed`, `sendsRequests: false`, and a versioned `checks` object containing counts and `{code, location}` diagnostics. Malformed/unreadable input can instead produce a redacted stderr configuration error with exit 2. No request, workspace import, credential hydration or file export occurs.
