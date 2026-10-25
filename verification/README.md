# Rill manual verification kit

Synthetic data and local endpoints for **your own hands-on checks**. This kit does not read or modify your normal Rill workspace, start Docker, install dependencies or change system trust automatically. Start it from a Terminal window and keep that window open. Python 3 is required (`python3 --version`).

## Start here

1. Unzip `Rill-Verification-Kit.zip` and open Terminal in the extracted folder:

   ```sh
   cd ~/Downloads/Rill-Verification-Kit
   python3 server.py
   ```

   In a repository checkout, use `cd verification` first. Startup must print **Rill verification kit ready**. If any port is occupied, startup fails and releases its other ports. All listeners bind to 127.0.0.1. Ctrl+C stops them.

2. Open Rill. Choose **File → Import Rill Workspace…** (or sidebar **Workspace files → Import Rill workspace…**) and select `materials/rill-workspace.json`. **Do not select Import HTTPie Desktop JSON, Postman, or command import for this native file.** Review the preview and apply. It contains 19 requests in four clearly named `Kit — …` collections. Existing requests should remain intact. Choose the imported **Verification local** environment so `{{base_url}}` resolves.
3. Run **Kit — Smoke**: every request should pass. Run **Kit — Workflow** in saved order: session creation returns 201; extraction makes the next authenticated profile request pass. Sending the second request alone has no run-local token and should fail before sending.
4. Reset retry state by sending **POST http://127.0.0.1:18990/reset** with body `{}`. Run **Kit — Retry** with **one retry**: attempt 1 returns 503, attempt 2 returns 200; the final run passes with one recovered retry.
5. **Kit — Expected failures is supposed to fail.** It contains a wrong expected status, short timeout, missing authentication and oversized response. Test separately before trying continue-on-failure. A passing **check result** for these unchanged cases is a problem. HTTP 200 can still be correct for the intentional assertion failure: it expects 201, so its response check must fail. In Rill 0.3.1 use response **Checks** to inspect this; 0.3.2 adds a persistent red failed-check banner independent of the HTTP badge.
6. Copy `CHECKLIST.csv` to `results/` and record pass/fail, Rill version, macOS/CPU and notes/screenshots. Close/reopen Rill and retest persistence. Synthetic fixtures exercise functionality; they do not establish full standards conformance or independent broker acceptance.

### Quick self-check (separate from manual acceptance)

Stop `server.py` first; the self-check owns the same ports and stops its services afterward:

```sh
python3 verify.py
python3 verify.py --cli /Applications/Rill.app/Contents/Helpers/rill
```

Use the actual installation path. From a checkout, the development CLI can be `../dist/Rill.app/Contents/Helpers/rill`. The optional CLI check writes only to a disposable temporary workspace. It does not validate the UI or automatically complete your checklist.

### If import says “Expected a bounded HTTPie Desktop 1.0.0 JSON …”

The HTTPie Desktop importer was selected for a different file format. For the kit workspace use **File → Import Rill Workspace… → materials/rill-workspace.json → Apply Import**, then select **Verification local**. Importer validation errors occur before incoming changes are applied. The welcome screen's **Import request** action is for commands/HAR, not native workspaces.

## Endpoint directory

Main base URL: **http://127.0.0.1:18990**.

