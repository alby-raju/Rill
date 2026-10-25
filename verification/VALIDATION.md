# Kit validation record

Validated locally on 2026-10-25 against the packaged Rill 0.3.1 CLI. This records **automated kit checks**, not the owner's manual acceptance or a full parity claim. CHECKLIST.csv intentionally has no prefilled results.

- `python3 verification/verify.py --cli …/Rill.app/Contents/Helpers/rill` passed: HTTP methods/query/body, Unicode, authentication accept/reject, OAuth client credentials accept/reject, session, reset/retry, byte/delay limits, 404/500, GraphQL variables/errors and SSE.
- The same self-check executed the native 12-request smoke collection, chained extraction/profile, recovered retry, real timeout diagnostic, wrong assertion/unauthorized/oversized-response exits, five foreign import samples, OpenAPI import, reviewed data-only extension enable/template/disable and sanitized JSON report.
- The ZIP was extracted into a fresh temporary folder outside the repository; CRCs, every SHA256SUMS entry and the endpoint/CLI self-check passed without repository-relative support files.
- Optional grpcio **1.80.0** server passed all four methods through Rill's bundled CLI and an independent Python gRPC client. Python also sent multiple distinct messages for client/bidirectional streaming and checked final/echo results.
- The existing first-party live/MQTT/AMQP/TLS fixtures are reused without copying office code. Synthetic broker behavior does not substitute for independent real broker/TLS/provider testing. Optional TLS fixture behavior has existing automated Rill coverage; actual Keychain imports and human UI checks remain manual.

Reproduce the default endpoint check with `python3 verify.py` after stopping server.py. Use `--cli /absolute/path/to/rill` to include product/import checks. CI runs the kit self-check against its newly built native CLI on every supported build configuration. The optional gRPC dependency is not installed by normal startup or CI.

The downloadable ZIP contains a per-file SHA256SUMS and ORIGIN.json with source revision/dirty state. Rebuild it with `python3 scripts/build-verification-kit.py`. No real tokens, private keys, personal workspaces or runtime reports are packaged; all demo credentials are public dummy values. Disposable TLS keys are generated only when the user starts the optional TLS helper.
