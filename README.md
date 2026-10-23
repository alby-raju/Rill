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

- Native split-view workspace with collection navigation, searchable requests, editable names, duplication, deletion and collection assignment.
- HTTP methods, query parameters, headers, text/JSON/XML/form-encoded bodies, JSON formatting, Basic and Bearer auth.
- Environment variables using `{{name}}`, explicit errors for unresolved values, and enable/disable controls.
- Ephemeral URLSession execution, 1–300 second timeout, cancellation, default system TLS verification and a 16 MiB response limit.
- Response body, formatted JSON, selectable text, copy/export, headers, status, latency and size.
- Status and body-contains checks.
- Session history bounded to 50 exchanges and 32 MiB of bodies.
- Atomic local workspace persistence and Rill JSON import/export with regenerated identities.
- Authentication credentials in macOS Keychain; credentials excluded from exported workspaces.
- System/light/dark appearance and keyboard shortcuts: Cmd+N, Cmd+Enter, Cmd+K, Cmd+Shift+E, Cmd+period.

Requests are sent only when you choose Send. A fresh workspace has no preconfigured remote endpoint.

## Data

Workspace: `~/Library/Application Support/Rill/workspace.json`.

Auth-tab credentials use Keychain service `app.rill.credentials`. Headers, URLs, usernames, bodies and environment values are stored as entered, including any secrets you type there. Exports include those values. Response history is session-only. Avoid credentials in URLs and use the Auth tab for tokens/passwords.

## Verification

```sh
bash scripts/test.sh
```

GitHub Actions builds the release executable and runs the full test suite on macOS for pushes to `main`, pull requests, and manual runs. Python is used only for the loopback HTTP fixture; no Python packaging or PyPI workflow is needed.

Ten cases cover request preparation, persistence, real loopback HTTP responses, cancellation and response limits. See [validation](docs/VALIDATION.md) for the fixture setup and the Xcode toolchain command.

## Roadmap

See the [phased roadmap](ROADMAP.md), [122-capability register](docs/roadmap/CAPABILITIES.md) and [acceptance journeys](docs/roadmap/ACCEPTANCE.md) for the path to Relay-level workflow breadth. The audit records missing functionality and supported-subset boundaries without incorporating the original code.

## Scope

This is the first working native foundation, not full parity with the old application. See [implementation status](docs/IMPLEMENTATION.md) for remaining work. No original Java source, scripts, assets, tests or dependencies were copied or translated into this project. The supplied archive's user documentation was read to identify workflows.
