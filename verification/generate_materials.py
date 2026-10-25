#!/usr/bin/env python3
"""Rebuild synthetic materials with stable identities; never reads a user workspace."""

import base64
import json
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent
M = ROOT / "materials"
M.mkdir(exist_ok=True)


def uid(name):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "https://rill.test/verification/" + name)).upper()


def write(name, value):
    (M / name).write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def field(name, value):
    return {"id": uid(name + value), "enabled": True, "name": name, "value": value}


collections = [
    {"id": uid(x), "name": x}
    for x in ["Kit — Smoke", "Kit — Workflow", "Kit — Retry", "Kit — Expected failures"]
]
requests = []


def request(name, path, collection=0, method="GET", status="200", body="", headers=None):
    r = {
        "id": uid(name),
        "collectionID": collections[collection]["id"],
        "name": name,
        "method": method,
        "url": "{{base_url}}" + path,
        "headers": [field(k, v) for k, v in (headers or {}).items()],
        "parameters": [],
        "body": body,
        "bodyMode": "Raw text" if body else "None",
        "contentType": "application/json",
        "auth": "None",
        "username": "",
        "credential": "",
        "timeout": 5,
        "expectedStatus": status,
        "bodyContains": "",
    }
    requests.append(r)
    return r


request("Health", "/health")["bodyContains"] = "verification kit"
r = request("JSON inspection", "/json")
r["assertions"] = [
    {
        "id": uid("assert-json"),
        "enabled": True,
        "kind": "jsonEquals",
        "selector": "$.items[0].price",
        "expected": "12.5",
    }
]
request("Repeated query and Unicode", "/echo?tag=one&tag=two&empty=&name=caf%C3%A9")
for method in ["POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"]:
    request(
        method + " echo",
        "/echo",
        method=method,
        body='{"message":"Hello 👋","count":42}' if method in ["POST", "PUT", "PATCH"] else "",
    )
request("Bearer demo", "/auth/bearer", headers={"Authorization": "Bearer rill-demo-token"})
request(
    "Basic demo",
    "/auth/basic",
    headers={"Authorization": "Basic " + base64.b64encode(b"rill:demo-password").decode()},
)
request("API key demo", "/auth/api-key", headers={"X-API-Key": "rill-demo-key"})
r = request("Create synthetic session", "/session", 1, "POST", "201", body="{}")
r["extractions"] = [
    {
        "id": uid("extract-token"),
        "enabled": True,
        "kind": "json",
        "selector": "$.token",
        "variable": "sessionToken",
    }
]
request("Use extracted token", "/profile", 1, headers={"Authorization": "Bearer {{sessionToken}}"})
request("Recover on retry", "/flaky?key=collection", 2)
request("Intentional assertion failure", "/json", 3, status="201")
r = request("Intentional timeout", "/delay/3", 3)
r["timeout"] = 1
request("Intentional unauthorized", "/auth/bearer", 3)
request("Intentional response limit", "/bytes/17825792", 3)
env = {
    "id": uid("env"),
    "name": "Verification local",
    "variables": [
        field("base_url", "http://127.0.0.1:18990"),
        field("greeting", "Hello from Rill"),
    ],
}
workspace = {
    "version": 1,
    "collections": collections,
    "requests": requests,
    "environments": [env],
    "selectedEnvironmentID": env["id"],
    "history": [],
}
write("rill-workspace.json", workspace)
# Postman is intentionally only an interchange sample; native assertions/extraction live above.
items = []
for name, path, method, body in [
    ("Health", "/health", "GET", ""),
    ("Echo JSON", "/echo", "POST", '{"hello":"Rill"}'),
    ("Query", "/echo?tag=one&tag=two", "GET", ""),
]:
    r = {"method": method, "header": [], "url": "{{base_url}}" + path}
    if body:
        r["header"] = [{"key": "Content-Type", "value": "application/json"}]
        r["body"] = {"mode": "raw", "raw": body}
    items.append({"name": name, "request": r})
write(
    "postman-collection.json",
    {
        "info": {
            "name": "Rill kit Postman import",
            "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
        },
        "item": items,
        "variable": [{"key": "base_url", "value": "http://127.0.0.1:18990"}],
    },
)
write(
    "postman-environment.json",
    {
        "name": "Rill kit local",
        "values": [
            {
                "key": "base_url",
                "value": "http://127.0.0.1:18990",
                "enabled": True,
                "type": "default",
            }
        ],
        "_postman_variable_scope": "environment",
    },
)
write(
    "payload.json",
    {
        "name": "Rill demo",
        "quantity": 2,
        "tags": ["local", "synthetic"],
        "nested": {"enabled": True},
        "unicode": "café 👋",
    },
)
write(
    "payload.schema.json",
    {
        "type": "object",
        "required": ["name", "quantity"],
        "properties": {"name": {"type": "string"}, "quantity": {"type": "integer", "minimum": 1}},
        "additionalProperties": True,
    },
)
write("payload-invalid-schema.json", {"name": 12, "quantity": -1})
write(
    "cloudevent.json",
    {
        "specversion": "1.0",
        "id": "rill-kit-event-001",
        "source": "urn:rill:verification",
        "type": "dev.rill.order.created",
        "time": "2026-10-25T00:00:00Z",
        "datacontenttype": "application/json",
        "data": {"orderId": 42, "total": 12.5},
    },
)
write("graphql-variables.json", {"recipient": "Rill", "count": 42})
(M / "query.graphql").write_text(
    "query Echo($recipient: String!) { hello(recipient: $recipient) }\n"
)
(M / "subscription.graphql").write_text("subscription { value }\n")
(M / "echo.proto").write_text(
    'syntax = "proto3";\npackage rill.kit;\nmessage EchoMessage {\n  string text = 1;\n  int32 count = 2;\n}\nservice Echo {\n  rpc Unary(EchoMessage) returns (EchoMessage);\n  rpc ServerStream(EchoMessage) returns (stream EchoMessage);\n  rpc ClientStream(stream EchoMessage) returns (EchoMessage);\n  rpc Bidi(stream EchoMessage) returns (stream EchoMessage);\n}\n'
)