| Method and path | What to verify | Expected result |
|---|---|---|
| GET `/health` | Basic connectivity | 200, `ok: true` |
| GET `/json` | JSON tree/pretty/raw, checks, search/copy | 200; id 42, two items, Unicode |
| Any supported HTTP method `/echo?tag=one&tag=two&empty=` | Repeated query, enabled headers, URL encoding | Returns method, query arrays, headers, body text/base64/byte count |
| POST `/echo` | Raw JSON, form, multipart and binary bodies | Inspect exact body/base64 and Content-Type; server doesn't parse multipart into fields |
| POST `/session` | Start chained workflow | 201; token `rill-demo-token`, user id `user-42` |
| GET `/profile` | Extraction/substitution | 200 with `Authorization: Bearer rill-demo-token`; 401 without |
| GET `/auth/basic` | Basic auth editor/profile | Username `rill`, password `demo-password`; 200, wrong/missing values 401 |
| GET `/auth/bearer` | Bearer auth editor/profile | Token `rill-demo-token`; 200, missing/wrong token 401 |
| GET `/auth/api-key` | API key auth editor/profile | Header `X-API-Key: rill-demo-key`; 200, missing/wrong key 401 |
| POST `/oauth/token` | OAuth client credentials | URL-encoded grant_type=client_credentials, client_id=rill, client_secret=demo-password (or Basic auth); returns demo bearer token; wrong credentials fail |
| GET `/status/201`, `/status/404`, `/status/500` | Status checks | Requested status |
| GET `/flaky?key=manual` | Retries | First request per key is 503, later requests 200; reset before repeating |
| POST `/reset` | Reset flaky counters | 200; clears only fixture state |
| GET `/delay/3` | Timeout/cancel and UI responsiveness | Responds after 3 seconds; timeout 1 second must fail |
| GET `/bytes/614400` | Preview truncation vs retained/exported bytes | 600 KiB of `x`; preview should disclose truncation |
| GET `/bytes/17825792` | 16 MiB HTTP response limit | Must fail instead of displaying a successful complete response |
| GET `/xml`, `/html`, `/image` | Response format rendering | XML, synthetic HTML, 1px PNG respectively |
| GET `/invalid-json` | Invalid JSON handling | HTTP 200 but invalid JSON; formatting/schema checks must not silently pass |
| GET `/redirect` | Explicit redirect policy | 302 Location `/json`; no silent redirect under the current default policy |
| GET `/unknown` | Error inspection | 404 JSON |

All credentials above are deliberately public dummy strings. Auth requests in the supplied collection use literal headers to stay portable. **To verify the actual auth UX**, duplicate those requests, remove the explicit Authorization/X-API-Key header and configure the corresponding Auth controls. Test correct, incorrect and missing credentials. Use a uniquely named demo Keychain secret if testing reusable profiles; delete it yourself afterward.

For OAuth client-credentials UI testing use token endpoint `http://127.0.0.1:18990/oauth/token`, client ID `rill` and a demo named secret containing `demo-password`. Browser PKCE is not provided by this kit and still needs a separate provider.

## Bodies, editors and persistence

- POST `/echo`, raw JSON: paste `materials/payload.json`, format, search, wrap, zoom, undo and send. Check Unicode and exact body bytes.
- Form fields: `name=Rill demo`, `tag=one`, `tag=two`, plus a disabled field. Echo must show form Content-Type and only enabled values.
- Multipart: add a text field and select `uploads/sample.txt` plus `uploads/sample.bin` through Rill's file picker. Inspect boundary/content-disposition and body size in the echo. Files are not automatically attached by import.
- Binary: select `uploads/sample.bin`; echoed `bodyBytes` must be **1024**. Rename/change the file after selecting it; Rill must require reselection instead of silently sending different content.
- XML: use `uploads/sample.xml`; choose application/xml.
- Schema: `payload.schema.json` accepts `payload.json` and rejects `payload-invalid-schema.json` (wrong name type/negative quantity). For response validation use a schema matching `/json`, or import the OpenAPI definition.
- Hooks: paste the contents of `pre-hook.json` / `post-hook.json` into the corresponding hook editor and enable explicitly. The pre-hook adds an `X-Request-ID` UUID. These files are Rill JSON operations, not JavaScript or Postman SDK scripts.
- Make unsaved edits; test Save/Discard/Cancel, tabs/pins/reopen, ordering, search, resize, light/dark, keyboard and restart. Use a disposable request for delete/restore tests.
- Right-click a request tab, or use the Request menu, for **Close All Tabs**, **Close Tabs to the Left** and **Close Tabs to the Right** (Rill 0.3.2). Left/right are relative to the clicked tab; the Request menu uses the active tab. Explicit bulk close includes pinned tabs. One Save All/Discard Changes/Cancel prompt covers unsaved target tabs; Cancel must keep all tabs open, and a failed save must not close them. Closing tabs must not delete saved requests. Reopen Closed Tab retains the existing last-20 history limit.

## Import/export, definitions and negative files

