# Native CLI

Requires macOS 15+. Build with `swift build --product RillCLI`; discover the executable directory with `swift build --show-bin-path`, then run its `RillCLI --help`. The packaged app includes `Rill.app/Contents/Helpers/rill`. Use that path directly or create a personal shell alias. The build product uses a distinct name because macOS filesystems commonly ignore filename case.

## Installation and discovery

Keep the full app installation if using its bundled CLI. For a permanent personal command, create `~/.local/bin/rill` containing the following, make it executable, and add `~/.local/bin` to your shell's `PATH`:

```sh
#!/bin/sh
exec /Applications/Rill.app/Contents/Helpers/rill "$@"
```

Development source also builds a CLI-only `RillCLI-VERSION-ARCH-development.zip` through `bash scripts/release-artifacts.sh` (or `python3 scripts/package-cli.py` after packaging the app). This is a macOS archive, not Linux/Windows support. Extract it to a permanent directory and add its `bin` directory to `PATH`. Keep `Resources` and `Frameworks` beside `bin`; copying only the executable loses optional compiler/runtime resources. Packaging checks the signature, relocates the tree to a path with spaces, compiles a well-known protobuf import and performs a loopback HTTP request. The currently published 0.4.5-dev.1 release predates this standalone archive. Homebrew remains a later distribution decision.

```sh
rill doctor --json
rill doctor --workspace ./workspace.json --json
rill help run
rill run --help
```

`doctor` makes no network requests, changes no files and does not read Keychain or process secrets. It reports the bundled compiler's presence and optionally validates one explicit workspace read-only. Missing optional `protoc` is a warning for HTTP-only installations; an invalid explicit workspace exits 2. It does not attest signatures, test credentials, validate every protocol or prove endpoint connectivity. Output omits workspace paths/content.

Generate static completions for your shell:

```sh
rill completion zsh > ~/.zfunc/_rill
rill completion bash > ~/.local/share/rill.bash
rill completion fish > ~/.config/fish/completions/rill.fish
```

Create destination directories first. For zsh, add `~/.zfunc` to `fpath` before `compinit`; for bash, source the generated file from your shell configuration. Fish loads its completions directory automatically. The standalone archive includes the same files in `completions`. Completions list commands/options and local files without invoking Rill during tab completion or accessing credentials. Option lists come from the parser; value suggestions are intentionally generic file suggestions. Bash completion supports macOS's bundled Bash 3.2.

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

## Direct Postman v2 file runs (since 0.4.5)

```sh
rill run ./collection.json --environment-file ./environment.json \
  --env-var baseUrl=http://127.0.0.1:8080 --env-var optionalValue= \
  --report ./results.json --report-format json --json
```

The file runner executes the supported Postman v2/v2.1 JSON subset through RillCore, in depth-first source order, without creating a desktop workspace or importing credentials into Keychain. Enabled globals provide fallback values; collection variables override them, followed by enabled environment-file values, iteration-data rows and repeatable `--env-var` options (last occurrence wins; empty values are valid). Secret-typed input values stay in a transient in-memory credential provider. Ambient process-secret fallback and personal Keychain credentials are not read by this file-run path.

Before any request, the entire selected collection/folder and supplied environment are checked for static blockers and every supported request is prepared to validate expanded URLs, headers, credentials and resource limits. By default, nonempty foreign scripts, missing or cyclic variables, unsupported transport/import representations and unbound file attachments block the run. Rill ignores file paths stored in the export. Supported native dynamic templates may be generated during preparation and again at execution; no deterministic-seed promise is made.

**Success policy: HTTP 2xx checks, not Postman assertions.** Every executed request receives an explicit 2xx status check. Scripts in the selected subtree or its ancestors reject the run rather than executing without their tests. A passed run does not establish Newman or full Postman compatibility. Status-check failures exit **4**, transport/runtime failures **3**, invalid/blocked inputs **2**, and cancellation **130**; successful runs exit **0**.

