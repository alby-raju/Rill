# Changelog

## 0.4.5 (unreleased)

- Bound runtime variable-template scanning without overlapping whitespace quantifiers or eagerly collecting all matches. Preserve whitespace semantics, stop on cancellation, and enforce the substitution budget during scanning.
- Set the ad-hoc CLI no-body mode explicitly rather than assigning an optional nil.
- Keep layout/environment selectors inside the workbench window, size them to content, and support close/Escape/click-away dismissal. Add compact-window containment and native Escape regressions.

- Add ad-hoc `request METHOD URL` with headers/text body inputs, temporary variable overrides, explicit saved environment/auth/TLS selection, redacted summaries and opt-in raw response files.
- Identify recognizable Insomnia/native workspace preflight inputs with actionable redacted format guidance.
- Isolate request/response pane hosting constraints from tab content so delayed native sizing updates cannot reset the divider to its minimum.

- Show one collection disclosure control, preserving saved collapse state and search expansion.
- Recognize supported native dynamic templates in offline preflight without generating values; reject unsupported names and malformed arguments.
- Remove force casts from collection adapters and runner failures, report the current version in the default User-Agent, and clarify invalid OpenAPI input diagnostics.

- Keep request/response tab content inside bounded viewports so switching tabs does not impose new split-view constraints. Reduce the stacked response minimum and add a 420-case native resize regression.
- Replace the large validation banner and empty Checks presentation with compact status and guidance; keep failures visible with a review action.
- Omit grouping-only parent containers when importing flattened collections, while preserving intentional empty leaves and mixed parents.

## 0.4.4

- Import explicitly empty GET/HEAD raw bodies as no body, with a warning, in Postman and HTTPie Desktop collections. Nonempty/structured payloads remain rejected with a collection-specific explanation.
- Restore collapsible collection headers with saved expansion state and temporary search expansion.
- Keep CLI preflight template scanning bounded on unterminated whitespace-heavy input.

- Add offline CLI `preflight` for Postman collection/environment inputs, temporary variable overrides, redacted script/variable/import blockers and optional bounded unencrypted PEM certificate/key pairing/expiry checks. This does not execute requests or provide Newman script compatibility.


## 0.4.3 — Installed app launch

- Resolve icon and offline-help resources relative to the installed app without SwiftPM build-machine fallback paths or fatal resource lookup.
- Verify the relocated optimized app actually opens a window and reads its packaged resources, with build-tree bundles temporarily unavailable and a missing-help negative case. Use an isolated temporary workspace for these checks.

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
