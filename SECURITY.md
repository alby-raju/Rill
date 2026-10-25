# Security policy

Rill handles credentials and potentially sensitive API data. Never include real tokens, request/response bodies, private keys or personal workspaces in public issues, screenshots or logs.

## Report a vulnerability

Use GitHub's private vulnerability reporting option in this repository's Security tab when available. If it is unavailable, open an issue containing **only a request for a private contact channel**, without exploit details or sensitive data. Maintainers will arrange a private exchange. Do not post the vulnerability details publicly while arranging contact.

Include the affected version/commit, platform, impact and a minimal synthetic reproduction. There is no guaranteed response-time SLA or paid support contract. Older development builds may require updating to reproduce a fix.

## Security boundaries

- Credentials use macOS Keychain; named process-environment fallbacks are read-only. Entered URLs, fields, bodies, schemas and environment values can still contain secrets in plain-text workspace data.
- Portable reports, diagnostics and sanitized sharing omit disallowed runtime values. Explicit raw exports and generated client source need review before sharing.
- TLS verifies certificates/hostnames by default. Insecure profiles are explicit per-request development choices; no silent fallback is allowed.
- Imports are bounded and validated before Apply. Foreign script source is disabled review material. Rill hooks are a finite operation language; extensions are reviewed data services, not arbitrary executable plugins.
- Local sharing is token-protected and loopback by default. Explicit LAN HTTP is plaintext.
- Native parsers and libraries have bounded entry points, but an in-process parser is not an OS sandbox or a promise of a hard memory/time ceiling for every dependency allocation.

For exact supported behavior see [features and limits](docs/FEATURES.md). Dependency review records are dated; absence of an advisory match is not proof of safety. Developer ID signing/notarization remain deferred for development builds.
