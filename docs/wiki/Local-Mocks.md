# Local mock servers

Development source provides **Workspace tools → Sessions and testing → Local Mocks**. The Mocks tab inside API Definitions and Tools uses the same workbench. These additions are not in the published v0.4.5-dev.1 preview.

Create a project, add routes and choose **Start**. Port 0 selects an available loopback port. Copy its base URL or a route's cURL example. Servers keep running when their editor closes; **Stop**, project deletion or app termination stops them. Nothing starts automatically on launch or import. Up to four listeners can run concurrently. A changed route or port requires **Restart**; the running listener continues serving its previous snapshot until then.

Projects and unapplied JSON drafts save with the workspace. The route forms cover method/path, required query/header predicates, an optional exact UTF-8 body, response headers/body/status, delay and disconnect faults. Routes are evaluated in displayed order, so put specific cases before a general fallback. Use **Move up/down** to change precedence. `{parameter}` matches one nonempty path segment. Unmatched requests return 404.

A scenario has a name, required state and optional next state. Its initial state is `start`; a match advances it before response delay. **Calls → Reset scenarios and calls** restores deterministic initial state. Calls retain at most 1,000 metadata entries in memory; query strings, headers and payloads are omitted. Paths may contain identifiers. Stopping/restarting discards the session journal.

The JSON editor accepts the route-array format below. Its unapplied draft persists until **Apply JSON** or **Discard draft**. Applying a valid draft replaces applied routes; it does not restart a listener. Project export contains applied routes, never draft text or runtime state. Configuration is plain text; review payloads before sharing.

Generate fixtures from supported OpenAPI examples using **API Definitions and Tools → Definitions → Generate editable mock routes**. **From response…** makes a structural template of the selected response: all JSON scalar values are replaced, original headers/URL are omitted, and the route uses `/recorded-response`. JSON key names remain and require review. Non-JSON payloads become a placeholder. Both workflows record source provenance; neither proves schema conformance.

## Same configuration in the CLI

Export a project from the workbench, then run:

```sh
rill mock-serve --project ./mock-project.json --port 0 --json
```

Readiness is one compact JSON line with `schemaVersion: 1`, `state: "ready"`, `baseURL` and `routeCount`. Ctrl+C or SIGTERM stops the listener and exits 130. A port override takes precedence over the saved port. Invalid configuration or an occupied port fails; no LAN bind option exists.

For CI, `--control-stdin` enables newline-terminated `status`, `reset` and `stop` commands. Each command is limited to 64 bytes; invalid commands fail closed. `status` emits a compact count record; `reset` clears scenario state and calls and acknowledges reset. EOF or `stop` tears down normally. Control stays on the explicitly supplied pipe, without an HTTP administration endpoint.

Legacy route arrays still work:

```sh
rill mock-serve --routes ./verification/materials/mock-routes.json --port 18995
```

A version 1 project uses `kind`, `version`, `name`, `port` and `routes`:

```json
{
  "kind": "rill.mock-project",
  "version": 1,
  "name": "Synthetic checkout",
  "port": 0,
  "routes": [{
    "method": "POST",
    "path": "/orders/{id}",
    "query": [{"name": "mode", "value": "test"}],
    "requestHeaders": [{"name": "X-Fixture", "value": "yes"}],
    "requestBody": "{}",
    "status": 201,
    "headers": {"Content-Type": "application/json"},
    "body": "{\"created\":true}",
    "delayMilliseconds": 30,
    "scenario": {"name": "checkout", "requiredState": "start", "nextState": "created"}
  }]
}
```

Optional `fault: "disconnect"` closes without a response. Query names/values and body bytes are exact; header names are case-insensitive and values exact. Extra parameters/headers are allowed. Repeated query predicates require presence, not multiplicity. Duplicate match signatures reject; overlapping patterns use first match. Response status is 200–599; delays are 0–10,000 ms. HEAD omits payload bytes, and 204/304 responses omit bodies.

Limits: 16 saved projects, 1,000 total routes, 2 MiB portable files, 4 MiB total unapplied JSON, 16 MiB response-body storage, 1 MiB per body, 100 fields per group, 32 active connections per listener, 16 KiB request headers, 1 MiB request bodies and five-second read/write deadlines. Payload delay is bounded separately. No route scripts, TLS listener, proxy recording or arbitrary network replay is provided. See the [roadmap acceptance](https://github.com/alby-raju/Rill/blob/main/ROADMAP.md#3-first-class-mock-workbench) and [features and limits](https://github.com/alby-raju/Rill/blob/main/docs/FEATURES.md).
