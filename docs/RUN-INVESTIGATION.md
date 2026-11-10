# Reproducible runs and investigation

These are development-source additions after v0.4.5-dev.1. They share the native runner; no JavaScript runtime, hosted report service or cross-platform support is added.

## One reviewed configuration

`run COLLECTION --config run-config.json` reads a version 1 file containing option defaults. The collection operand remains explicit. Options are strings or, for repeatable `env-var`, arrays of strings; flags are booleans. Unknown keys/options, recursive configs, invalid types, unsupported versions, files over 64 KiB and excessive nesting fail before traffic.

```json
{
  "kind": "rill.run-config",
  "schemaVersion": 1,
  "options": {
    "environment-file": "./environment.json",
    "seed": "42",
    "seed-time": "1735689600",
    "deadline": "120",
    "retries": "1",
    "report": "./results/run.json",
    "report-format": "json"
  },
  "flags": {
    "cookies": true,
    "github-annotations": true
  }
}
```

CLI options override defaults; repeatable config variables precede CLI variables, so the last explicit value wins. File destinations and environment/data/TLS inputs supplied by a config resolve relative to that config. Paths supplied on the CLI and the collection operand resolve relative to the working directory. No shell expansion, environment interpolation or config discovery occurs. Native inputs use `format: "native"` plus native collection/environment selection; format-specific restrictions remain enforced.

`--fail-fast` explicitly overrides a config's continue-on-failure choice, and `--continue-on-failure` overrides a config's fail-fast choice. Contradictory explicit policies reject. A true CLI flag takes precedence over a false config default; there is no generic `--no-FLAG` inversion. Configs are plain text and can specify entered values, insecure TLS or overwrite behavior: review them before use. Prefer process secrets/passphrase files to storing credentials inline. Output validation protects the config itself along with collection, environment, data and TLS inputs.

## Deterministic templates and execution deadlines

`--seed UINT64` scopes the versioned **SplitMix64-v1** generator to this run's task tree. `$uuid`, `$email` and `$randomInt lower upper` consume a reproducible sequence; UUIDs retain their version/variant bits. `$timestamp` uses `--seed-time EPOCH`, defaulting to zero. Seed time requires a seed and ranges from epoch 0 through 253402300799. Integer bounds include the complete signed 64-bit range with rejection sampling. The unseeded behavior remains unchanged; no process RNG or system clock is modified.

Generation order follows execution and substitution order, including retries and branches. Offline preparation does not consume the execution generator. To reproduce values, keep the same inputs, traversal, options, engine version and generator version. Independent concurrent runs have separate generators; arbitrary concurrently scheduled work inside one seeded scope is not promised a fixed consumption order. These are synthetic fixture values, not cryptographic secrets or a promise to match Newman's random generator.

`--deadline SECONDS` sets a monotonic execution deadline from 0.01 through 86400 seconds, including request work and pacing/retry delays. Request `--timeout` remains separate. On expiry the runner cancels active work, stops retries/traversal, marks unvisited steps, and reports `timedOut: true`; it cannot pass. Deadline failures exit 3. User cancellation remains cancellation (exit 130). Preparation and report/export I/O sit outside this execution deadline. Cancellation is cooperative; finite native scripts retain their own operation/time budgets and may finish their bounded work before unwinding.

## Reports and CI

JSON exports now identify `kind: "rill.run-report"`, `schemaVersion: 1`. Existing outcome fields and computed `passed` remain. Optional failure kinds distinguish assertions, configuration, authentication/TLS/contracts, transport, request timeout, execution deadline, cancellation and resource limits. Runtime strings, arbitrary expected/actual values, labels, URLs, bodies, headers and fingerprints remain excluded from ordinary exports. Safe actual status/check counts and timing remain available.

`--report events.ndjson --report-format ndjson` writes version 1 `rill.run-event` records: `started`, ordered `attempt` records (including retries/unvisited steps), then `finished`. Sequence numbers, final flags, request IDs and structural source pointers support machine processing. This is an **atomic end-of-run export**, not a live stream. The CLI encodes redacted events in bounded chunks and publishes the report after the final event. Existing reports require `--overwrite`. An interrupted run can still export its complete unsuccessful report. The JSON allowlist and 32 MiB export budget also apply to NDJSON. JSON/JUnit/Markdown/Allure/HTML remain supported.

Offline HTML adds source-group navigation, failure kinds, state/request filters, per-attempt timings and a reproduction-command template. It remains self-contained with a hash-pinned script and no remote assets. Structural JSON pointers replace private folder labels/file paths. The displayed command uses placeholder paths; retain the actual original inputs/config and credential sources to reproduce a run. The report does not embed credentials or an exact secret-bearing command line.

