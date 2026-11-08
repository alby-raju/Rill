# Collection script compatibility

This inventory describes development source, not unrestricted Postman/Newman compatibility.
Rill executes its own bounded native JSON operations, response assertions and extraction.
It executes **no JavaScript runtime**. Default file runs block nonempty foreign script blocks.
Development source also provides explicit [bounded native translation](SCRIPT-SUBSET.md) with
`--translate-scripts`; only its fully validated finite grammar can run.

[ADR 0001](adr/0001-collection-script-compatibility.md) defines the bounded translation strategy.
The inventory alone does not enable it; broader grammar and independent acceptance remain open.

## Inspect a collection offline

```sh
rill preflight ./collection.json --script-inventory --json
rill preflight ./collection.json --folder /Parent/Child --script-inventory --detail
```

This opt-in adds `checks.scriptInventory` to JSON preflight output, or a redacted section to
terminal output. Ordinary preflight output remains unchanged when the flag is absent.
It accepts the existing environment/globals/override inputs and optional PEM inspection;
it makes no API requests, fetches no external scripts, executes no source and changes no
workspace, source file or Keychain. Other commands reject `--script-inventory`.

An inventory alone does not change preflight's exit status: nonempty scripts, including declared
disabled scripts, remain blockers with exit 2. Combining it with `--translate-scripts` reports
fully validated source as `translated`, counts compiled native operation nodes, and preserves
source/feature coordinates. The standalone lexical hints never grant that classification. Empty whitespace-only `exec` arrays do not
block by themselves. Comments-only scripts remain nonempty foreign source. Other variable,
transport, import and resource blockers still apply.

## Source and inheritance records

The inventory enumerates collection, folder and request event entries, including empty,
remote and malformed entries. Each retained source includes:

- `location`: a JSON pointer using original item/event indices, never user labels or keys.
- `scope`: `collection`, `folder` or `request`.
- `phase`: `prerequest`, `test` or `other`; arbitrary event names are never echoed.
- `declaredDisabled`: an event/script declaration, not a promise that foreign source runs or
  is safely ignored. Conservative blocking remains unchanged.
- `affectedRequests`: the number of selected structural request leaves below that source.
  Ancestor events therefore cover their selected descendants. This includes declared-disabled
  request items and is not an executed-request count or a simulation of script ordering.
- `disposition`: `empty`, `unsupported`, `invalid` or explicitly validated `translated`. A known API hint never upgrades this
  classification to supported or translated.
- `coverage`: `lexical`, `partial` or `limited`, plus an array of fixed diagnostic hints.

Exact folder selection retains ancestor events, excludes unrelated siblings and preserves
original JSON indices. The inventory does not expand ancestor source into one copy per
request, which keeps large inherited suites bounded. `sourceCount` includes every event
entry seen; this differs from preflight's count of nonempty script blocks.

## Lexical migration hints

Hints identify case-sensitive token sequences, not verified JavaScript semantics. Comments
and quoted strings are skipped. No argument, literal, identifier chosen by the user, source
snippet, request name, endpoint or secret value is included in output. Shadowing, aliases,
computed properties and arbitrary JavaScript behavior are not inferred.

| Source/API family | Fixed hint family | Current foreign execution | Native migration starting point |
| --- | --- | --- | --- |
| `pm.variables`, `pm.environment`, `pm.collectionVariables`, `pm.globals`, `pm.iterationData` methods | `variable.SCOPE.ACTION` | Selected getters and string mutations are translated | Explicit input precedence and finite native `set`/`unset` |
| `pm.test`, `pm.expect`, `pm.response.to.have.status/header/body` | `assertion.*` | Selected status, header-presence and scalar-equality forms are translated | Native response assertions and finite hook assertions cover additional cases |
| `pm.response.json/text`, `pm.response.headers.get` | `response.*` | Literal JSON selectors and header getters are translated in selected forms | Native JSON/header extraction and response assertions |
| `pm.execution.setNextRequest/skipRequest`, `postman.setNextRequest` | `workflow.*` | Literal branch targets, stop and pre-request skip are translated | Native same-collection `next` and explicit stop |
| `pm.request.headers.add/upsert/remove` | `request.header.*` | Bounded pre-request edits with literal names and string values | Native header operations cover other request mutation workflows |
| `pm.sendRequest`, `pm.vault` methods | `runtime.http`, `runtime.vault` | Unsupported | No implicit async HTTP/Vault implementation |
| `require`, `eval`, `Function`, `console.log` | `runtime.module`, `runtime.dynamicCode`, `runtime.log` | Unsupported | No foreign module/runtime access; native log output remains opaque |
| Loop and async keywords | `syntax.loop`, `syntax.async` | Unsupported | No arbitrary loops or asynchronous foreign source |
| Template literals, non-comment slash syntax, escaped identifiers | `syntax.opaque` | Unsupported; inspection stops | Requires grammar-aware parsing, not token guessing |
| Remote source or an unrecognized declared language | `source.external`, `source.otherLanguage` | Unsupported | No fetch or language runtime selected |

For variable families, recognized method spellings are `get`, `set`, `unset`, `clear`, `has`,
`replaceIn` and `toObject`. Recognition is only a migration hint, including methods that may
not exist on a particular Postman scope. Unknown calls and other unclassified source remain
covered by the block's `unsupported` disposition even when they produce no individual hint.
An empty hints list never establishes compatibility.

Hint positions are one-based logical source lines and UTF-8 byte columns after joining the
`script.exec` array with LF. Embedded CR/CRLF also count as line breaks. Positions are relative
to that event's `script.exec`, not to the JSON file's physical formatting or display-width
columns. The event pointer plus source position locates the retained source for review.

## Limits and completeness

Preflight retains its 32 MiB input and bounded JSON/folder limits. Inventory traversal permits
at most 100,000 nodes and 32 folder levels plus request leaves. It retains at most 1,000
source records; `sourceCount` and `omittedSources` expose omitted entries. Source hint scanning
is bounded to 1 MiB and 10,000 `exec` entries per block, 4 MiB scanned source in total,
100,000 tokens and 4,000 scanner records across the inventory. Fixed source/limit markers
can appear in addition to scanner records. Cancellation is checked during traversal/scanning.

`complete: false` signals omitted sources, an inspection limit or opaque/unterminated syntax.
Each retained source exposes its coverage, with fixed `analysis.limit` or `syntax.opaque`
markers where available. `complete: true` only means the bounded lexical inspection finished;
it never means a JavaScript program was parsed, validated or shown compatible. No retained
sample is extrapolated into a compatibility percentage.

The [finite translated subset](SCRIPT-SUBSET.md) adds grammar-checked operations, separate
variable scopes and a pinned synthetic differential corpus. Every construct outside it remains
unsupported; broader compatibility/independent acceptance stays on [COMPAT-01/03/04](../ROADMAP.md).
