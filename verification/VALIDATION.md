# Kit validation record

Validated locally on 2026-10-25 against the packaged Rill 0.3.1 CLI. This records **automated kit checks**, not the owner's manual acceptance or a full parity claim. CHECKLIST.csv intentionally has no prefilled results.

- `python3 verification/verify.py --cli …/Rill.app/Contents/Helpers/rill` passed: HTTP methods/query/body, Unicode, authentication accept/reject, OAuth client credentials accept/reject, session, reset/retry, byte/delay limits, 404/500, GraphQL variables/errors and SSE.
- The same self-check executed the native 12-request smoke collection, chained extraction/profile, recovered retry, real timeout diagnostic, wrong assertion/unauthorized/oversized-response exits, five foreign import samples, OpenAPI import, reviewed data-only extension enable/template/disable and sanitized JSON report.
- The ZIP was extracted into a fresh temporary folder outside the repository; CRCs, every SHA256SUMS entry and the endpoint/CLI self-check passed without repository-relative support files.
- Optional grpcio **1.80.0** server passed all four methods through Rill's bundled CLI and an independent Python gRPC client. Python also sent multiple distinct messages for client/bidirectional streaming and checked final/echo results.
- The existing first-party live/MQTT/AMQP/TLS fixtures are reused without copying office code. Synthetic broker behavior does not substitute for independent real broker/TLS/provider testing. Optional TLS fixture behavior has existing automated Rill coverage; actual Keychain imports and human UI checks remain manual.

Reproduce the default endpoint check with `python3 verify.py` after stopping server.py. Use `--cli /absolute/path/to/rill` to include product/import checks. CI runs the kit self-check against its newly built native CLI on every supported build configuration. The optional gRPC dependency is not installed by normal startup or CI.

The downloadable ZIP contains a per-file SHA256SUMS and ORIGIN.json with source revision/dirty state. Rebuild it with `python3 scripts/build-verification-kit.py`. No real tokens, private keys, personal workspaces or runtime reports are packaged; all demo credentials are public dummy values. Disposable TLS keys are generated only when the user starts the optional TLS helper.

## Owner-reported response presentation issue

The owner exercised the intentional status-check failure and supplied a screenshot of HTTP 200 with expected status 201. HTTP delivery and check validation are separate outcomes; the previous green status-only header concealed the latter until the Checks tab was opened. Rill 0.3.2 adds a persistent failed/passed/unconfigured validation banner, a direct check-review action, explicitly labels received HTTP status, and top-aligns the response text within both scroll axes. Shared response tabs and a separate body-action row avoid narrow-pane toolbar crowding. Debug-only synthetic response fixtures cover failed, passed and unconfigured checks in dark/light and compact/wide layouts. These are visual regression evidence, not owner sign-off.

## Bulk tab controls

Rill 0.3.2 adds explicit all/left/right actions in each tab's context menu and the Request menu. Core batch close validates every targeted draft before mutating any tab; discard is explicit and save failure leaves tabs open. Four behavior tests exercise visual-order targeting/anchor preservation, atomic refusal of unsaved changes, explicit discard without modifying saved requests, pinned-tab inclusion/reopen, and preservation of untargeted dirty drafts/pins. Actual prompt interaction remains in the manual checklist.

## Close All performance diagnostic

The owner reported slow tab closure before tabs disappeared. An isolated 100-tab direct-close diagnostic measured approximately 1.6 ms for model mutation and 119 ms including initial UI layout on the development Mac; it did not reproduce a long model-operation stall. The first live sample was idle and inconclusive. A subsequent live sample of installed Rill 0.3.2 captured substantial main-thread work in SwiftUI PlatformItemList updates, NSMenu setItemArray and AppKit menu-item allocation/layout while the context menu was tracking; footprint was about 1.3 GB with a 1.9 GB peak. Raw process samples remain local and are not packaged.

Rill 0.3.3 uses a native snapshot menu for request tabs, without rebuilding active menu items for every observed store update. Commands are deferred into the default run-loop mode after context-menu tracking ends. Ordinary left clicks pass through the overlay; right/control-click provides the same six native menu entries. The Request menu remains available for keyboard/accessibility use. The isolated native-menu diagnostic passed with 100 tabs and 30 live workspace updates: exactly one menu build, six entries, then successful Close All and no reopened tabs. Direct-close layout timing remains around 126 ms; no claim of improving that already-fast path is made. Full live installed-app latency should be rechecked by the owner after upgrading.
