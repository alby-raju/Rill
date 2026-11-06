# Optional Newman reference corpus

This first-party corpus compares bounded Rill workflows with **stock Newman 6.2.3** using
the committed test-only npm lockfile. Newman is Apache-2.0 licensed; its dependencies retain
their own licenses. Neither Node, Newman nor node_modules is linked/bundled into Rill,
installers, the CLI-only archive or the verification kit. This directory is tooling under
`scripts`, separate from standalone first-party verification materials.

```sh
cd scripts/script-conformance
npm ci --ignore-scripts --no-fund --no-audit
cd ../..
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build --product RillCLI
python3 scripts/script-conformance/run.py --cli "$(swift build --show-bin-path)/RillCLI"
```

The runner accepts only the Rill executable path. It generates its own synthetic collections,
uses a disposable loopback HTTP server and temporary files, and never reads a user collection,
workspace, certificate or credential. Each subprocess has a deadline. It compares actual wire
order and selected headers, total/failed checks, selected environment mutations and success/
assertion-failure exits. Rill uses exit 4 where Newman uses 1 for assertions; that normalization
is explicit, not an assertion that their numeric exit conventions are identical.

The seven positive cases cover inherited phases, scope writes/reads, string extraction,
conditional skip, cross-folder branches/stop, mutation after a failed assertion and expected
404. Two negative Rill-only cases require unknown/remote later source to reject before traffic.
The latest local run used Node v26.12.1 and passed all seven cases plus both negative cases.
No data-row persistence/retry/proxy/TLS/async-library equivalence or compatibility percentage
is claimed. Stock dependency behavior is kept unchanged; no reference patches force agreement.

## Dependency audit status

The 5 November 2026 registry audit of this reference lockfile reported **19 advisory matches:
1 critical, 12 high and 6 moderate**, including transitive template/parser/crypto libraries.
The reference is therefore an optional local, synthetic-input tool. Normal Swift tests/builds
do not install or invoke it, and it is not an automatic trusted release gate or a clean-audit
claim. Audit separately with `npm audit --json`; re-review upstream releases before expanding
its use. Keep lifecycle scripts disabled and do not feed this reference personal collections or
credentials. Production Swift dependency audits and exact-source release/security gates remain
separate and are not waived by this conformance evidence.
