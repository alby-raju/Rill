# Getting help

Use [GitHub Issues](https://github.com/alby-raju/Rill/issues) for reproducible bugs and focused feature requests. Search existing issues first. Security reports follow [SECURITY.md](SECURITY.md), not a public bug report.

For a bug, include:

- Rill version/commit, macOS version, CPU architecture and installation method.
- Exact steps, expected result and actual result, including whether it survives restart.
- A synthetic request or the named [verification-kit](verification/README.md) case that reproduces it.
- A screenshot or redacted report when useful. Remove credentials, private endpoints and personal data.

For CLI failures include the command with secrets replaced, exit code and whether stdout was human output or `--json`. For a slow interaction, describe when the delay occurs and how many tabs/requests or bytes are involved. Collect process samples only with explicit consent and keep raw samples private.

An MVP has supported subsets. Check [FEATURES.md](docs/FEATURES.md) before relying on import, protocol, script or schema compatibility. A feature request should describe the workflow and expected outcome rather than assume another tool's implementation can be reused.
