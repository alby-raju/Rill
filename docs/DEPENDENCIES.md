# Dependencies and licensing

Rill's original code is MIT licensed. Third-party libraries, vendored components, compiler resources and runtime compatibility libraries retain their own terms. The authoritative collected texts are [THIRD_PARTY_NOTICES.txt](../THIRD_PARTY_NOTICES.txt), generated from clean checkouts at the exact revisions in [Package.resolved](../Package.resolved). The app bundles both its own LICENSE and third-party notices.

## Production selections

| Dependency | Exact selection | Purpose / license |
|---|---|---|
| [Yams](https://github.com/jpsim/Yams) | 6.2.2 | YAML plus bundled libyaml; MIT |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | 0.9.20 | Bounded archive adapter; MIT, privacy manifest retained |
| [gRPC Swift](https://github.com/grpc/grpc-swift-2) | 2.4.4 | Native gRPC; Apache-2.0 |
| [gRPC NIO transport](https://github.com/grpc/grpc-swift-nio-transport) | 2.11.0 | Native transport; Apache-2.0 and transitive notices |
| [SwiftProtobuf](https://github.com/apple/swift-protobuf) | 1.39.0 | Models/compiler; Apache-2.0 with runtime exception |
| [Swift Kafka client](https://github.com/swift-server/swift-kafka-client) | 1.0.0-beta.1 | Native librdkafka wrapper; retain its graph's native/TLS/compression notices |
| [Swift Log](https://github.com/apple/swift-log) | 1.16.2 | Logging interface; Apache-2.0 |

SwiftPM resolves 26 pinned packages. Not every transitive source component is linked into every artifact. Kafka uses a beta API and is isolated behind an adapter. No office/reference runtime or Java bundle is shipped. MQTT/AMQP use first-party bounded codecs and Apple's Network framework; HTTP and native UI use Apple platform APIs.

## Parser and transport review boundaries

- YAML uses a bounded event preflight before constructing a tree: duplicate/tag/multi-document/recursive/oversized inputs reject. Workspace imports disallow aliases; API definitions allow bounded prior anchors/aliases but not merge keys. Upgrades must preserve that separation and the CYaml module integration.
- ZIP metadata is checked before decompression: safe normalized paths, no symlinks/special files, collision/CRC/overlap validation, size/count/depth bounds and cancellation. No archive is extracted to disk by import. ZIP64/encrypted/nested/unsupported representations reject.
- JSON preserves exact decimal and UTF-8-key semantics through bounded parsing. Schema support is explicit; external reference loading is not automatic.
- The official protobuf compiler is built/bundled for the target CPU, invoked without a shell and bounded by time/output/import rules. Never run a user-specified plugin implicitly.
- Native protocol adapters preserve TLS/hostname checks, deadlines, ownership and no hidden credential-bearing diagnostics. Kafka library allocation/decompression precedes Swift inspection in some paths; independently test real compressed batches and services.
- Generated client programs are text templates, not app dependencies. CI installs pinned SDKs in isolated test environments. Review generated source before execution, especially URLs/bodies/uncommon headers.

The [dated dependency audit](dependency-audit.json) records published advisory-database matches by exact public revision as of its review date. It is not a continuing monitoring service or proof of vulnerability absence; vendored components need separate review.

## Upgrade process

1. Inspect official upstream release/support/security information and record the date, version and revision.
2. Review license changes, transitive/vendored notices, privacy resources and runtime packaging.
3. Keep production pins exact and update Package.resolved deliberately.
4. Preserve parser/transport bounds, TLS/redaction and explicit unsupported cases. Re-run success/failure/cancellation/adversarial tests and the full supported architecture matrix.
5. Regenerate and verify notices; validate the packaged app/CLI/compiler offline. Document migration/removal implications before changing stored representations.

```sh
python3 scripts/collect-dependency-notices.py
python3 scripts/collect-dependency-notices.py --check
```

## Developer-only tools

Swift formatting and C formatting use the selected Xcode toolchain. Python formatting uses Ruff 0.17.2 from `requirements-dev.txt`; Bash formatting uses [shfmt 3.14.1](https://github.com/mvdan/sh/releases/tag/v3.14.1). These are not bundled runtime dependencies. The optional verification gRPC server uses separately installed grpcio 1.80.0. Client-validation SDK versions are pinned in CI and the validation harness; their libraries are not copied into the app.
