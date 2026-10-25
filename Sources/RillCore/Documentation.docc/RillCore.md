# ``RillCore``

Shared services for Rill's native desktop application and command-line executable.

## Workspace and execution

Use ``WorkspaceSession`` for credential-aware open/save operations and ``WorkspaceFile`` for validated portable files. Saved identities are stable; imports regenerate identities before merging. WorkspaceSession performs revision checks to prevent concurrent lost updates. Keep Keychain credentials outside exported data.

``RequestEngine`` executes HTTP requests. Collection, matrix and load runners share request preparation, finite hooks, assertions, extraction and report models. Execution requires an explicit action; constructing a model does not start traffic.

## Native sessions

Native live sessions own bounded queues, deadlines and cancellation. Consult the protocol boundaries in docs/milestones/M6.md and M7.md before assuming unsupported protocol features. Foreign scripts never execute as native hooks.

## Collaboration

``WorkspaceSharing`` sanitizes read-only snapshots. ``WorkspaceShareServer`` defaults to loopback and requires a token. ``WorkspaceGit`` operates only on an explicitly selected portable checkout. ``PluginRegistry`` registers reviewed data services; it never loads executable plugins.

## Resource and privacy policy

Outputs may contain entered request or response content only through explicit export choices. Reports and diagnostics use redacted models. Errors, truncation and unsupported schema/protocol behavior must be surfaced rather than treated as successful validation.
