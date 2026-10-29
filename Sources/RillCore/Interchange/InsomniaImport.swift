import Foundation

public enum InsomniaImportError: LocalizedError {
    case invalid, unsupported
    public var errorDescription: String? {
        switch self {
        case .invalid:
            "Expected bounded Insomnia v4 JSON or v5 collection/environment YAML with valid resource references."
        case .unsupported:
            "Unsupported Insomnia auth, body, scoped variables, template expression or non-HTTP resource. No data was applied."
        }
    }
}
public enum InsomniaImporter {
    public static func load(from url: URL) throws -> ForeignWorkspaceImport {
        try parse(WorkspaceFile.readBounded(from: url))
    }
    public static func parse(_ input: Data) throws -> ForeignWorkspaceImport {
        guard input.count <= ResourceLimits.workspaceBytes else { throw WorkspaceError.tooLarge }
        let bytes = input.starts(with: [0xef, 0xbb, 0xbf]) ? Data(input.dropFirst(3)) : input
        let root: [String: Any]
        if let first = bytes.first(where: { ![9, 10, 13, 32].contains($0) }), first == 123 {
            try WorkspaceFile.checkJSONBounds(bytes)
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            else { throw InsomniaImportError.invalid }
            root = object
        } else {
            root = try BoundedYAML.object(bytes)
        }
        return try Adapter().decode(root)
    }
    private final class Adapter {
        var scripts: [[ForeignScriptSource]] = [], parameters: [[Field]] = []
        var imported = ForeignWorkspaceImport(workspace: Workspace(), warnings: [])
        func string(_ value: Any?) throws -> String {
            guard let value else { return "" }
            guard let text = value as? String else { throw InsomniaImportError.invalid }
            return text
        }
        func template(_ text: String) throws -> String {
            guard !text.contains("{%"), !text.contains("\\{{") else {
                throw InsomniaImportError.unsupported
            }
            let pattern = try NSRegularExpression(pattern: #"\{\{\s*_\.([A-Za-z0-9_-]+)\s*\}\}"#)
            let translated = pattern.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "{{$1}}")
            let remaining = try NSRegularExpression(pattern: #"\{\{\s*_\."#)
            guard
                remaining.firstMatch(
                    in: translated, range: NSRange(translated.startIndex..., in: translated)) == nil
            else { throw InsomniaImportError.unsupported }
            return translated
        }
        func list(_ value: Any?) throws -> [[String: Any]] {
            guard let value else { return [] }
            guard let rows = value as? [[String: Any]], rows.count <= 10_000 else {
                throw InsomniaImportError.invalid
            }
            return rows
        }
        func source(_ object: [String: Any], inherited: [ForeignScriptSource], name: String) throws
            -> [ForeignScriptSource]
        {
            var result = inherited
            if object["scripts"] != nil && !(object["scripts"] is [String: Any]) {
                throw InsomniaImportError.invalid
            }
            let current = object["scripts"] as? [String: Any] ?? [:]
            for (stage, key) in [
                ("preRequest", "preRequestScript"), ("afterResponse", "afterResponseScript"),
            ] {
                let value = current[stage] ?? object[key]
                if let value {
                    let text = try string(value)
                    if !text.isEmpty {
                        result.append(
                            ForeignScriptSource(
                                origin: "Insomnia: " + name, stage: stage, source: text))
                    }
                }
            }
            guard result.count <= 16, result.allSatisfy({ $0.source.utf8.count <= 256 * 1024 }),
                result.reduce(0, { $0 + $1.source.utf8.count }) <= 1024 * 1024
            else { throw InsomniaImportError.unsupported }
            return result
        }
        func authentication(_ value: Any?, inherited: [String: Any]?) throws -> [String: Any]? {
            guard let value else { return inherited }
            guard let auth = value as? [String: Any] else { throw InsomniaImportError.invalid }
            if auth.isEmpty { return inherited }
            if auth["disabled"] as? Bool == true { return ["type": "noauth"] }
            let type = try string(auth["type"])
            switch type {
            case "none": return ["type": "noauth"]
            case "basic":
                guard auth["useISO88591"] as? Bool != true else {
                    throw InsomniaImportError.unsupported
                }
                return [
                    "type": "basic",
                    "basic": [
                        ["key": "username", "value": try template(string(auth["username"]))],
                        ["key": "password", "value": try template(string(auth["password"]))],
                    ],
                ]
            case "bearer":
                guard auth["prefix"] == nil || auth["prefix"] as? String == "Bearer" else {
                    throw InsomniaImportError.unsupported
                }
                return [
                    "type": "bearer",
                    "bearer": [["key": "token", "value": try template(string(auth["token"]))]],
                ]
            case "apikey":
                let location = try string(auth["addTo"])
                guard ["header", "queryParams", "query"].contains(location) else {
                    throw InsomniaImportError.unsupported
                }
                return [
                    "type": "apikey",
                    "apikey": [
                        ["key": "key", "value": try template(string(auth["key"]))],
                        ["key": "value", "value": try template(string(auth["value"]))],
                        ["key": "in", "value": location == "header" ? "header" : "query"],
                    ],
                ]
            default: throw InsomniaImportError.unsupported
            }
        }
        func request(
            _ object: [String: Any], auth: [String: Any]?, hooks: [ForeignScriptSource],
            name: String
        ) throws -> [String: Any] {
            guard scripts.count < 10_000, object["protoFileId"] == nil,
                object["reflectionApi"] == nil,
                try list(object["pathParameters"]).allSatisfy({ $0["disabled"] as? Bool == true })
            else { throw InsomniaImportError.unsupported }
            var result: [String: Any] = [
                "method": try string(object["method"]), "url": try template(string(object["url"])),
            ]
            result["header"] = try list(object["headers"]).map { row in
                [
                    "key": try template(string(row["name"])),
                    "value": try template(string(row["value"])),
                    "disabled": row["disabled"] as? Bool ?? false,
                ]
            }
            if let authentication = try authentication(object["authentication"], inherited: auth) {
                result["auth"] = authentication
            }
            let query = try list(object["parameters"]).map { row -> Field in
                var field = Field(
                    name: try template(string(row["name"])),
                    value: try template(string(row["value"])))
                field.enabled = !(row["disabled"] as? Bool ?? false)
                return field
            }
            parameters.append(query)
            scripts.append(try source(object, inherited: hooks, name: name))
            if let body = object["body"] as? [String: Any], !body.isEmpty {
                let mime = body["mimeType"] as? String ?? "text/plain"
                if let file = body["fileName"] as? String, !file.isEmpty {
                    result["body"] = ["mode": "file", "file": ["src": file]]
                } else if mime == "application/x-www-form-urlencoded"
                    || mime == "multipart/form-data"
                {
                    guard body["params"] != nil || (body["text"] as? String ?? "").isEmpty else {
                        throw InsomniaImportError.unsupported
                    }
                    let mode = mime == "multipart/form-data" ? "formdata" : "urlencoded"
                    let fields = try list(body["params"]).map { row -> [String: Any] in
                        var item: [String: Any] = [
                            "key": try template(string(row["name"])),
                            "disabled": row["disabled"] as? Bool ?? false,
                        ]
                        if row["type"] as? String == "file" {
                            guard mode == "formdata", let file = row["fileName"] as? String else {
                                throw InsomniaImportError.unsupported
                            }
                            item["type"] = "file"
                            item["src"] = file
                        } else {
                            guard row["type"] == nil || row["type"] as? String == "text" else {
                                throw InsomniaImportError.unsupported
                            }
                            item["type"] = "text"
                            item["value"] = try template(string(row["value"]))
                        }
                        return item
                    }
                    result["body"] = ["mode": mode, mode: fields]
                } else if let text = body["text"] as? String {
                    guard mime != "application/graphql" else {
                        throw InsomniaImportError.unsupported
                    }
                    result["body"] = ["mode": "raw", "raw": try template(text)]
                } else {
                    throw InsomniaImportError.unsupported
                }
                guard var headers = result["header"] as? [[String: Any]] else {
                    throw InsomniaImportError.invalid
                }
                if !headers.contains(where: {
                    ($0["key"] as? String)?.lowercased() == "content-type"
                        && $0["disabled"] as? Bool == false
                }) && !["application/x-www-form-urlencoded", "multipart/form-data"].contains(mime) {
                    headers.append(["key": "Content-Type", "value": mime, "disabled": false])
                }
                result["header"] = headers
            } else if object["body"] != nil && !(object["body"] is [String: Any]) {
                throw InsomniaImportError.invalid
            }
            return ["name": name, "request": result]
        }
        func environment(_ object: [String: Any], parent: UUID? = nil) throws -> UUID {
            guard imported.workspace.environments.count < 1_000 else {
                throw InsomniaImportError.invalid
            }
            let confidential = Set(object["confidentialKeys"] as? [String] ?? [])
            let values: [[String: Any]]
            if object["environmentType"] as? String == "kv" {
                values = try list(object["kvPairData"]).map { row in
                    let type = row["type"] as? String
                    guard ["str", "json", "secret"].contains(type ?? "") else {
                        throw InsomniaImportError.unsupported
                    }
                    return [
                        "key": try string(row["name"]), "value": try string(row["value"]),
                        "enabled": row["enabled"] as? Bool ?? true,
                        "type": type == "secret" || row["isConfidential"] as? Bool == true
                            ? "secret" : "default",
                    ]
                }
            } else {
                if object["data"] != nil && !(object["data"] is [String: Any]) {
                    throw InsomniaImportError.invalid
                }
                let data = object["data"] as? [String: Any] ?? [:]
                values = try data.keys.sorted().map { key in
                    let value = data[key]!
                    let text =
                        try (value as? String)
                        ?? String(
                            decoding: JSONSerialization.data(
                                withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
                            as: UTF8.self)
                    return [
                        "key": key, "value": confidential.contains(key) ? text : try template(text),
                        "type": confidential.contains(key) ? "secret" : "default",
                    ]
                }
            }
            let root: [String: Any] = [
                "_postman_variable_scope": "environment",
                "name": object["name"] as? String ?? "Imported environment", "values": values,
            ]
            let parsed = try PostmanImporter.parse(JSONSerialization.data(withJSONObject: root))
            var environment = parsed.workspace.environments[0]
            environment.parentID = parent
            imported.workspace.environments.append(environment)
            imported.workspace.namedSecrets =
                (imported.workspace.namedSecrets ?? []) + (parsed.workspace.namedSecrets ?? [])
            imported.secretValues.merge(parsed.secretValues) { _, new in new }
            return environment.id
        }
        func decode(_ root: [String: Any]) throws -> ForeignWorkspaceImport {
            let object: [String: Any]
            if (root["__export_format"] as? Int) == 4 {
                object = try legacy(root)
            } else {
                guard
                    ["collection.insomnia.rest/5.0", "environment.insomnia.rest/5.0"].contains(
                        root["type"] as? String ?? ""),
                    root["schema_version"] == nil
                        || ["5.0", "5.1"].contains(root["schema_version"] as? String ?? "")
                else { throw InsomniaImportError.invalid }
                object = root
            }
            let rootAuth = try authentication(object["authentication"], inherited: nil)
            let rootScripts = try source(
                object, inherited: [], name: object["name"] as? String ?? "Collection")
            let items = try walk(
                list(object["collection"]), auth: rootAuth, hooks: rootScripts, depth: 0)
            let collection: [String: Any] = [
                "info": [
                    "name": object["name"] as? String ?? "Insomnia import",
                    "schema":
                        "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
                ], "item": items,
            ]
            let requests = try PostmanImporter.parse(
                JSONSerialization.data(withJSONObject: collection))
            imported.workspace.collections = requests.workspace.collections
            imported.workspace.requests = requests.workspace.requests
            guard scripts.count == imported.workspace.requests.count else {
                throw InsomniaImportError.invalid
            }
            for i in scripts.indices {
                imported.workspace.requests[i].foreignScripts =
                    scripts[i].isEmpty ? nil : scripts[i]
                imported.workspace.requests[i].parameters = parameters[i]
            }
            if let base = object["environments"] as? [String: Any] {
                let id = try environment(base)
                for child in try list(base["subEnvironments"]) {
                    _ = try environment(child, parent: id)
                }
            }
            imported.warnings =
                requests.warnings.filter { !$0.contains("Postman") } + [
                    "Insomnia folders are flattened into collection breadcrumbs and supported inherited auth is copied to requests. Folder-scoped variables, non-HTTP resources and dynamic template tags are unsupported.",
                    "Foreign script text is retained DISABLED for review only; it has no execution API. Scripts may contain secrets and remain plain text in native workspaces/backups. Cookies, certificates, plugins, tests, examples and transport settings are omitted.",
                    "Simple {{ _.name }} references become {{name}}. Nested JSON variable values remain JSON strings; nested selectors are unsupported. Environment privacy/color/sort metadata is omitted; marked confidential values move to Keychain.",
                ]
            try WorkspaceFile.validate(imported.workspace)
            return imported
        }
        func walk(
            _ rows: [[String: Any]], auth: [String: Any]?, hooks: [ForeignScriptSource], depth: Int
        ) throws -> [[String: Any]] {
            guard depth <= 32 else { throw InsomniaImportError.invalid }
            return try rows.map { row in
                try Task.checkCancellation()
                let name = row["name"] as? String ?? "Imported request"
                guard name.utf8.count <= 4000 else { throw InsomniaImportError.invalid }
                if row["children"] != nil {
                    guard
                        row["environment"] == nil
                            || (row["environment"] as? [String: Any])?.isEmpty == true
                    else { throw InsomniaImportError.unsupported }
                    let authentication = try authentication(row["authentication"], inherited: auth)
                    let sources = try source(row, inherited: hooks, name: name)
                    return [
                        "name": name,
                        "item": try walk(
                            list(row["children"]), auth: authentication, hooks: sources,
                            depth: depth + 1),
                    ]
                }
                return try request(row, auth: auth, hooks: hooks, name: name)
            }
        }
        func legacy(_ root: [String: Any]) throws -> [String: Any] {
            let resources = try list(root["resources"])
            var byID: [String: [String: Any]] = [:]
            var children: [String: [[String: Any]]] = [:]
            let known = Set([
                "workspace", "request", "request_group", "folder", "environment", "response",
                "cookie_jar", "api_spec", "unit_test", "unit_test_suite", "plugin",
                "client_certificate", "ca_certificate", "proto_file", "mock",
            ])
            for row in resources {
                guard known.contains(row["_type"] as? String ?? "") else {
                    throw InsomniaImportError.unsupported
                }
                guard let id = row["_id"] as? String, byID[id] == nil else {
                    throw InsomniaImportError.invalid
                }
                byID[id] = row
                if let parent = row["parentId"] as? String {
                    children[parent, default: []].append(row)
                }
            }
            let workspaces = resources.filter { $0["_type"] as? String == "workspace" }
            guard workspaces.count == 1, let rootID = workspaces[0]["_id"] as? String else {
                throw InsomniaImportError.unsupported
            }
            var visited = Set<String>()
            func convert(_ id: String, depth: Int) throws -> [[String: Any]] {
                guard depth <= 32, visited.insert(id).inserted else {
                    throw InsomniaImportError.invalid
                }
                return try (children[id] ?? []).filter {
                    ["request", "request_group", "folder"].contains($0["_type"] as? String ?? "")
                }.map { row in
                    guard let rowID = row["_id"] as? String else {
                        throw InsomniaImportError.invalid
                    }
                    var copy = row
                    if row["_type"] as? String != "request" {
                        copy["children"] = try convert(rowID, depth: depth + 1)
                    } else {
                        visited.insert(rowID)
                    }
                    return copy
                }
            }
            for key in Array(children.keys) {
                children[key] = children[key]!.enumerated().sorted { lhs, rhs in
                    let left = lhs.element["metaSortKey"] as? Double ?? Double(lhs.offset)
                    let right = rhs.element["metaSortKey"] as? Double ?? Double(rhs.offset)
                    return left == right ? lhs.offset < rhs.offset : left < right
                }.map(\.element)
            }
            let collection = try convert(rootID, depth: 0)
            for row in resources
            where ["request", "request_group", "folder"].contains(row["_type"] as? String ?? "") {
                guard let rowID = row["_id"] as? String, visited.contains(rowID) else {
                    throw InsomniaImportError.invalid
                }
            }
            let envs = resources.filter { $0["_type"] as? String == "environment" }
            let bases = envs.filter { $0["parentId"] as? String == rootID }
            guard bases.count <= 1 else { throw InsomniaImportError.unsupported }
            var result = workspaces[0]
            result["collection"] = collection
            result["name"] = workspaces[0]["name"] as? String ?? "Insomnia import"
            if var base = bases.first {
                guard let baseID = base["_id"] as? String else { throw InsomniaImportError.invalid }
                let subs = envs.filter { $0["parentId"] as? String == baseID }
                guard subs.count + 1 == envs.count else { throw InsomniaImportError.unsupported }
                base["subEnvironments"] = subs
                result["environments"] = base
            } else if !envs.isEmpty {
                throw InsomniaImportError.invalid
            }
            return result
        }
    }
}
