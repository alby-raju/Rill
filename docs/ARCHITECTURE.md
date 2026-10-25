# Architecture

Rill is one Swift package with three production targets and a small test-only native bridge. SwiftPM discovers source files recursively; folders express ownership rather than separate frameworks.

```text
Sources/
  Rill/                    SwiftUI app and AppKit integration
    App/                   App entry, observable workspace store, isolated debug previews
    Components/            Shared controls, native editor and stable tab context menu
    Workspace/             Navigation, response inspection, environments and history
    Requests/              Request/body/workflow composition and interchange views
    Authentication/        Auth, OAuth and TLS profile UI
    Protocols/             gRPC, live streams and broker workbenches
    Tools/                 Runners, definitions, sharing/extensions and offline help
    Resources/             First-party icon and bundled help
  RillCore/                Shared behavior, no SwiftUI dependency
    Workspace/             Models, validated storage, drafts, recovery and imports
    HTTP/                  Preparation, encoding and replayable upload bodies
    Security/              Auth, named secrets, OAuth and trust profiles
    Execution/             Hooks, checks, runners, reports and console rendering
    Inspection/            Response comparison, previews and inspection rules
    Interchange/           Format adapters and frozen-request client generators
    Specifications/        OpenAPI, supported schema contracts and mocks
    Protocols/             Live, gRPC/protobuf, MQTT, Kafka, AMQP and event services
    Integrations/          Git, token-protected sharing and reviewed data extensions
    Support/               Bounded files/processes/parsers and version metadata
  RillCLI/                 Argument parsing and headless command dispatch
Tests/
  RillCoreTests/            Tests grouped by the same behavior domains
  BrokerSupport/           Test-only mock-cluster ABI bridge; never app code
verification/              Synthetic endpoints, sample inputs and manual checklist
scripts/                   Formatting, checks, fixtures and packaging tools
```

## Execution and ownership

The app's `WorkbenchStore` owns selection, drafts, persistence coordination and task lifetimes. UI controls call explicit operations; constructing a request does not send traffic. Keep I/O and parsing off the main actor where applicable. Long operations must support cancellation, deadlines and explicit resource ownership.

HTTP, collection, matrix, load and CLI commands share RillCore preparation and workflow behavior. Changing auth, variable expansion, body semantics or checks in one UI must not create a second incompatible execution engine. Protocol sessions retain their own bounded timelines and cancellation rather than pretending every transport is HTTP.

## Persistence and credentials

`WorkspaceSession` coordinates revision-aware metadata and Keychain operations. `WorkspaceFile` validates portable documents and uses atomic writes; stale revisions must fail without overwriting newer data. Editor checkpoints are separate from saved requests, with an explicit recovery window and Save/Discard/Cancel flow. Imports preview and regenerate identities before applying.

Credentials belong in Keychain, not exported workspaces. Entered URLs, bodies, field/environment values and schema examples can still be sensitive plain text. Reporting/sharing/diagnostic models are allowlisted separately from explicit raw exports. Preserve that distinction when adding fields.

## Native UI boundaries

Shared SwiftUI styles live in Components. Native text editing retains selection, undo, completion and accessibility behavior. Request-tab context menus are AppKit snapshots: build once when opened and defer mutations until tracking ends. Do not bind an active native menu to continuous store updates; live reconciliation previously caused severe allocation/layout churn.

Debug preview/diagnostic states use synthetic stores, temporary directories and isolated preferences. Release builds ignore their command-line flags. Never use a real user workspace for screenshot generation.

## Dependencies and change boundaries

Production dependencies are exact-pinned. The native protobuf compiler and required resources/runtimes ship in the app; generated client programs are text until a user explicitly runs them elsewhere. Test SDKs and optional Python gRPC tooling are not app runtime dependencies.

See [DEPENDENCIES.md](DEPENDENCIES.md) for review and packaging policy, [FEATURES.md](FEATURES.md) for supported subsets, and [SECURITY.md](../SECURITY.md) for trust boundaries.
