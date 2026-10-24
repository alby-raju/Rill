# Implementation status

For the complete delivery plan, use the [roadmap](../ROADMAP.md) and [capability register](roadmap/CAPABILITIES.md). This page is a summary of the current build, not the complete backlog.

## Product direction

A focused request workspace replaces the original application's many drawers. Muted native surfaces, a sea-green accent, method colors and monospaced payloads separate navigation, composition and inspection. The response lives below the composer in a resizable split so long URLs and JSON retain width. The initial screen uses real empty states rather than fabricated activity.

The package separates serializable models and request execution (`RillCore`) from SwiftUI and platform integrations (`Rill`). All source was authored anew. The archive remains outside the package and is not a build input.

## Remaining capability work

The archive documents a much larger product than this first native build. These features are not implemented or represented as working controls:

- OpenAPI/Swagger, Postman, Insomnia, Bruno, HAR and HTTPie Desktop import/conversion.

[M3](milestones/M3.md) adds native import plans and a documented subset of cURL/HTTPie command import/generation.
- Cookie management.

[M2](milestones/M2.md) adds structured forms, API-key auth, streaming file/multipart uploads and prepared request inspection, safe response previews, opt-in durable snapshots and semantic JSON comparison. Interoperability and installed-app acceptance remain partial.
- GraphQL IDE/introspection/subscriptions; ordinary GraphQL HTTP POST can be composed manually.
- WebSocket, SSE, gRPC, MQTT, Kafka and AMQP clients.
- Collection runner, extraction/chaining, scripting, matrix/load tests and CI reports.
- Schema/contract validation, mocks, scanners, workspace Git and sharing.
- An independent CLI.

[M1](milestones/M1.md) implements persistent tabs, separate drafts, ordering, inherited environments and native backups. Manual interaction/Keychain acceptance remains pending.
- Distribution icon, Developer ID signing, notarization, accessibility audit and UI verification on supported macOS releases.

The new HTTP foundation should be exercised against local fixtures before adding protocol transports. Protocol clients should use independently chosen maintained libraries rather than wrapping or embedding the old application. The name is a working product identity; trademark and distribution availability have not been checked.
