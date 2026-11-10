# Performance baselines

Performance work starts with reproducible workloads, not comparisons with other clients.
The harness measures metadata and offline Postman validation on synthetic
600/5,000/10,000-request files. Optional loopback workloads measure scripted execution and
reporting. The harness uses temporary files and local endpoints.

## Run the harness

Build an optimized executable, then use a new output filename:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build -c release --product RillCLI
python3 scripts/benchmark-cli.py \
  --cli "$(swift build -c release --show-bin-path)/RillCLI" \
  --output /tmp/rill-cli-baseline.json --repetitions 5
```

Add `--include-runs` to measure a scripted Postman run with no report, with a JSON report,
and with an NDJSON report at each size. The fixture binds to an ephemeral loopback port,
checks request order and a header added by the pre-request script, and returns JSON that
the post-response script checks. The 600-request workload returns 64 KiB per request.
The 5,000- and 10,000-request workloads return 1 KiB per request. The record includes
accepted TCP connections, response bytes and report bytes for each run sample.

Native and Postman file runs reuse connections for eligible plain HTTP GET and HEAD
requests. The pool is scoped to one run and one active origin. The task delegate still
checks redirects against the request's origin. HTTPS, request bodies, cookie jars and
requests with URL credentials or explicit authorization or cookie headers use their own
sessions. Reports remain redacted and bounded. Versioned JSON exports encode the report
and its schema metadata in one pass.

The script uses deterministic synthetic UUIDs and identical request shapes. Each sample
starts a separate CLI process. The first invocation
is recorded separately; repeated samples benefit from OS caches. These are not truly cold
cache measurements: the harness does not reboot, flush caches or control thermal state.
macOS `/usr/bin/time -l` records per-process peak resident memory in bytes. The JSON records
the source revision/dirty state, binary hash, version, OS, architecture, CPU count, every
sample, median, nearest-rank p95 and maximum peak RSS. Outputs are exclusive. Use the same
hardware, optimized build and sample conditions for comparisons; small sample p95 is the
maximum, not a reliable population estimate.

## Initial local measurement: 5 November 2026

Apple M5 Pro, 24 GiB RAM, 15 logical CPUs, arm64, macOS 27.2. Optimized packaged CLI;
three repeated samples after the first invocation. Working tree based on `d9e1be2` plus
the CLI discovery/packaging increment. This is local development evidence, not an
exact-source release gate or installed Intel result. Raw JSON is generated under ignored
`dist`; the harness can regenerate it and records the binary digest.

| Requests | Operation | Median ms | Sample p95 ms | Maximum RSS MiB |
| ---: | --- | ---: | ---: | ---: |
| 600 | List native workspace | 19.5 | 19.7 | 11.3 |
| 600 | Search native workspace | 22.2 | 22.4 | 12.3 |
| 600 | Postman preflight | 24.3 | 24.7 | 11.6 |
| 5,000 | List native workspace | 62.2 | 63.4 | 27.5 |
| 5,000 | Search native workspace | 65.4 | 65.9 | 26.3 |
| 5,000 | Postman preflight | 107.5 | 107.8 | 22.2 |
| 10,000 | List native workspace | 111.8 | 111.9 | 44.0 |
| 10,000 | Search native workspace | 116.2 | 116.8 | 39.7 |
| 10,000 | Postman preflight | 198.1 | 199.2 | 34.0 |

No speed claim against Postman, Newman or HTTPie follows from these measurements. Their
equivalent workloads, setup and distributions have not been measured. CLI metadata timings
also do not measure native search interaction or frame/main-thread latency.

## Scripted loopback runs: 10 November 2026

Apple M5 Pro, 24 GiB RAM, 15 logical CPUs, arm64, macOS 27.2.1. Optimized CLI built from
`bdbf252` with the connection and reporting changes in the working tree. Three repeated
samples followed the first invocation for each row. All 36 runs passed, and 35 used one TCP
connection. The first 5,000-request NDJSON run used two. The harness includes CLI startup,
plan preparation, HTTP traffic, checks, summary and any report write in elapsed time.

| Requests | Export | Median s | Sample p95 s | Maximum RSS MiB |
| ---: | --- | ---: | ---: | ---: |
| 600 | None | 0.616 | 0.622 | 52.8 |
| 600 | JSON | 0.622 | 0.628 | 55.9 |
| 600 | NDJSON | 0.619 | 0.628 | 53.6 |
| 5,000 | None | 1.709 | 1.710 | 48.1 |
| 5,000 | JSON | 1.744 | 1.745 | 66.0 |
| 5,000 | NDJSON | 1.752 | 1.772 | 51.8 |
| 10,000 | None | 3.389 | 3.391 | 77.0 |
| 10,000 | JSON | 3.460 | 3.469 | 114.7 |
| 10,000 | NDJSON | 3.619 | 3.621 | 84.8 |

The 10,000-request reports occupied approximately 6.6 MiB in JSON and 5.6 MiB in NDJSON.
These local samples characterize one scripted workload per size. TLS, remote latency and
independent hardware results require separate measurements.

## Still required by PERF-01

Native startup/tab/search/close-all interaction and main-thread profiling; many-tab and
script-heavy native workflows; independent hardware/OS results, stable repetition counts and CI
history/regression thresholds. Preserve installed-resource launch and pane-sizing checks
while optimizing. The broader [roadmap](../ROADMAP.md) remains open.
