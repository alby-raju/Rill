# Bounded script workflows: subset v1

Development source supports an explicit, finite Postman-source translation mode:

```sh
rill preflight ./collection.json --translate-scripts --script-inventory --json
rill run ./collection.json --translate-scripts --continue-on-failure --report ./run.html --report-format html
```

The default still blocks nonempty foreign source. Translation parses a fixed grammar into
typed native operations; it does not evaluate JavaScript, link a JS runtime, load modules or
allow script-directed filesystem/process access. No source is executed during preflight.
Native file runs reject this Postman-only option. Importing a collection into the desktop
does not enable translation or run its retained foreign source.

All selected inherited blocks and literal branch targets must validate before the first
request. An unsupported construct anywhere, including an unselected conditional arm,
rejects the selected plan. Unknown remote sources/languages, declared-disabled nonempty
blocks and nonstandard disabled request settings reject rather than being silently ignored.
Exact folder selection includes ancestor scripts and excludes unrelated siblings.

## Grammar

Statements are limited to these forms; placeholders below stand for literals or the
expressions described afterward. Semicolons are required between call statements; the
last call before a closing brace or end of source can omit one. Comments are allowed.

```js
pm.environment.set('token', 'literal value');
pm.environment.set('copy', pm.globals.get('seed'));
pm.environment.unset('old');

if (pm.variables.get('runLinks') === 'true') {
    pm.environment.set('result', 'yes');
} else {
    pm.environment.set('result', 'no');
}

// Post-response only:
pm.environment.set('token', pm.response.json().token);
pm.environment.set('header', pm.response.headers.get('X-Token'));
pm.test('status check', function () {
    pm.response.to.have.status(200);
});
pm.test('response fields', () => {
    const body = pm.response.json();
    pm.response.to.have.header('Content-Type');
    pm.expect(body.ok).to.eql(true);
    pm.expect(body.count).to.equal(42);
});
pm.execution.setNextRequest('Next request');
pm.execution.setNextRequest(null);

// Pre-request only:
pm.execution.skipRequest();
```

- Variable `get`, `set` and `unset` calls accept `pm.variables`, `pm.environment`,
  `pm.collectionVariables` and `pm.globals`. `pm.iterationData.get` is read-only.
- Names are nonempty native variable names: up to 128 ASCII letters/digits or `_.-`,
  excluding reserved `request.`/`response.` prefixes. Values are strings. String literals
  use single/double quotes and the finite `\\`, `\'`, `\"`, `\n`, `\r`, `\t`, `\b`, `\f`
  and four-digit Unicode escapes. Valid surrogate pairs are decoded; unmatched surrogates,
  template literals, line continuations, octal/hex/braced escapes and arbitrary coercion reject.
- A set value can be a string literal, a permitted variable getter, a response-header getter,
  or an inline response JSON path. JSON selectors use dotted identifiers, literal string
  brackets and nonnegative integer brackets, up to 32 segments/4,096 bytes. Extracted JSON
  values must be strings; missing/nonstring values fail the workflow instead of being coerced.
- Conditions use string expressions, `===`/`!==` against a string literal, or string
  truthiness (missing/empty is false; every other string, including `"false"`, is true).
  `!` is accepted for the truthiness form. Both arms require braces. Nested conditions
  are bounded; arbitrary boolean/numeric expressions, `&&`/`||` and automatic coercions reject.
- A `pm.test` callback is anonymous `function () { ... }` or `() => { ... }`, containing
  one or more status, header-presence or scalar-equality assertions. Supported forms are
  `pm.response.to.have.status(100...599)`, `pm.response.to.have.header('Name')` and
  `pm.expect(expression).to.equal(literal)` or `.to.eql(literal)`. Equality accepts strings,
  nonnegative integer literals of up to nine digits, booleans and `null`. Types must match.
  Missing JSON values differ from `null`. Header names are case-insensitive. JSON objects and
  arrays can be traversed to reach a scalar. Arrays support literal indices. Object and array
  literals are unsupported as expected values.
- A post-response block or test callback can start with one `const name = pm.response.json();`
  declaration. Its JSON alias is scoped to that block or callback and can be used with the same
  literal selectors as an inline JSON expression. Other declarations and initializers reject.
- Each callback produces one check. A failed assertion ends that callback. Later tests and
  ordinary following operations still run. Reports omit user test labels and assertion values.
- Next-request selection accepts a literal original ID, a unique literal name, or `null`.
  Legacy `postman.setNextRequest` is also accepted. Targets must exist inside the selected
  run scope; branches can cross its folders. IDs take precedence over names. Names and
  comparisons use exact UTF-8 bytes, including canonically distinct Unicode sequences.
