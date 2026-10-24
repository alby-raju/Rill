# Rill

A new native macOS API workbench, written from scratch in Swift and SwiftUI. Rill takes its name from a small stream: a quiet workspace for following requests and responses.

Requires macOS 14+ and Swift 6+. No Java, JavaFX, third-party packages, account or hosted workspace.

## Run

```sh
swift run Rill
```

Open `Package.swift` in Xcode to edit and run the app. For a local app bundle:

```sh
zsh scripts/package.sh
```

The bundle is written to `dist/Rill.app`. It is ad-hoc signed for local development; distribution signing and notarization are not configured.

## Implemented

- Native adaptive split-view workspace with collection CRUD, request ordering, global search and templates.
- Persistent request tabs, pin/reopen, separate unsaved drafts, explicit Save/Discard/Cancel and two-second recovery checkpoints.
- Bounded streaming binary/multipart uploads with file change detection and replayable private snapshots.
- HTTP methods, query parameters, headers, text/JSON/XML/form-encoded bodies, JSON formatting, Basic, Bearer and header/query API-key auth; separate None/raw/structured-form body modes.
- Inherited environments and bounded nested `{{name}}` expansion with explicit missing/cyclic-variable errors.
- Native body editor with syntax colors, line numbers, find, zoom, wrap, undo and variable suggestions; lossless JSON formatting.
- Secret-scrubbed `.rillbackup` workspace/draft backups and restore with a retained pre-restore copy.
- Ephemeral URLSession execution, 1–300 second timeout, cancellation, system TLS verification by default and a 16 MiB response limit.
- Safe JSON/XML/HTML-source/text/binary/raster previews, raw export, response metadata, prepared-request inspector and transport timeline.
- Reviewed cURL/HTTPie command import and masked frozen-request command generation; unsupported options fail explicitly.
- Status and body-contains checks.
- Configurable response/preview/history budgets; opt-in durable redacted snapshots (bodies omitted by default), per-exchange inspection and exact semantic JSON comparison.
- Validated, conflict-aware background workspace persistence and Rill JSON import/export with a reviewed import plan and regenerated identities.
- Named TLS trust profiles, custom anchors and Keychain client identities; explicit per-profile insecure development mode.
- Explicit OAuth2 client-credentials and browser PKCE acquisition into named Keychain tokens.
- Authentication credentials in macOS Keychain; reusable auth profiles and named `{{secret:name}}` values with a read-only `RILL_SECRET_` process fallback. Credentials are excluded from exported workspaces.
- System/light/dark appearance and keyboard shortcuts: Cmd+N, Cmd+Enter, Cmd+K, Cmd+Shift+E, Cmd+period.

Network requests start only when you choose Send or explicitly acquire an OAuth token. A fresh workspace has no preconfigured remote endpoint.

## Data

Workspace: `~/Library/Application Support/Rill/workspace.json`.

Saved Auth-tab credentials use Keychain service `app.rill.credentials`; draft credentials use `app.rill.drafts`, and named values use `app.rill.namedsecrets`. Draft checkpoints are separate in `editor-session.json` beside the workspace. Headers, URLs, usernames, bodies and environment values are stored as entered, including any secrets you type there. Exports include those values. Response history is session-only by default. Optional durable snapshots are stored in `exchange-history.json`; retained bodies may contain sensitive data. Avoid credentials in URLs and use the Auth tab for tokens/passwords.

## Verification

```sh
bash scripts/test.sh
```

GitHub Actions builds the release executable and runs the full test suite on Apple Silicon/Intel macOS configurations for pushes to `main`, pull requests, and manual runs. Python is used only for the loopback HTTP fixture; no Python packaging or PyPI workflow is needed.

The suite covers request preparation, validated/conflict-aware persistence, transactional imports, diagnostic redaction, real loopback HTTP responses, cancellation and response limits. See [validation](docs/VALIDATION.md) for the fixture setup and the Xcode toolchain command.

## Roadmap

[M0 reliability](docs/milestones/M0.md) and [M1 workspace/recovery](docs/milestones/M1.md) document implementation, tests and outstanding manual acceptance.

See the [phased roadmap](ROADMAP.md), [122-capability register](docs/roadmap/CAPABILITIES.md) and [acceptance journeys](docs/roadmap/ACCEPTANCE.md) for the path to Relay-level workflow breadth. The audit records missing functionality and supported-subset boundaries without incorporating the original code.

## Scope

This is the first working native foundation, not full parity with the old application. See [implementation status](docs/IMPLEMENTATION.md) for remaining work. No original Java source, scripts, assets, tests or dependencies were copied or translated into this project. The supplied archive's user documentation was read to identify workflows.

Postman v2.0/v2.1 JSON collections and environments can be imported from the File menu with a loss preview. Supported inherited auth is flattened, nested folders become collection breadcrumbs, and marked environment secrets move to Keychain. Scripts, OAuth helper imports and scoped folder/request variables are not supported; unsupported auth/body data fails before Apply. File references require local reselection. See [M3 details](docs/milestones/M3.md).

The File menu also exports Postman collections/environments and an unexecuted HAR request. Masked exports still include bodies, URL paths and unmarked variable values; review before sharing. HAR binary/multipart capture and native auth/TLS profile exports fail explicitly rather than silently changing behavior.

HTTPie Desktop 1.0.0 workspace/collection/request/environment JSON also imports through a reviewed plan, including marked secrets and supported inherited auth. Unsupported path/template/body semantics fail explicitly; see M3 for limitations.

Insomnia v4 JSON and v5 collection/environment YAML import/export are available in File. Imported foreign scripts remain disabled review text (Request → Review Imported Scripts); exporting to Insomnia omits them to prevent foreign auto-execution. YAML uses pinned Yams 6.2.2 with bounded event preflight; dependency notices ship in the app bundle. See [parser decision](docs/decisions/yaml-parser.md) and [M3 limits](docs/milestones/M3.md).

Bruno `.bru` requests/environments and collection folders/ZIPs now import with bounded path/file/archive validation. Export creates a valid ZIP bundle with `bruno.json`, supported raw requests and plain environments; form/file-body exports fail before writing. The supported two-space Bru subset, omitted defaults and other limitations are documented in M3. Referenced uploads and `.env` files are never read by folder import, and foreign scripts remain disabled review text. See the [ZIP dependency and limits decision](docs/decisions/zip-parser.md).

Request → Generate Command also provides Python requests/httpx, Node fetch/axios, Java HttpClient/OkHttp, Go, Rust reqwest and C# client programs. Captured raw/binary/multipart bodies embed exact bytes up to 1 MiB; common credential headers mask by default. Review source before sharing or executing. SDK dependencies are hints and are not installed by Rill; TLS profiles and unrepresentable headers fail explicitly. See [M3 scope and validation](docs/milestones/M3.md).

Request → Collection Runner / Matrix / Load runs saved snapshots with explicit retries, pacing, cancellation, bounded retained results, isolated environment comparisons and load latency metrics. The Workflow tab adds assertions, extraction and opt-in finite native JSON hooks; foreign JavaScript stays disabled. Reports default to redacted JSON, Markdown, JUnit and Allure files. [Supported operations, limits and pending acceptance](docs/milestones/M4.md).
