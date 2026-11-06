# Rill

[![Swift CI](https://github.com/alby-raju/Rill/actions/workflows/swift.yml/badge.svg)](https://github.com/alby-raju/Rill/actions/workflows/swift.yml) [![Security](https://github.com/alby-raju/Rill/actions/workflows/security.yml/badge.svg)](https://github.com/alby-raju/Rill/actions/workflows/security.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**A native macOS API workbench, built with Swift and SwiftUI.**

Compose requests, inspect responses, run API workflows, and explore live protocols in a local workspace. Rill works without an account or hosted workspace. Its name comes from a small stream.

[Wiki](https://github.com/alby-raju/Rill/wiki) · [Get started](#get-started) · [Features and limits](docs/FEATURES.md) · [CLI](docs/CLI.md) · [Contribute](CONTRIBUTING.md) · [Roadmap](ROADMAP.md) · [Community and support](SUPPORT.md)

![Rill workbench with a request and validated JSON response](docs/images/workbench-dark.png)

## Rill 0.4.5 development preview

[Download Rill 0.4.5](https://github.com/alby-raju/Rill/releases/tag/v0.4.5-dev.1) for **macOS 15+**. Choose the `arm64` installer for Apple Silicon or the `x86_64` installer for Intel. The preview includes the native app, CLI, and a separate verification kit.

Development installers are ad-hoc signed. Paid Developer ID signing and notarization are deferred. See [installation and release notes](docs/RELEASE.md) for the exact distribution status and remaining acceptance gates.

## Where Rill is heading

Direct collection-file execution is available in this preview. Development source since this preview adds final-environment export, opt-in runner cookies, offline HTML reports, doctor/completions, CLI-only packaging, an explicit [bounded script workflow subset](docs/SCRIPT-SUBSET.md), a [saved mock workbench](docs/wiki/Local-Mocks.md) shared with the CLI, and [versioned run configs, snapshots and comparison](docs/RUN-INVESTIGATION.md); these additions are not in the linked installer yet. Broader compatibility and independent acceptance remain active work. Initial CLI performance baselines are recorded; broader performance acceptance and Linux/Windows portability remain on the [prioritized roadmap](ROADMAP.md).

## What you can do

- Organize collections, tabs, drafts and inherited environments. Open **Workspace tools** to find request setup, sessions, protocol tools, and workspace files.
- Command-click to select individual requests or Shift-click for a range. Use the selection menu to move, copy, duplicate or delete the batch. Select all visible requests from Collection actions.
- Send HTTP requests with JSON/XML/text, forms, multipart and binary uploads; configure auth, named Keychain secrets and TLS profiles.
- Reuse cookies automatically across matching Workbench HTTP requests and inspect or clear them in Cookie Manager. The jar lasts until Rill quits.
- Inspect bodies, headers, checks and timelines. Validation results stay visible separately from HTTP status.
- Chain requests with assertions, extraction, finite opt-in hooks, retries, environment matrices and bounded load tests.
- Import/export supported Postman, Insomnia, Bruno, HAR and HTTPie representations; generate client snippets.
- Work with OpenAPI/Swagger, supported JSON Schema contracts, local mocks and explicit inspection tools.
- Explore GraphQL, subscriptions, WebSocket, SSE, gRPC, MQTT, AMQP and Kafka within the [published limits](docs/FEATURES.md).
- Run supported Postman and native collection files from the CLI with iteration data, temporary inputs, scoped file-based TLS and redacted reports. See the [CLI guide](docs/CLI.md) for the supported subset.

![Rill welcome screen with workspace entry points](docs/images/welcome-light.png)

Screenshots use synthetic sample data rendered by the actual app. No personal workspace or credentials are shown.

## Get started

Open the disk image for your Mac and copy Rill to Applications. For your first request, choose **New request**, enter a URL, then click **Send**. Open **Workspace tools** for environments, authentication, history, and other tools.

To build from source, install full **Xcode 26.2+** with **Swift 6.2.3+**:

```sh
git clone https://github.com/alby-raju/Rill.git
cd Rill
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift run Rill
```

Open `Package.swift` in Xcode if you prefer the IDE. To create a local app bundle:

```sh
zsh scripts/package.sh
```

The output is `dist/Rill.app`; its bundled CLI is `dist/Rill.app/Contents/Helpers/rill`. Packaging includes the selected native runtimes, official protobuf compiler, licenses and offline help. It does not require Java or install a hosted service.

## Try it with local test data

```sh
python3 verification/server.py
```

In Rill choose **Workspace tools → Files and integrations → Import Rill Workspace**, select `verification/materials/rill-workspace.json`, apply the preview and select **Verification local**. Start with **Kit — Smoke**. The **Expected failures** collection is deliberately supposed to fail its checks.

The [verification guide](verification/README.md) includes endpoints, upload files, format samples, optional gRPC/TLS setup and a blank acceptance checklist. Build a portable kit with `python3 scripts/build-verification-kit.py`.

## For developers

Start with [CONTRIBUTING.md](CONTRIBUTING.md). The [architecture guide](docs/ARCHITECTURE.md) explains the source layout, and [testing guide](docs/TESTING.md) covers the fixture-backed suite, formatting and visual diagnostics.

```sh
bash scripts/test.sh
python3 scripts/check-docs.py
```

CI builds and tests Apple Silicon with Xcode 26.2/26.3 and Intel with Xcode 26.3, verifies the app bundle and manual test kit, and executes generated client programs.

## License and support

Rill's original code is available under the [MIT License](LICENSE). Dependencies retain their own licenses; see [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt) and the [dependency guide](docs/DEPENDENCIES.md).

[Report a bug or request a feature](SUPPORT.md). Report sensitive vulnerabilities through the process in [SECURITY.md](SECURITY.md).
