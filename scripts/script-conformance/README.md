# Recorded Newman reference corpus

The runner compares Rill with recorded results from stock Newman 6.2.3 on Node v26.12.1.
It runs only Python and the Rill CLI against a disposable loopback fixture.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build --product RillCLI
python3 scripts/script-conformance/run.py --cli "$(swift build --show-bin-path)/RillCLI"
```

The seven cases cover inherited phases, scope writes and reads, string extraction,
conditional skip, cross-folder branches and stop, mutation after a failed assertion,
and expected HTTP 404. Each record contains the request order, selected headers,
assertion counts, selected environment values and reference exit status. Newman uses exit 1
for an assertion failure and Rill uses exit 4. Two additional Rill-only cases require
unknown and remote script sources to fail before sending traffic.

The capture used the historical lockfile identified by its SHA-256 in `reference.json`.
Input hashes bind each record to its synthetic case with the ephemeral loopback port
normalized. Changing a case requires new independent evidence. Replaying these fixtures
checks for regressions against the captured version. Live interoperability and coverage
outside the seven cases require separate verification.

## Dependency remediation

The retired npm graph accounted for all 33 open repository advisories at review.
Candidate upgrades addressed 32 of those advisory ranges, but the current Postman SDK
still depends on a Faker API removed in the patched releases. The harness now reads
the independently captured results as data. It has no npm manifest, lockfile, install
step, or JavaScript reference process. Historical advisories and captures remain part of
the project record.
