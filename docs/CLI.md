# Native CLI

Requires macOS 15+. Build with `swift build --product RillCLI`; run `.build/debug/RillCLI --help`. The packaged app includes `Rill.app/Contents/Helpers/rill`. Use that path directly or create a personal shell alias. The build product uses a distinct name because macOS filesystems commonly ignore filename case.

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

`--help` is the authoritative complete command/option list. `--workspace` defaults to the desktop workspace. Use a copy for automation. Selection by name must be unambiguous; IDs avoid duplicate names. Environment inheritance, named secrets, authentication, TLS and runners use RillCore. Insecure TLS profiles additionally require `--allow-insecure` on each invocation. Read-only metadata commands do not need Keychain; execution and credential-bearing imports may prompt through macOS.

Exit codes: 0 success; 2 usage/configuration; 3 runtime/transport; 4 failed checks; 130 cancellation. Ctrl+C cancels owned work; report flush uses a separate bounded task. Reports support JSON, Markdown, JUnit and Allure directories. Retry attempts are retained, while recovered retries do not make the final run fail. `--quiet` suppresses normal output. Payloads stay out of ordinary summaries; `--show-messages` explicitly displays stream content and `--output` explicitly saves raw output. Output files are exclusive unless `--overwrite` is supplied; the active workspace cannot be replaced by an output flag.

Imports and API refresh preview by default; `--apply` persists reviewed results. Restore retains a pre-restore copy. Sharing strips bodies, field values, auth/TLS profiles, schemas, hooks and history, but names/hosts/paths remain visible. LAN sharing is explicit plaintext HTTP; use only a trusted network or a TLS reverse proxy. Tokens are required and are not printed. Git exports omit Keychain values and history but retain entered bodies, fields and environment values: review before committing. No remote Git commands run.

Extensions are versioned JSON manifests, not executable code. Discovery lists stable IDs and services; enable approves an exact manifest/content hash. Changes invalidate approval. Templates import with fresh IDs, detached profiles and disabled hooks. Mock-route services export validated JSON for the existing mock server. A manifest contains `apiVersion: 1`, `id`, `name`, `version`, and `services` with `id`, `kind` (`requestTemplate` or `mockRoutes`) and a JSON basename in `file`. The service files use Rill's RequestDraft or MockRouteFile encoding. Do not put secrets in extension files.

The CLI is intentionally explicit: it does not install itself, push Git changes, refresh tokens automatically or execute foreign scripts. gRPC sends one supplied message then half-closes; desktop supports interactive streaming. MQTT/AMQP/Kafka remain desktop workbenches. See the milestone documents for protocol subsets and outstanding acceptance gates.

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
