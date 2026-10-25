# Roadmap

Rill has reached an **MVP development milestone**: the native app and CLI cover everyday API work and a documented breadth of advanced tools. MVP means a usable starting point, not complete standards conformance, universal import compatibility or a notarized public release.

## Next priorities

1. **Acceptance and reliability:** complete the [manual checklist](verification/CHECKLIST.csv) on fresh supported Macs, including restart/recovery, Keychain prompts, upgrades and keyboard/VoiceOver use.
2. **Independent interoperability:** verify real gRPC services, brokers, TLS/OAuth providers and exports from supported producer tools. Expand behavior only with explicit tests and documented limits.
3. **Everyday UX:** improve editor/response navigation and large-workspace performance based on reproducible user feedback.
4. **Distribution:** retain reproducible per-architecture installers and license/provenance checks. Paid Developer ID signing/notarization is deferred until the owner enables it.
5. **Scope expansion:** prioritize unsupported import representations, protocol authentication/administration, script and extension requests through issues rather than silently implying compatibility.

The [capability checklist](docs/CAPABILITIES.csv) preserves all 122 original tracked requirements and their acceptance criteria. Existing partial/verified/deviation states remain conservative; this cleanup does not convert implementation into sign-off. Historical evidence links point to immutable Git revisions. New contributors should use the current [feature guide](docs/FEATURES.md) and [architecture](docs/ARCHITECTURE.md), not old development milestone logs.

There are no promised dates for these priorities. Signing expenditure, release publication and broader scope changes remain explicit owner decisions.
