# CLI run experience

The native CLI now presents a terminal summary by default for request/collection/folder/contract runs and performance runs. The shared runner, execution/check semantics, exit codes and file exporters remain unchanged. There are no new dependencies and no imported Newman code/assets.

## Delivered

- Human headings use the selected saved name even when the input is a UUID.
- Request visits and all-attempt check counts are separate; failed attempts recovered by retries remain visible without marking the final visit failed.
- Attempts, retries, recovery, skipped/cancelled work, original planned steps, received body bytes and response latency statistics are explicit.
- Summaries include request results and focused terminal-failure diagnostics with allowlisted guidance. Details show every displayed attempt/check with bounded output and explicit omission counts.
- Performance summaries show throughput and nearest-rank p50/p95/p99, minimum/maximum and per-sample details.
- Append-only TTY progress uses stderr. Redirected/JSON/quiet modes have no progress. Colors are supplementary, automatic on capable TTYs, respect NO_COLOR and can be forced/disabled.
- URLs, runtime errors, bodies, field values and check titles are omitted; visible saved names are bounded and stripped of control/format overrides.
- `--json` preserves previous structured run/performance stdout. This is an intentional default-output migration, documented in CLI help, CLI.md and release notes.

## Validation

250 tests pass with local HTTP/TLS/protocol fixtures. Five renderer tests cover recovered retries, failed-check details, allowlisted diagnostics, control injection, empty/cancelled/limited runs, detail bounds, performance percentiles and unexecuted samples. CLI integration tests cover default/detail/JSON/quiet/color modes, invalid options, existing report/raw-output behavior and stable failure exit codes. An actual two-request imported sample collection was executed through the native CLI and both transcripts inspected; saved-name headings were corrected after that review. Live named-request progress was also verified through an actual PTY, read concurrently while the CLI ran.

This is terminal reporting, not an HTML report viewer or Newman compatibility claim. Existing JSON/Markdown/JUnit/Allure exports are available. Manual accessibility/installed-app/real-provider release acceptance and paid signing remain separate deferred gates.
