# Contributing to Rill

Rill is an independent native Swift/macOS implementation. Use the roadmap capability IDs to describe what a change implements and how it was verified.

## Source and dependency policy

- Write all implementation, tests, fixtures, scripts, icons and other assets independently. Do not copy or translate source, test implementations, assets or bundled runtime files from the original Relay archive.
- The reference inventory records requirement provenance through names and hashes only. Keep the archive, generated build output, personal workspaces, credentials and signing material out of commits and PR attachments.
- Named reference scenarios may guide new behavioral tests; do not reuse the reference test source. A matching test count is not a compatibility claim.
- Before adding a package, parser, compiler, runtime or protocol library, add a decision note identifying its official upstream, current maintained release/support status, license and notices, Swift/macOS/CPU compatibility, vulnerability review date, resource/error behavior, packaging needs and upgrade/removal strategy. Include primary-source links and the verification date.
- Do not silently relax TLS checks, resource budgets, secret redaction or plugin/script trust boundaries to make a dependency work. Document any needed product decision first.

## Changes and evidence

Work on a feature branch and open a PR. Preserve the repository owner's administrator-bypass and one-review configuration. `Build and test on macOS` is the required aggregate CI check; it must succeed across all matrix jobs for ordinary merges. Administrator bypass is an owner-controlled exception, not an implementation workflow to use automatically.

Run:

```sh
bash scripts/test.sh
python3 scripts/audit-roadmap.py
```

On Macs configured with command-line tools alone, use the installed Xcode toolchain for the test command, as described in [validation](docs/VALIDATION.md). Do not skip fixture-backed tests in CI.

Every feature PR includes stable capability IDs, relevant failure/cancellation/resource tests, documentation and verification links. Regenerate the readable capability register with `python3 scripts/audit-roadmap.py --render`. Leave a row partial when required manual/interop evidence is missing. An owner-approved difference is a documented deviation, not a deleted requirement.