Options reuse `--iterations`, `--delay`/`--retry-delay` (milliseconds), `--retries`, `--continue-on-failure`, `--timeout` (1–300 seconds), `--report`/`--report-format json|markdown|junit|html`, `--allure`, `--detail`, `--quiet` and `--json`. Limits remain 10,000 planned/executed steps with bounded retries, variables and response retention. JSON summaries have `schemaVersion: 1`, `passed`, `cancelled`, `exhausted`, executed `attempts`, `folderSelected`, `collectionSelected`, `inputFormat` and optional `iterationDataRows`; static blockers return versioned redacted preflight checks with `sendsRequests: false`. Argument, file and preparation errors use stderr and exit 2. Ctrl+C flushes an explicitly requested unsuccessful report before exit when possible.

Ordinary reports omit payloads/credentials. `--output FILE` explicitly exports the last received response if retained; unavailable retention is an error, not a silently omitted artifact. Outputs are exclusive unless `--overwrite` is supplied and cannot replace collection/environment/globals/iteration-data/TLS inputs or the desktop workspace. Inputs remain unchanged. Multipart/file bodies remain unsupported; their options are not silently ignored. Saved-workspace commands remain available separately.

### Offline HTML reports

`--report ./run.html --report-format html` writes a self-contained report with state/request-ID filters, per-attempt checks, retries, HTTP status and relative timing bars. The desktop runner offers **Offline HTML** in its existing export menu. Open the file locally; it requires no server, CDN, network assets or telemetry. A content security policy permits only the report's fixed, hash-pinned local filter script. Without JavaScript, all rows remain visible and printable. Payloads, URLs, request labels and runtime messages remain omitted under the same allowlist as JSON/JUnit reports. This first version navigates by request ID; folder/source navigation and baseline response diffs remain roadmap work.

### Cookie login chains

```sh
rill run ./collection.json --cookies
rill run ./workspace.json --format native --cookies
```