| File | How to use | Expected |
|---|---|---|
| `rill-workspace.json` | Native import | Four collections, 19 requests, local environment |
| `postman-collection.json`, `postman-environment.json` | Postman import | Three requests and a base_url variable environment; native checks/hooks are not included in this interchange sample |
| `insomnia-v4.json` | Insomnia import | Health request and base environment |
| `health.bru` | Bruno file import | One health request |
| `request.har` | HAR import | One GET /json request |
| `commands.txt` | Paste each command separately into command import | cURL POST and HTTPie GET |
| `openapi.json` | API definition import | Health and JSON operations with linked response expectations |
| `openapi-updated.json` | Refresh the same source using replacement contents/location | Adds POST /echo; existing unchanged operations retain IDs/local edits |
| `invalid-json.json` | Native import/JSON editor | Clear rejection; existing workspace unchanged |
| `invalid-duplicate-ids.json` | Native import | Duplicate identity rejection; existing workspace unchanged |
| `mock-routes.json` | Mock tool route import / CLI --routes | GET /demo returns mocked=true; POST /orders returns 201/id42 |

Export the sample requests to each supported format, then import into a separate empty workspace. Compare enabled fields, bodies, auth policy, Unicode and grouping; read every omission warning. Back up before testing restore. Backup/restore and malformed-file tests should never overwrite the original on failure. No hostile executable or foreign script is included.

## GraphQL, SSE and WebSocket

These run on **port 18991**, not the main API port.

| Tool | Endpoint / input | Expected |
|---|---|---|
| GraphQL | `http://127.0.0.1:18991/graphql`; `query.graphql`, `graphql-variables.json` | HTTP responder returns `data.echo` containing supplied variables and `data.query`; introspection returns a small synthetic schema with hello(recipient) |
| GraphQL error | `http://127.0.0.1:18991/graphql-errors` | GraphQL errors despite HTTP 200 |
| Introspection disabled | `http://127.0.0.1:18991/graphql-disabled` | Visible refusal rather than a fabricated schema |
| Subscription | `ws://127.0.0.1:18991/subscription`; `subscription.graphql`, graphql-transport-ws | Acknowledgement, data value 1 and complete |
| Subscription negative | `ws://127.0.0.1:18991/subscription-no-ack` | Acknowledgement timeout, clean closure |
| WebSocket | `ws://127.0.0.1:18991/echo` | Text/binary echo, ping; disconnect and reopen |
| SSE | `http://127.0.0.1:18991/sse` | Named update event, Unicode, persistent/reset IDs, multi-line data |
| SSE negatives | `/sse-bad`, `/sse-stall` | MIME rejection; cancel a stalled stream |

The GraphQL fixture is a synthetic protocol responder, **not a general GraphQL execution engine**. Its schema/query behavior intentionally exercises Rill's plumbing rather than GraphQL business logic. Stream payloads are synthetic and may be displayed safely.

## MQTT, AMQP, CloudEvents

These are **wire-level fixtures, not production brokers**. They test local controls, frame handling and timelines; persistence, cluster behavior, independent interoperability and real TLS/auth must still be checked separately.

- MQTT: `mqtt://127.0.0.1:18992`, version 3.1.1 or 5. Subscribe and publish on `rill/demo` **in the same connection**. Test QoS0/1/2, retained flag and payload `{"hello":"Rill"}`. `reject/#` is an intentional subscription rejection. WS transport: `ws://127.0.0.1:18991/mqtt`.
- AMQP: `amqp://127.0.0.1:18993`, vhost `/`, username/password `demo`/`demo`, existing queue **existing**, default exchange. Subscribe then publish in the same session. Queue **missing** must fail; a credential containing `reject` deliberately fails authentication. No queue creation occurs.
- CloudEvents: use `cloudevent.json` as a structured payload, or enter source `urn:rill:verification`, type `dev.rill.order.created` and data `{"orderId":42}` in Rill's composer. Test valid JSON and invalid JSON. MQTT5 can carry its content type; MQTT3 cannot carry that metadata.
- Kafka: this kit does **not** provide a Kafka broker. Use an independently operated test cluster for latest-only consumption, acknowledged publishing, TLS/SASL and no-offset-commit acceptance. Never use production data for destructive checks.

## Optional gRPC — real HTTP/2 server

