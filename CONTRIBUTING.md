# Contributing to Rill

Rill is a native Swift/macOS API workbench. Small, focused contributions with clear behavior and validation are welcome.

## Set up your Mac

You need macOS 15+, full Xcode 26.2+ with Swift 6.2.3+, Python 3, an OpenSSL command for disposable TLS fixtures, Git and enough disk space for SwiftPM's native dependencies. The app supports Apple Silicon and Intel. Select your Xcode installation for the current shell:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
swift run Rill
```

Alternatively open `Package.swift` in Xcode. `swift build --product RillCLI` builds the CLI; `swift build --show-bin-path` reports its output directory. Do not assume a fixed `.build` subdirectory across toolchains.

Read [architecture](docs/ARCHITECTURE.md), [features and limits](docs/FEATURES.md) and [testing](docs/TESTING.md) before changing a shared engine or protocol adapter.

## Make a change

1. Start from current `main` and create a feature branch.
2. Keep the change focused. Explain the concrete problem, resulting behavior and relevant limits.
3. Use RillCore for behavior shared by desktop and CLI; keep SwiftUI/AppKit code in the app target.
4. Add behavior tests for meaningful success, failure, cancellation and resource-boundary changes. Documentation-only changes do not need artificial tests.
5. Format first-party code, run the relevant checks, and update user-facing docs when behavior changes.
6. Open a PR with a clear description and validation results. All required CI checks must pass. Maintainers apply the repository's configured review and merge rules.

Do not commit build output, personal workspaces, credentials, signing keys, certificates or raw process samples. Use synthetic fixtures and redacted reproduction steps. Keep the existing 122 capability IDs when refining tracked scope; [CAPABILITIES.csv](docs/CAPABILITIES.csv) retains requirements and immutable historical evidence without development-log clutter.

## Code style

Swift uses four spaces and a 100-column target through `.swift-format`. Prefer one declaration/statement per line, descriptive names, small cohesive types and explicit failure handling. Let the formatter handle whitespace; do not manually compress declarations.

Python uses Ruff's formatter and import checks (`requirements-dev.txt`, `ruff.toml`). C test support uses the bundled clang-format and `.clang-format`. Bash uses shfmt 3.14.1; the one zsh packaging script keeps its native syntax and is syntax-checked separately. `.editorconfig` covers other text files.

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-dev.txt
export PATH="$PWD/.venv/bin:$PATH"
# Install shfmt 3.14.1 using your preferred package manager or official release.
bash scripts/format.sh
bash scripts/format.sh --check
```

Formatting tools are development dependencies, not app runtime requirements. Run formatters only on first-party source; never rewrite dependency checkouts or third-party license texts.

## Validation

```sh
bash scripts/test.sh
python3 scripts/check-docs.py
python3 scripts/collect-dependency-notices.py --check
```

Use the fixture wrapper for a complete test run. A bare `swift test` can skip endpoint-dependent cases and is not a replacement for CI. See [testing](docs/TESTING.md) for focused tests, the manual kit, generated-client checks and visual diagnostics. Run packaging for changes that affect resources, native dependencies or distribution.

## Source, dependency and security policy

All Rill implementation, tests, fixtures and assets must be independently authored. Do not copy or translate proprietary office/reference code, test implementations, assets or runtime bundles. General requirements and public protocol specifications may guide fresh implementations.

Before adding or upgrading a dependency, record official upstream/version/revision, license/notices, Swift/macOS/CPU support, dated advisory findings, bounds/error behavior, packaging and removal implications in [DEPENDENCIES.md](docs/DEPENDENCIES.md). Keep exact production pins and update `Package.resolved` and generated notices together. Never relax TLS, redaction, resource limits or trust boundaries merely to accommodate a library.

Protocol work needs independent real-service evidence in addition to synthetic fixtures. Unsupported behavior must be explicit. Imported foreign scripts stay disabled; hooks and extensions must respect the published trust model.

## License

Contributions are made under the project's [MIT License](LICENSE). Submit only material you have the right to contribute. Third-party code/assets require their own compatible license and retained attribution.
