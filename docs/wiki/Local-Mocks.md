# Local mock servers

Mocks already exist in Rill. In the app open:

**Request → API Definitions / Contracts / Mocks… → Mocks**

Edit method/path/status/header/body routes as JSON, choose a port (0 chooses a free one), and click **Start mock server**. Copy the displayed address to a request. The current server binds to loopback, runs no route scripts and stops when this tool window closes. It is not a persistent background service.

You can also generate editable routes from a supported OpenAPI definition in the same tool.

## Run the synthetic sample from Terminal

From a repository checkout, with the CLI alias configured:

```sh
rill mock-serve --routes ./verification/materials/mock-routes.json --port 18995
```

Wait for startup/readiness output. Ctrl+C stops the listener. If the port is occupied, choose another port. These fixtures are synthetic; review route files before using sensitive data.

A visible Mocks navigation entry, persistent projects, editor-independent lifecycle, request journals and scenarios are [planned improvements](https://github.com/alby-raju/Rill/blob/main/ROADMAP.md#3-first-class-mock-workbench), not current features. See [features and limits](https://github.com/alby-raju/Rill/blob/main/docs/FEATURES.md).
