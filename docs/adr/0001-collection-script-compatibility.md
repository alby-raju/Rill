# ADR 0001: bounded translation for the first collection-script subset

Status: implementation decision for the next compatibility increment, 5 November 2026.
This records a direction; it does not advertise support for Postman JavaScript.

## Context

Rill already has finite native JSON hooks, assertions, extraction and sequential branching.
Foreign scripts are retained as disabled source, and direct file runs block them before
traffic. The next migration increment needs explicit behavior for inherited collection,
folder and request scripts without creating a second execution engine or opening arbitrary
host access. The same behavior must eventually run outside the Mac desktop.

## Decision

Translate a deliberately small, published grammar into the existing native operations.
Parse syntax into a bounded intermediate representation; do not evaluate JavaScript or use
regular-expression replacement as a parser. Keep the original source and source locations.
The translator must reject an entire selected execution plan before traffic if any inherited
construct falls outside its grammar. No implicit omission, partial script execution or
conversion of unsupported assertions into passing checks is permitted.

The first proposed grammar covers literal variable set/unset, literal status assertions,
bounded JSON/header extraction, conditional skip and explicit same-collection next-request
selection. Exact supported syntax is to be frozen with fixtures before enabling translation.
Comments, strings, escapes and nested constructs must be parsed rather than guessed.
Collection/folder/request inheritance, pre-request/test ordering and variable scopes need
an explicit execution model; flattening imported values alone is insufficient.

Keep translation opt-in until a pinned Newman differential corpus proves the documented
subset. Default foreign-script blocking remains. Report translated and rejected constructs
with source location and a stable code; diagnostics must not echo source, expected values,
URLs or secrets. The retained source is available only through explicit source inspection.

Use the existing cancellation, step limits, transactional variable updates and report
redaction. Bound source bytes, token count, nesting, translated operations, substitutions,
variable counts/bytes and branch executions before and during execution. Async requests,
loops, eval, dynamic property access, arbitrary modules and Node/host APIs are excluded from
the first grammar. A construct being common is not sufficient reason to silently approximate it.

## Alternatives

An optional isolated JavaScript worker may eventually improve syntax coverage. It also needs
its own portable process lifecycle, memory/CPU/wall-time enforcement, bounded IPC, cancellation,
filesystem/network/environment denial, credential mediation, dependency review and distribution
evidence on each target OS. Merely moving evaluation into another process is insufficient.
No worker/runtime is selected or linked by this decision. Revisit through a superseding ADR
only after a prototype demonstrates these boundaries and a defined compatibility denominator.

Continuing to block all scripts is the current safe behavior and remains the fallback. It
cannot satisfy the intended migration workflow, so it is not the final compatibility strategy.
Unrestricted evaluation inside the desktop or CLI process is rejected.

## Acceptance before enabling the subset

- A published construct inventory distinguishes native operations, translated syntax and
  unsupported syntax, including inherited event locations and disabled input behavior.
- Pinned synthetic Newman/Rill suites compare wire request order/count, scope mutation,
  assertions, extraction, retries, branching, empty/disabled values and exit status.
- Unsupported or malformed constructs block before the first request, including constructs
  in later iterations or inherited folders. Negative fixtures cover adversarial syntax,
  resource exhaustion, cancellation and sensitive source text.
- Ordinary reports identify the strategy and omissions without exposing source/credentials.
  Explicit raw exports remain separately authorized.
- Cross-platform claims require the same corpus on each supported OS. Current macOS tests
  and the existence of a Swift compiler on another OS are not portable-runtime acceptance.

Consequences: smaller initial syntax coverage and more up-front parsing work, in exchange
for reuse of the existing engine and a finite behavior boundary. No compatibility percentage
or unrestricted Newman parity is promised.
