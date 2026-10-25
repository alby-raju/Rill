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
