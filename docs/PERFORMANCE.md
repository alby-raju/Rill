# Performance baselines

Performance work starts with reproducible workloads, not comparisons with other clients.
The first harness measures metadata and offline Postman validation on synthetic
600/5,000/10,000-request files. It does not send requests or open personal data/Keychain.

## Run the harness

Build an optimized executable, then use a new output filename:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build -c release --product RillCLI
python3 scripts/benchmark-cli.py \
  --cli "$(swift build -c release --show-bin-path)/RillCLI" \
  --output /tmp/rill-cli-baseline.json --repetitions 5
```

The script uses deterministic synthetic UUIDs, identical request shapes and loopback URLs
that are never contacted. Each sample starts a separate CLI process. The first invocation
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

## Still required by PERF-01

Native startup/tab/search/close-all interaction and main-thread profiling; many-tab and
large-response workloads; script-heavy native workflows; HTTP connection reuse and report
generation overhead; independent hardware/OS results, stable repetition counts and CI
history/regression thresholds. Preserve installed-resource launch and pane-sizing checks
while optimizing. The broader [roadmap](../ROADMAP.md) remains open.
