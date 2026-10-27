# Changelog

## 0.4.2 — Portable Git hardening

- Reject nonportable filter names before Git configuration overrides are constructed.
- Disable effective Git clean, smudge and process filters for portable workspace operations, including drivers defined through included configuration. Preserve exported bytes without launching configured helpers.
- Keep hooks, signing, fsmonitor, external diff/text conversion and automatic maintenance disabled for those operations.

## 0.4.1 — Import and collection experience

- Preserve unselected Postman binary/multipart upload placeholders and multiple selected files, with explicit local reselection warnings.
- Add Copy/Move collection selection and cross-collection drag placement while retaining identities and unsaved edits when moving.
- Replace nested environment/layout choices with direct controls and give the environment editor a full-height, actionable empty state.

## 0.4.0 — MVP development

- Organize app/core/test source by feature area and apply consistent first-party code formatting.
- Replace initial-development logs and duplicated archive inventory with current architecture, feature/limit, testing, dependency and release guides. Preserve all 122 capability records and historical evidence.
- Add app screenshots, an onboarding-focused contributor guide, MIT license, security/support guidance and issue/PR templates.
- Include Rill's license in app and verification-kit packaging. Developer ID signing/notarization remain deferred.

## 0.3.3 — Tab interaction reliability

Fix active tab context-menu rebuilding that stalled bulk close; use a stable native menu and defer commands until menu tracking ends. The owner confirmed the installed build is responsive. [PR #29](https://github.com/alby-raju/Rill/pull/29).

## 0.3.2 — Manual verification and response UX

Add the standalone local verification kit, visible failed/passed/unconfigured response checks, top-aligned response text, and Close All/Left/Right tab commands with unsaved-draft protection. [PR #28](https://github.com/alby-raju/Rill/pull/28).

## 0.3.1 — CLI reports

Add human summaries, detailed attempts/checks, retry recovery and performance percentiles. Existing automation uses `--json` to retain the previous output shape. [PR #27](https://github.com/alby-raju/Rill/pull/27).

## 0.3.0 — Workbench experience

Add branded startup, full-height welcome, shared native controls and grouped request/auth/workflow editing. [PR #26](https://github.com/alby-raju/Rill/pull/26).

Earlier implementation history remains in Git and the capability checklist's immutable evidence links.