`--cookies` opts a file run into a private in-memory cookie jar. Responses capture `Set-Cookie`; later matching requests and redirects send cookies using native domain, path, Secure and expiry rules. The jar starts empty for every invocation, is shared across requests/retries/iterations in that run, and is discarded at the end. Cookies are transport session state: failed assertions do not roll back server cookie changes. Runs without the flag retain cookie-free behavior. The jar is separate from Workbench, system/browser storage, environment exports and ordinary reports. No cookie files are read or written. Explicit raw response exports may reveal echoed cookies. Individual `request` commands use the separate [encrypted cookie session](#persist-cookies-across-requests) option. Offline preflight rejects `--cookies`. The desktop Collection and Environment matrix tabs offer the same opt-in as **Use run-local cookies**, with a separate empty jar per environment. Load tests retain isolated cookie-free requests.

### Final environment export

```sh
rill run ./collection.json --export-environment ./final-environment.json
rill run ./workspace.json --format native --environment Staging --export-environment ./final-environment.json
```

`--export-environment FILE` explicitly writes effective run variables as sorted Postman environment JSON. It includes enabled merged inputs and committed native hook/extraction updates; failed-attempt updates roll back. With iteration data, it captures the last started row, not an aggregate of all rows. Without iteration data, variables keep flowing across iterations. Failed or stopped runs export their last committed state; cancelled runs and input-preparation failures do not export. Export happens before normal reports and exit-status evaluation, so a nonzero exit can still leave a useful environment artifact.

This is a raw plaintext export: values can include tokens extracted from responses or entered through CLI overrides. Selecting the option authorizes that export. Templates and named-secret references stay unexpanded; Keychain/process/transient credential values are never resolved for export. An exported secret reference needs its original credential source supplied separately when reused. Reuse with Postman-format `--environment-file`; this is a flattened snapshot, not a native workspace or an export of separate variable scopes. The destination must differ from reports, raw responses, run inputs and the desktop workspace. Existing files require `--overwrite`. Ordinary reports/stdout do not contain the exported variable map.

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

### Bind Postman file attachments

Development source supports raw binary bodies and multipart forms in Postman file runs. Text-only multipart forms need no attachment manifest. For file parts, use the dry-run plan to discover the required slots:

```sh
rill run ./collection.json --folder /Upload --dry-run --json
```

The plan lists each slot and whether a file was declared for it. A plan with missing bindings exits 2 while still listing the slots. Create a version 1 JSON manifest using the exact slots printed by the plan:

```json
{
  "schemaVersion": 1,
  "attachments": [
    {"slot": "/item/1/item/0/attachments/0", "file": "./photo.jpg"},
    {"slot": "/item/1/item/0/attachments/1", "file": "./notes.pdf"}
  ]
}
```

```sh
rill run ./collection.json --folder /Upload --attachments ./attachments.json --dry-run --json
rill run ./collection.json --folder /Upload --attachments ./attachments.json --report ./upload-results.json
```

The request prefix uses original collection positions, including when a folder is selected. The final number counts enabled file parts from zero in their wire order. A multipart field with multiple exported files gets one slot for each file. A binary body uses slot zero. Regenerate the plan after reordering requests or file parts. Duplicate, missing or unused slots block execution. Relative file paths resolve from the manifest's directory. The manifest supports up to 256 bindings and 64 KiB of JSON.

Exported paths are ignored, including paths that contain unresolved variables. Only the manifest can select local files. Dry-run checks the mapping without inspecting attachment files. A real run checks regular-file metadata and the 256 MiB body limit before sending any requests, then reads and rechecks each file when its request is prepared. The manifest, attachments and aliases are protected from report and output overwrite. Native file runs still reject streaming bodies.

### Run a native Rill file

```sh
rill run ./workspace.json --format native --collection Smoke --environment CI \
  --env-var baseUrl=http://127.0.0.1:8080 --report ./native-results.json --json
```

Native input is opt-in with `--format native`; the default remains Postman v2 (`--format postman`). The native v1 file is decoded and validated in memory with the shared workspace reader, without opening a workspace session, draft store or Keychain. The source is not rewritten, including any legacy timeout normalization. `--collection NAME_OR_ID` selects one exact, unique flat native collection; omit it to run all requests in file order, including unfiled requests. Native breadcrumb names are literal names, not hierarchical paths. `--folder`, `--globals` and `--environment-file` are Postman-only options.

`--environment NAME_OR_ID` resolves a unique native environment and its enabled parent values; otherwise the file's selected environment is used, or no environment when none is selected. Repeatable `--env-var` overrides those values, with last occurrence winning and empty values allowed. Native file runs bind named-secret descriptors to explicitly supplied `RILL_SECRET_` process values using the existing name normalization (uppercase; dots/hyphens become underscores). Undeclared secret references can use that same process provider. No personal Keychain value, saved request credential companion or identity is read, and no secret is saved. Plaintext credentials/values already present in the supplied file remain sensitive plaintext. OAuth profiles use a supplied token; this command does not acquire or refresh it.

Selected native assertions, extraction, GraphQL/contracts and enabled finite `json-operations-v1` hooks use the shared workflow engine. Foreign script source blocks the selected run; JavaScript is not executed. Configured checks retain their meaning, including an explicitly expected non-2xx status. If an executed response has no native checks, the runner adds an explicit HTTP 2xx check. The terminal labels this policy; it does not claim Postman assertion compatibility.

Before traffic, the complete native file schema and selected hook/profile/contract/TLS configuration are validated. Multipart/binary bodies and file references block without opening referenced files. Saved Keychain client-identity references require an explicit file identity instead of a lookup. System trust and embedded custom anchors are supported; an insecure selected profile requires `--allow-insecure` on this invocation unless explicit file trust replaces it. Unlike static Postman preparation, native request expansion occurs per step so response-derived variables, extraction and hook mutations can drive later requests. Later expansion/configuration errors can therefore occur after earlier requests have run; reports retain partial outcomes. The same execution budgets, retries, cancellation, redaction, protected output paths and exit codes apply. Offline `preflight` remains Postman-only.

### Preview a file run offline

```sh
rill run ./collection.json --config ./run.json --translate-scripts --dry-run --json
rill run ./workspace.json --format native --collection Smoke --environment CI --dry-run --detail
```

Development source supports `--dry-run` for Postman and native files. It uses the run's selected folder or collection, config, environment, globals, overrides and iteration data. The terminal summary or version 1 JSON plan shows the selection and environment source, iteration count, retry limit and base step count. JSON and terminal `--detail` list each selected request once in input order using its HTTP method and structural location in the source. They omit request and environment names, addresses, local paths, headers, bodies, variable values and script source. Source locations are JSON pointers such as `/item/1/item/0` and `/requests/0`.

A successful plan describes offline preparation. It does not run scripts or hooks, resolve named-secret values, open key/certificate/passphrase files, send requests or write run outputs. TLS declarations and the identity map shape are checked; TLS file contents are deferred. The plan marks requests whose validation depends on secrets, script mutations or native workflow state, and indicates when scripts or hooks can change the request order. The base count excludes retries, skips and branches. Concrete preparation failures still exit 2. Use the explicit command-line flag when reusing a run config; `dry-run` is unavailable as a persisted config default.

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

Choose a PEM certificate/key pair or one PKCS#12 identity. RSA and EC PEM identities are fixture-tested. In a PEM certificate bundle, put the leaf first and intermediates after it. Encrypted PEM uses the PKCS#8 `ENCRYPTED PRIVATE KEY` format with PBES2, PBKDF2 and AES-128/192/256-CBC. PBKDF2 accepts HMAC-SHA-1/224/256/384/512, an 8–64 byte salt and 1–1,000,000 iterations. Encrypted EC keys use the named P-256, P-384 or P-521 curves. Legacy PEM encryption, scrypt and other encryption schemes are unsupported.

Use `--ssl-passphrase-file FILE` for encrypted PEM or password-protected PKCS#12. A password file is UTF-8 single-line text. Rill preserves spaces and removes at most one trailing LF or CRLF. Omit the file for an unencrypted PEM key. PKCS#12 defaults to an empty password when the file is omitted. CA/certificate/key files are each limited to 1 MiB, certificate bundles to 16 certificates, PKCS#12 to 4 MiB and one identity, and password files to 4 KiB. Invalid or mismatched keys, invalid certificate dates and wrong passwords fail setup before traffic with redacted diagnostics.

```sh
rill run ./collection.json --ssl-client-cert ./client.pem \
  --ssl-client-key ./encrypted-key.pem --ssl-passphrase-file ./passphrase.txt \
  --ssl-client-origin https://api.example.test --ca-cert ./ca.pem
```

Use `--ssl-client-origin` with the single-identity flags. For a run that contacts several mTLS services, use `--ssl-client-map ./identities.json` with this version 1 format:

```json
{
  "schemaVersion": 1,
  "identities": [
    {"origin": "https://api.example.test", "certificate": "api.pem", "key": "api.key"},
    {"origin": "https://jobs.example.test:8443", "pkcs12": "jobs.p12", "passphraseFile": "jobs.txt"}
  ]
}
```

The map accepts 1–16 identities and is limited to 64 KiB. Relative identity paths are resolved from the map's directory. `passphraseFile` is required for an encrypted PEM key and optional for PKCS#12. Choose either the map or the single-identity flags. Trust options apply to the entire run. The map and all referenced files are protected from output overwrite.

Each origin is an exact HTTPS host and port, with no credentials, query, fragment or path beyond `/`. Host case and default port 443 are normalized, and duplicate origins fail setup before any requests are sent. Rill selects the identity after resolving the request URL and offers it only to matching TLS challenges, including in `--insecure` mode. Unmapped requests use no file identity. Same-origin redirects remain allowed. Rill leaves cross-origin redirects unfollowed even when both origins are mapped. A native request that requires an identity fails configuration before sending if its resolved origin has no matching file identity. Earlier workflow steps may already have run.

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

Use repeatable `-H`/`--header name:value`, `-d`/`--data TEXT` or `--data-file FILE` (UTF-8, at most 1 MiB). Development source also supports explicit binary and form uploads:

```sh
rill request PUT https://example.test/blob --binary-file ./image.bin
rill request POST https://example.test/upload --form 'title=Example' --form 'file@./image.bin'
rill request POST https://example.test/search --form 'q=Rill API' --form 'tag=swift' --form 'tag=cli'
```

A form with only text fields is URL-encoded. Adding a `NAME@PATH` field or `--multipart` selects multipart. Repeated names and field order are preserved. Paths are literal and files must be regular files. The complete binary or multipart upload is limited to 256 MiB. Body modes are mutually exclusive. GET/HEAD bodies and repeated request headers are rejected.

Temporary `--env-var key=value` overrides saved environment values. The last occurrence wins, including empty values. `--timeout` accepts 1–300 seconds. A saved insecure profile requires `--allow-insecure`. For headless mTLS, use [explicit file TLS options](#ca-trust-and-mutual-tls-from-files), including a single exact `--ssl-client-origin`. Choose either explicit file TLS or a saved `--tls` profile. Certificate maps are for collection file runs.

```sh
rill request GET https://example.test/archive --download ./archive.zip --json
```

`--download FILE` streams a successful GET into a private temporary file in the destination directory, then installs it atomically. The directory must exist. The limit is 256 MiB. Failed HTTP responses, incomplete transfers, size-limit failures and cancellation leave any existing destination intact. Use `--overwrite` to replace an existing file after a successful transfer.

Ordinary output is a redacted status, timing and byte summary. `--json` emits `schemaVersion: 1`, `status`, `duration` in seconds and `bodyBytes`. `--quiet` suppresses the summary. Use `--output FILE` for explicit raw response export, including on non-2xx responses, with the usual 16 MiB limit. Choose either `--output` or `--download`. Both protect workspace, body and TLS inputs from overwrite. Non-2xx and transport failures exit 3, invalid configuration exits 2, and cancellation exits 130. The command runs a single request with no saved hooks or assertions. Cookies are disabled unless an encrypted session is selected.

### Persist cookies across requests

```sh
(umask 077; openssl rand -hex 32 > ./session-key.txt)
rill request POST https://api.example.test/login --data-file ./login.json \
  --session ./cookies.rill --session-key-file ./session-key.txt
rill request GET https://api.example.test/me \
  --session ./cookies.rill --session-key-file ./session-key.txt --json
```

Development source supports opt-in cookie sessions for `request`, including streaming downloads. Use a dedicated random 32-byte key written as 64 hexadecimal digits. The key and any existing session must be regular, owner-only files. Rill creates the encrypted session and its lock with private permissions in an existing directory. Store the key separately from the session when sharing or backing up files.

The first completed request binds the session to its resolved scheme, host and port. Reusing it for a different origin exits 2 before sending. The native jar applies cookie path, Secure and expiry rules. A session retains ordinary server cookies across invocations, including cookies without an expiry. Header overrides, request bodies, auth settings and TLS credentials stay invocation-local. Explicit Cookie headers and insecure TLS settings are rejected with a session. Non-Secure cookies on an explicitly selected HTTP origin travel over HTTP.

The session is authenticated with AES-GCM and limited to 128 cookies and 256 KiB on disk. The key is supplied from its explicit file, with no Keychain lookup for session encryption. A concurrent invocation using the same file exits 2 before sending. Updates replace the prior encrypted file atomically. A completed HTTP error response can still set or expire cookies. Cancellation, transport failure and an unsuccessful session write preserve the previous session. The session is separate from Workbench and run-local cookie jars.

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

`--env-var` is repeatable; precedence is collection variables, then enabled environment values, then overrides (last override wins). Empty override values are valid. Other run commands reject these new file options rather than silently ignoring them. Explicit Postman globals are supported as described above. Use `run FILE --dry-run` to preview a Postman v2 or native v1 file run with JSON/CSV iteration data and the same selection options as execution.

Preflight blocks nonempty foreign scripts at collection/folder/request scope, unsupported importer representations, omitted transport settings, unresolved/cyclic/over-budget template references, invalid environments and empty collections. Script-produced variables are not inferred. Diagnostics identify JSON locations using indices, without echoing request names, arbitrary keys, URLs, variable values or script text. Terminal output shows the first 20 diagnostics by default; `--detail` expands it. At most 1,000 diagnostic records are retained; the total blocker count remains visible. Static variable analysis is bounded and conservative; it recognizes the supported `$uuid`, `$timestamp`, `$email` and `$randomInt a b` syntax without generating values. Unsupported dynamic names and malformed arguments remain blockers. It does not evaluate JavaScript or arbitrary body-file contents.

Use `--translate-scripts` for the explicit [bounded native script subset](SCRIPT-SUBSET.md), in Postman `run` or offline `preflight`. This enables no JavaScript runtime; every selected inherited block and branch target must compile before traffic. Normal mode still blocks foreign source. See the subset guide for exact grammar, scoped mutations, row isolation, skip/branch outcomes, raw export behavior and conformance limits.

Use `--script-inventory` with `--json` or `--detail` for an opt-in [script compatibility inventory](COMPATIBILITY.md): original collection/folder/request event locations, selected-descendant counts, declared-disabled flags and redacted lexical API hints with source coordinates. The inventory alone never enables JavaScript or translation; combine it with `--translate-scripts` to validate the finite subset. Opaque syntax, inspection budgets and omitted source records are explicit; known hints do not establish executable support. Existing script blockers and exit codes remain unchanged. The optional JSON field is `checks.scriptInventory`; it is absent by default.

Optional PEM certificate/key inspection uses the fixed system `/usr/bin/openssl` with bounded input/output and deadlines. It checks PEM parsing, public-key pairing and certificate notAfter expiry only. It does not verify notBefore validity, certificate chains, hostname, revocation, server trust or actual mTLS negotiation. Offline inspection supports unencrypted PEM keys. File runs also support encrypted PKCS#8 PEM keys, PKCS#12 and custom CAs. No private key or password is printed or imported into Keychain.

Exit 0 means these static checks passed, **not** that the suite executed or matched Newman semantics. Blocked/invalid input exits 2; cancellation exits 130. JSON output has `passed`, `sendsRequests: false`, and a versioned `checks` object containing counts and `{code, location}` diagnostics. Malformed/unreadable input can instead produce a redacted stderr configuration error with exit 2. No request, workspace import, credential hydration or file export occurs.

## Saved mock projects (development source)

`mock-serve --project FILE [--port N] --json` reads the desktop's version 1 project format without opening a personal workspace. `--routes FILE` retains legacy route-array support; choose exactly one input. Readiness is compact one-line JSON, including the ephemeral loopback port. `--control-stdin` accepts bounded newline-terminated `status`, `reset` and `stop`; EOF stops normally. Ctrl+C/SIGTERM stops and exits 130. See [Local mocks](wiki/Local-Mocks.md) for matching, scenario, file and resource limits. No listener starts implicitly and no LAN bind is available.

## Reproducible runs and comparison (development source)

Versioned `run --config FILE` defaults, scoped `--seed`/`--seed-time`, `--deadline`, redacted GitHub annotations, NDJSON events and explicit raw `--comparison-output` snapshots are documented in [Run investigation](RUN-INVESTIGATION.md). `report-diff BEFORE AFTER` compares normalized JSON/header/shape, status/check/retry and latency drift; ordinary redacted reports require `--metadata-only`. Unknown data cannot prove equality. Raw snapshots can contain credentials; they are separate from safe ordinary JSON/HTML exports.