- `null` stops after the current request; a later next-request call can replace that choice.
  Skip immediately ends remaining pre-request scripts and sends no request or post scripts.
  Loops, general declarations, arbitrary functions, async calls, external modules, eval,
  dynamic property access, Vault, arbitrary request mutation and all other syntax reject.

## Scope, ordering and failure behavior

Collection, outer-to-inner folder, and request scripts run in that order for **both** phases.
Event order within each scope is preserved. This follows the documented
[Postman script hierarchy](https://learning.postman.com/v11/docs/tests-and-scripts/write-scripts/intro-to-scripts).
Skip and next operations follow their explicitly supported phase restrictions; see
[Postman's execution APIs](https://learning.postman.com/docs/tests-and-scripts/write-scripts/postman-sandbox-reference/pm-execution).

Globals, collection, environment, iteration data and run-local values are separate layers.
Template/effective lookup goes from broad to narrow in that order; a scoped getter reads
its own layer. `pm.variables.get` reads the effective value. Empty strings override lower
layers, and unsetting a scoped value reveals lower layers. Scope writes are run-local;
input files and the desktop workspace are never rewritten.

Rill's existing explicit CLI overrides remain the highest initial layer and are also visible
to environment getters. To avoid ambiguous override/mutation behavior, any script write or
unset of an explicitly overridden name is rejected before traffic, regardless of branch.
This is a documented subset restriction, not unrestricted Newman `--env-var` equivalence.
Data files preserve Rill's row isolation: every row resets initial scopes and local values;
without a data file, state flows across iterations. Newman persistence across data rows and
Rill retries are not established by the current differential corpus.

Failed translated test checks preserve preceding/following valid script mutations. This is
separate from native JSON-hook transactional failure behavior, which remains unchanged.
Transport or uncaught script-value errors still fail the run; mutations already made remain
run-local and can appear in an explicit raw final-environment export. Cancelled runs do not
export. Exported effective variables are flattened plaintext and may contain extracted tokens;
ordinary console/JSON/JUnit/HTML/Allure reports continue to omit values and user test labels.

Rill's default fail-fast policy still stops after a failed request/check. Use
`--continue-on-failure` to compare normal continuation with Newman. Failed assertions exit 4;
runtime/transport errors exit 3; unsupported syntax/configuration exits 2; cancellation exits
130. A response with translated tests uses those tests, including explicit non-2xx status
expectations. A response with no translated tests gets Rill's conservative HTTP 2xx check.

Skipped steps have `state: "skipped"`, no HTTP status/body, and a skipped entry in JUnit/Allure.
An explicitly skipped-only validated run can pass; empty, cancelled and exhausted runs cannot.
Branch loops remain subject to the shared runner execution limit. Normal report retry/retention
and cancellation handling are reused rather than introducing another collection runner.

## Bounds and validation evidence

The parser allows at most 1 MiB/block, 4 MiB source across the plan, 1,000 blocks, 10,000 source lines/block,
100,000 lexer tokens/block, 1,024 parsed statements/block, 16 conditional levels and 128 assertion or declaration operations per callback.
Compilation bounds total estimated operation cost to 100,000 and each
request's inherited pre/post cost to 1,024. It retains at most 100,000 inherited source references
and traverses at most 100,000 nodes/32 folder levels plus request leaves. Runtime repeats the
1,024-operation bound and applies a 250 ms deadline per script phase, excluding network wait.
Scopes are bounded to 4,096 entries/4 MiB total text, 1 MiB/value and 1,024 effective variables.
Native bounded JSON/HTTP/TLS and the collection execution/retention limits remain in force.

Script-produced template names are recognized during preparation using opaque validation-only
values. Conditional/dynamic values still receive native URL/header/auth validation at their
actual request step. Passing static preflight does not prove future response-dependent values
will exist, contain strings, satisfy transport configuration or pass tests.

Seven independently authored synthetic workflows passed against pinned Newman 6.2.3:
inheritance/extraction, skip/branch/stop, mutation after failed checks, both conditional arms,
scoped mutation and expected non-2xx responses. Wire order/headers, assertion totals/failures,
selected exported mutations and normalized exit results matched. Additional negative fixtures
confirmed unsupported/remote later source blocks the first request and never fetches a script.
The newer typed assertions and JSON aliases have Rill fixture coverage. See the
[recorded reference harness](../scripts/script-conformance/README.md) for the earlier cases. These results
define a small corpus, not a compatibility percentage or acceptance of arbitrary collections.

The broader [roadmap](../ROADMAP.md) still requires independent suites, fuller assertions and
extraction, richer mutation/type semantics and additional platform/provider acceptance.