`--github-annotations` emits at most 100 safe final-failure annotations on stderr. Recovered retry attempts do not produce error annotations. An unsuccessful empty/cancelled/exhausted run still has a summary annotation. Identifiers, fixed failure kinds, status and iteration/attempt counts are allowed; response content, labels and raw errors are not. `--quiet` suppresses annotations.

## Baseline versus current

For full comparison, explicitly save raw snapshots:

```sh
rill run ./collection.json --config ./run-config.json --comparison-output ./baseline.json
rill run ./collection.json --config ./run-config.json --comparison-output ./current.json
rill report-diff ./baseline.json ./current.json --json
```

Use distinct report destinations or the explicit `--overwrite` policy when repeating the run. Snapshot format is `kind: "rill.run-snapshot"`, `schemaVersion: 1`. **Raw snapshots contain response bodies and headers, which can contain credentials/private data.** They omit variable maps/credential providers but are not sanitized sharing artifacts. Header capture is off by default; snapshot capture budgets response bodies to 8 MiB total, headers to 4 MiB total/64 KiB per attempt/100 fields, with explicit omission metadata. Portable snapshot/report inputs are capped at 32 MiB. No listener or traffic starts when comparing files.

`report-diff` compares final attempts per request/iteration/visit, preserving repeated branch visits and retry-count changes. It reports before/after state, status, safe check counts, timing, missing visits, normalized body/header changes and structural JSON drift. Snapshot values and response-key names are not echoed in the comparison output. Ordinary version 1 reports can be compared with `--metadata-only`; payload/header equality is then explicitly outside scope. Older unversioned exports must be regenerated for this command.

Native file runs match persisted request IDs. Postman file runs now derive IDs from original structural item pointers, preserving identity under exact folder selection and repeated loading. These positional IDs are deliberately independent of labels, URLs and credentials. Compare the **same logical file**: inserting/reordering/moving Postman items changes positional identities, and unrelated collections can have identical item pointers. Reports do not prove that two supplied inputs are the same collection.

Rules:

- JSON object order and numeric spelling are normalized; string values and property names retain exact UTF-8 identity. Array order matters for value comparison. Structural drift compares object keys/types and sets of array element shapes, not cardinality or full JSON Schema conformance.
- Repeat `--ignore-json /escaped/pointer` to omit selected subtrees from both value and shape comparison. Use `~1` for `/` and `~0` for `~`; invalid escapes reject. An empty pointer explicitly ignores the whole JSON document. Ignore rules can hide real changes, so keep them reviewed with the config/workflow.
- Header names normalize to lowercase; values remain exact, duplicates/order normalize as a sorted multiset. Date, Server and Content-Length are ignored by default. Add `--ignore-header NAME`, or use `--strict-headers` to remove those defaults.
- A latency regression exceeds **both** the percentage threshold (`--latency-percent`, default 20) and absolute increase (`--latency-floor` milliseconds, default 10). These are per-visit samples, not statistically significant performance conclusions.
- Complete non-JSON bodies compare by bytes; schema drift is unavailable for them. Missing/truncated/omitted data is unknown. JSON comparison is bounded to 8 MiB/body, 128 levels, 100,000 values and 1,000 retained differences; structural variants are bounded to 100 per array and shape work to 200,000 nodes per pair.

Exit 4 means observed drift; exit 2 means invalid/incompatible input or an incomplete comparison without observed drift; exit 0 means complete equality **under the selected rules and scope**. `changed` and `complete` are separate machine fields. Output also records metadata-only scope, ignore-rule counts and latency thresholds; raw pointer/header rule text is omitted and should stay with the reviewed invocation/config. Full comparison requires captured bodies/headers and available check sets; metadata-only mode does not turn omitted checks into evidence of equality. Arbitrary assertion values and detailed payload-value diffs remain outside redacted file comparison; the native response inspector supports explicit local value inspection.

A [GitHub Actions example](examples/run-api-checks.yml) builds the exact checkout, passes native named secrets through environment variables, applies a deadline and uploads only the redacted report. Supply its referenced workspace/config and review destinations before copying it into a workflow. File-based mTLS remains supported through the [CLI TLS inputs](CLI.md); provision certificates/passphrases as bounded CI files, not command text. No credentials require an interactive Keychain prompt for file runs.

The [roadmap](../ROADMAP.md) retains independent/installed acceptance and broader performance work. Synthetic fixture tests do not establish general service interoperability or release readiness.
