import Foundation

public enum HTTPieDesktopImportError: LocalizedError {
    case invalid, unsupported, postmanCollection
    public var errorDescription: String? {
        switch self {
        case .invalid:
            "Expected a bounded HTTPie Desktop 1.0.0 JSON workspace, collection, request or environment export."
        case .postmanCollection:
            "This file is a Postman collection. Choose Import Postman JSON… to import it; it is not an HTTPie Desktop export."
        case .unsupported:
            "The HTTPie export contains an unsupported path parameter, auth, file-text body or malformed active body. No data was applied."
        }
    }
}
/// Independent format adapter. The common Postman parser supplies field validation,
/// supported-body conversion and auth extraction; no foreign code is executed.
public enum HTTPieDesktopImporter {
    public static func load(from url: URL) throws -> ForeignWorkspaceImport {
        try parse(WorkspaceFile.readBounded(from: url))
    }
    public static func parse(_ input: Data) throws -> ForeignWorkspaceImport {
        try WorkspaceFile.checkJSONBounds(input)
        let data = input.starts(with: [0xef, 0xbb, 0xbf]) ? Data(input.dropFirst(3)) : input
        guard String(data: data, encoding: .utf8) != nil,
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw HTTPieDesktopImportError.invalid }
        if let info = root["info"] as? [String: Any], let schema = info["schema"] as? String,
            URL(string: schema)?.host == "schema.getpostman.com"
        {
            throw HTTPieDesktopImportError.postmanCollection
        }
        guard let meta = root["meta"] as? [String: Any], meta["format"] as? String == "httpie",
            meta["version"] as? String == "1.0.0",
            let kind = meta["contentType"] as? String, let entry = root["entry"] as? [String: Any]
        else { throw HTTPieDesktopImportError.invalid }
        func escaped(_ value: Any) -> Bool {
            if let value = value as? String { return value.contains("\\{{") }
            if let values = value as? [Any] { return values.contains(where: escaped) }
            if let values = value as? [String: Any] {
                return values.values.contains(where: escaped)
            }
            return false
        }
        guard !escaped(entry) else { throw HTTPieDesktopImportError.unsupported }
        return try Adapter().decode(entry, kind: kind)
    }
    private final class Adapter {
        var queryFields: [[Field]] = []
        func rows(_ value: Any?) throws -> [[String: Any]] {
            guard let rows = value as? [[String: Any]], rows.count <= 10_000 else {
                throw HTTPieDesktopImportError.invalid
            }
            return rows
        }
        func fields(_ value: Any?) throws -> [Field] {
            try rows(value).map { row in
                guard let name = row["name"] as? String, let value = row["value"] as? String,
                    let enabled = row["enabled"] as? Bool
                else { throw HTTPieDesktopImportError.invalid }
                var field = Field(name: name, value: value)
                field.enabled = enabled
                return field
            }
        }
        func auth(_ value: Any?, inherited: Bool) throws -> [String: Any]? {
            guard let source = value as? [String: Any], let type = source["type"] as? String else {
                throw HTTPieDesktopImportError.invalid
            }
            if type == "inherited" {
                guard inherited else { throw HTTPieDesktopImportError.unsupported }
                return nil
            }
            if type == "none" { return ["type": "noauth"] }
            guard let credentials = source["credentials"] as? [String: Any],
                let username = credentials["username"] as? String,
                let password = credentials["password"] as? String
            else { throw HTTPieDesktopImportError.invalid }
            switch type {
            case "basic":
                return [
                    "type": "basic",
                    "basic": [
                        ["key": "username", "value": username],
                        ["key": "password", "value": password],
                    ],
                ]
            case "bearer":
                guard username.isEmpty else { throw HTTPieDesktopImportError.unsupported }
                return ["type": "bearer", "bearer": [["key": "token", "value": password]]]
            case "apiKey":
                guard let target = source["target"] as? String,
                    ["headers", "params"].contains(target)
                else { throw HTTPieDesktopImportError.unsupported }
                return [
                    "type": "apikey",
                    "apikey": [
                        ["key": "key", "value": username], ["key": "value", "value": password],
                        ["key": "in", "value": target == "params" ? "query" : "header"],
                    ],
                ]
            default: throw HTTPieDesktopImportError.unsupported
            }
        }
        func request(_ source: [String: Any], inherited: Bool) throws -> [String: Any] {
            try Task.checkCancellation()
            guard queryFields.count < 10_000, let url = source["url"] as? String,
                let method = source["method"] as? String,
                let body = source["body"] as? [String: Any], let bodyType = body["type"] as? String,
                !(try fields(source["pathParams"])).contains(where: \.enabled)
            else { throw HTTPieDesktopImportError.unsupported }
            queryFields.append(try fields(source["queryParams"]))
            var result: [String: Any] = [
                "url": url, "method": method,
                "header": try fields(source["headers"]).map {
                    ["key": $0.name, "value": $0.value, "disabled": !$0.enabled] as [String: Any]
                },
            ]
            if let authentication = try auth(source["auth"], inherited: inherited) {
                result["auth"] = authentication
            }
            switch bodyType {
            case "none": break
            case "text":
                guard let text = body["text"] as? [String: Any],
                    let value = text["value"] as? String, let mime = text["format"] as? String,
                    ["text/plain", "application/json", "application/xml", "text/yaml"].contains(
                        mime)
                else { throw HTTPieDesktopImportError.unsupported }
                result["body"] = ["mode": "raw", "raw": value]
                guard var headers = result["header"] as? [[String: Any]] else {
                    throw HTTPieDesktopImportError.invalid
                }
                if !headers.contains(where: {
                    ($0["key"] as? String)?.lowercased() == "content-type"
                        && $0["disabled"] as? Bool == false
                }) {
                    headers.append(["key": "Content-Type", "value": mime, "disabled": false])
                }
                result["header"] = headers
            case "file":
                guard let file = body["file"] as? [String: Any], let name = file["name"] as? String
                else { throw HTTPieDesktopImportError.unsupported }
                result["body"] = ["mode": "file", "file": ["src": name]]
            case "form":
                guard let form = body["form"] as? [String: Any],
                    let multipart = form["isMultipart"] as? Bool
                else { throw HTTPieDesktopImportError.unsupported }
                let converted: [[String: Any]] = try rows(form["fields"]).map { row in
                    guard let name = row["name"] as? String, let enabled = row["enabled"] as? Bool,
                        let type = row["type"] as? String
                    else { throw HTTPieDesktopImportError.invalid }
                    var field: [String: Any] = ["key": name, "disabled": !enabled]
                    if type == "text", let value = row["value"] as? String {
                        field["type"] = "text"
                        field["value"] = value
                    } else if type == "file", multipart, let file = row["file"] as? [String: Any],
                        let name = file["name"] as? String
                    {
                        field["type"] = "file"
                        field["src"] = name
                    } else {
                        throw HTTPieDesktopImportError.unsupported
                    }
                    return field
                }
                let mode = multipart ? "formdata" : "urlencoded"
                result["body"] = ["mode": mode, mode: converted]
            default: throw HTTPieDesktopImportError.unsupported
            }
            return ["name": source["name"] as? String ?? "Imported request", "request": result]
        }
        func collection(_ source: [String: Any]) throws -> [String: Any] {
            let authentication = try auth(source["auth"], inherited: false)
            return [
                "name": source["name"] as? String ?? "Imported collection",
                "auth": authentication ?? ["type": "noauth"],
                "item": try rows(source["requests"]).map { try request($0, inherited: true) },
            ]
        }
        func decode(_ entry: [String: Any], kind: String) throws -> ForeignWorkspaceImport {
            var items: [[String: Any]] = []
            var environments: [[String: Any]] = []
            switch kind {
            case "workspace":
                let collections = try rows(entry["collections"])
                guard collections.count <= 1_000 else { throw HTTPieDesktopImportError.invalid }
                items = try collections.map(collection)
                items += try rows(entry["drafts"]).map { try request($0, inherited: false) }
                environments = try rows(entry["environments"])
                guard environments.count <= 1_000 else { throw HTTPieDesktopImportError.invalid }
            case "collection": items = [try collection(entry)]
            case "request": items = [try request(entry, inherited: false)]
            case "environment": environments = [entry]
            default: throw HTTPieDesktopImportError.invalid
            }
            let object: [String: Any] = [
                "info": [
                    "name": entry["name"] as? String ?? "HTTPie import",
                    "schema":
                        "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
                ], "item": items,
            ]
            var imported =
                kind == "environment"
                ? ForeignWorkspaceImport(workspace: Workspace(), warnings: [])
                : try PostmanImporter.parse(JSONSerialization.data(withJSONObject: object))
            guard imported.workspace.requests.count == queryFields.count else {
                throw HTTPieDesktopImportError.invalid
            }
            for i in queryFields.indices {
                imported.workspace.requests[i].parameters = queryFields[i]
            }
            for environment in environments {
                let values: [[String: Any]] = try rows(environment["variables"]).map { row in
                    guard let name = row["name"] as? String, let value = row["value"] as? String,
                        let secret = row["isSecret"] as? Bool
                    else { throw HTTPieDesktopImportError.invalid }
                    return ["key": name, "value": value, "type": secret ? "secret" : "default"]
                }
                let object: [String: Any] = [
                    "_postman_variable_scope": "environment",
                    "name": environment["name"] as? String ?? "Default", "values": values,
                ]
                let result = try PostmanImporter.parse(
                    JSONSerialization.data(withJSONObject: object))
                guard let added = result.workspace.environments.first else {
                    throw HTTPieDesktopImportError.invalid
                }
                imported.workspace.environments.append(added)
                imported.workspace.namedSecrets =
                    (imported.workspace.namedSecrets ?? []) + (result.workspace.namedSecrets ?? [])
                imported.secretValues.merge(result.secretValues) { _, new in new }
            }
            imported.warnings =
                imported.warnings.filter { !$0.contains("Postman") } + [
                    "HTTPie 1.0.0 workspace/collection/request/environment data is converted independently. Icons, local-only flags, inactive bodies and other presentation metadata are omitted; drafts become saved requests. Supported collection auth is flattened.",
                    "Imported environment sets stay independent; default/local-only flags are omitted. Choose the intended environment before Send. Backslash-escaped templates and active path parameters reject explicitly; configure values locally.",
                ]
            try WorkspaceFile.validate(imported.workspace)
            return imported
        }
    }
}
