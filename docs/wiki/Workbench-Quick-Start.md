# Workbench quick start

Open [Rill 0.4.5](https://github.com/alby-raju/Rill/releases/tag/v0.4.5-dev.1), choose **New request**, enter a URL, and click **Send**. Open the chevron beside **New request** for templates. Use the response tabs to inspect the body, headers, and checks.

## Organize requests

Use **Collection actions** beside the Collections heading to create a collection or select all visible requests. Command-click to select individual requests or Shift-click for a range. Open the selection count menu to duplicate, copy, move, or delete. Moves keep request identity and unsaved edits. Delete shows a confirmation before removing selected requests and drafts.

## Find tools

Open **Workspace tools** in the sidebar and search or browse by category. The macOS **Workspace** menu also lists these tools.

- **Request setup** has Environments, Authentication and Secrets, and TLS Profiles. Authentication separates reusable profiles from Keychain-backed secrets.
- **Sessions and testing** has Response History, Cookie Manager, Collection Runner, and API Definitions and Tools.
- **Protocols** has live connections, gRPC, and message brokers.
- **Files and integrations** has native workspace import/export, backup, and Git, sharing, and extension tools.

Use **File** for request and collection interchange. Use **Request** for send, search, and tab commands.

## Cookies and local verification

Workbench HTTP requests capture server cookies and replay them for matching requests. Open **Cookie Manager** to filter, reveal, remove, or clear cookies. The jar clears when Rill quits. CLI and runner sessions do not share it.

For synthetic endpoints and collections, follow the [verification kit guide](https://github.com/alby-raju/Rill/tree/main/verification). Find documented boundaries in [Features and supported limits](https://github.com/alby-raju/Rill/blob/main/docs/FEATURES.md).