write("grpc-message.json", {"text": "Hello from Rill", "count": 42})
write(
    "mock-routes.json",
    [
        {
            "method": "GET",
            "path": "/demo",
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": '{"mocked":true}',
        },
        {"method": "POST", "path": "/orders", "status": 201, "body": '{"id":42}'},
    ],
)
write(
    "pre-hook.json",
    [
        {"op": "uuid", "name": "requestId"},
        {"op": "header", "name": "X-Request-ID", "value": "{{requestId}}"},
        {"op": "set", "name": "kitRun", "value": "manual"},
    ],
)
write("post-hook.json", [{"op": "set", "name": "postHookRan", "value": "yes"}])
write(
    "openapi.json",
    {
        "openapi": "3.0.3",
        "info": {"title": "Rill verification API", "version": "1.0.0"},
        "servers": [{"url": "http://127.0.0.1:18990"}],
        "paths": {
            "/health": {
                "get": {"operationId": "health", "responses": {"200": {"description": "Healthy"}}}
            },
            "/json": {
                "get": {
                    "operationId": "getDemo",
                    "responses": {
                        "200": {
                            "description": "Demo",
                            "content": {
                                "application/json": {
                                    "schema": {
                                        "type": "object",
                                        "required": ["id"],
                                        "properties": {"id": {"type": "integer"}},
                                    }
                                }
                            },
                        }
                    },
                }
            },
        },
    },
)
spec = json.loads((M / "openapi.json").read_text())
spec["info"]["version"] = "1.1.0"
spec["paths"]["/echo"] = {
    "post": {"operationId": "echo", "responses": {"200": {"description": "Echo"}}}
}
write("openapi-updated.json", spec)
write(
    "insomnia-v4.json",
    {
        "_type": "export",
        "__export_format": 4,
        "resources": [
            {"_id": "wrk_kit", "_type": "workspace", "name": "Rill kit Insomnia"},
            {
                "_id": "env_kit",
                "_type": "environment",
                "parentId": "wrk_kit",
                "name": "Base",
                "data": {"base_url": "http://127.0.0.1:18990"},
            },
            {
                "_id": "req_kit",
                "_type": "request",
                "parentId": "wrk_kit",
                "name": "Health",
                "method": "GET",
                "url": "http://127.0.0.1:18990/health",
                "headers": [],
                "parameters": [],
                "body": {},
                "authentication": {},
            },
        ],
    },
)
write(
    "request.har",
    {
        "log": {
            "version": "1.2",
            "creator": {"name": "Rill verification kit", "version": "1"},
            "entries": [
                {
                    "request": {
                        "method": "GET",
                        "url": "http://127.0.0.1:18990/json",
                        "httpVersion": "HTTP/1.1",
                        "headers": [],
                        "queryString": [],
                        "cookies": [],
                        "headersSize": -1,
                        "bodySize": 0,
                    },
                    "response": {
                        "status": 200,
                        "statusText": "OK",
                        "headers": [],
                        "content": {"size": 0, "mimeType": "application/json"},
                        "redirectURL": "",
                        "headersSize": -1,
                        "bodySize": 0,
                    },
                }
            ],
        }
    },
)
(M / "health.bru").write_text(
    "meta {\n  name: Rill kit health\n  type: http\n  seq: 1\n}\nget {\n  url: http://127.0.0.1:18990/health\n  body: none\n  auth: none\n}\n"
)
(M / "commands.txt").write_text(
    "curl -X POST 'http://127.0.0.1:18990/echo?tag=one&tag=two' -H 'Content-Type: application/json' --data '{\"hello\":\"Rill\"}'\nhttp GET http://127.0.0.1:18990/json\n"
)
(M / "invalid-json.json").write_text('{"broken":\n')
invalid = json.loads(json.dumps(workspace))
invalid["requests"].append(invalid["requests"][0])
write("invalid-duplicate-ids.json", invalid)
(ROOT / "uploads" / "sample.txt").write_text("Rill upload verification\nUnicode: café 👋\n")
(ROOT / "uploads" / "sample.bin").write_bytes(bytes(range(256)) * 4)
(ROOT / "uploads" / "sample.xml").write_text('<order id="42"><total>12.50</total></order>\n')
print("Generated", len(list(M.iterdir())), "material files and 3 uploads.")

plugin = M / "plugins" / "rill-kit"
plugin.mkdir(parents=True, exist_ok=True)
(plugin / "rill-plugin.json").write_text(
    json.dumps(
        {
            "apiVersion": 1,
            "id": "rill-kit",
            "name": "Rill verification data services",
            "version": "1.0.0",
            "services": [
                {"id": "health", "kind": "requestTemplate", "file": "health.json"},
                {"id": "mocks", "kind": "mockRoutes", "file": "routes.json"},
            ],
        },
        indent=2,
    )
    + "\n"
)
template = dict(requests[0])
template.pop("collectionID", None)
(plugin / "health.json").write_text(json.dumps(template, indent=2) + "\n")
(plugin / "routes.json").write_text((M / "mock-routes.json").read_text())