The default kit needs only Python's standard library. gRPC is optional and needs the external `grpcio` package in a disposable virtual environment:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r grpc-requirements.txt
.venv/bin/python grpc_server.py
```

This follows the [official Python installation guide](https://grpc.io/docs/languages/python/quickstart/) and [generic handler API](https://grpc.github.io/grpc/python/grpc.html). The optional dependency is pinned to grpcio 1.80.0, verified with Rill for all four call modes. No generated Python protobuf files are needed: handlers echo the serialized EchoMessage bytes. No reflection or TLS endpoint is provided here.

In Rill load `materials/echo.proto`, connect to **grpc://127.0.0.1:18994**, choose `rill.kit.Echo` and paste `grpc-message.json`:

- Unary: one identical response.
- ServerStream: three identical responses then completion.
- ClientStream: send two messages, Finish sending; returns the final message.
- Bidi: one echo for each sent message; Finish sending ends the call.

Deadlines and Cancel must terminate cleanly. The server bounds message size to 1 MiB, concurrency to eight calls and client/bidi streams to 100 messages. For reflection, custom trust and mTLS acceptance use a separately configured real service.

## Optional HTTP TLS/mTLS

Requires an installed `openssl` executable. In a separate Terminal, from this kit folder:

```sh
mkdir -p results
python3 support/tls-fixture.py results/tls
```

In a repository checkout replace `support/tls-fixture.py` with `../scripts/tls-fixture.py`. It generates disposable two-day certificates and serves HTTPS on **localhost:18750**, mTLS on **localhost:18751**. Stop with Ctrl+C. Default trust must reject both. Create a Rill custom-trust profile using `results/tls/ca.der` or `ca.pem`; localhost:18750 should return `{"message":"TLS fixture"}`. Using **127.0.0.1** instead must fail hostname validation. mTLS must fail without a client identity. If you choose to test Keychain import, import `client.p12` with dummy password **rill-fixture**, select it in the TLS profile, then test mTLS success. This explicitly adds a test identity to your Keychain; remove it yourself afterward. Do not add this CA to global system trust. Regenerate expired certificates.

## CLI examples

Create an alias or substitute the full packaged executable path for `rill`. Use the supplied workspace explicitly so commands don't touch your normal workspace:

```sh
rill list --workspace materials/rill-workspace.json
rill run-collection 'Kit — Smoke' --workspace materials/rill-workspace.json --detail
rill run-collection 'Kit — Workflow' --workspace materials/rill-workspace.json --detail
curl -X POST http://127.0.0.1:18990/reset -d '{}'
rill run-collection 'Kit — Retry' --workspace materials/rill-workspace.json --retries 1 --detail
rill run-request 'Intentional assertion failure' --workspace materials/rill-workspace.json --detail
rill perf Health --workspace materials/rill-workspace.json --count 20 --concurrency 2 --detail
```

Expected assertion exit code is 4; timeout/transport/response-limit is 3; usage errors 2; Ctrl+C 130; successful runs 0. Add `--report results/run.json`, `--report-format markdown|junit`, `--allure results/allure`, or `--json` as needed (create results first). Output files refuse overwrite unless explicit. `rill mock-serve --routes materials/mock-routes.json --port 18995` starts a separate mock endpoint. It stops with Ctrl+C.

## Disposable Git, sharing and extensions

Use a **copy** of the kit workspace for these actions and choose a fresh folder under `results/` for Git. Git init/status/export/commit should affect only that selected folder. Review entered field/body/environment content before committing, even though this kit contains only synthetic values. No push is required.

Start a read-only local share with a generated token file in results; GET without a token must fail, and the authorized pull must contain a sanitized snapshot with fresh identities. Never choose an existing workspace as the pull destination. Stop the share and confirm the listener closes.

Select `materials/plugins` as the extension root. The `rill-kit` extension offers a health request template and two mock routes. It is **data only**. Before explicit approval, services should be disabled; after approval the health template imports with a fresh request ID. Work on a copy: alter a service file after approval and confirm that content changes invalidate approval. Disable the extension afterward. No executable plugin code is supplied.

## Reporting findings

Record request name, exact steps, expected/actual result, app version, macOS/CPU, screenshot or redacted report and whether the issue survives restart. Use CHECKLIST.csv as a template; **nothing is pre-marked passed**. These checks cover many roadmap journeys but do not replace actual fresh-machine, real-provider, full format/conformance, accessibility or release-signing acceptance. Paid signing remains deferred.
