import Foundation

public enum PostmanImportError: LocalizedError {
    case invalid, unsupported, unsupportedBody
    public var errorDescription: String? {
        switch self {
        case .invalid: "Expected a bounded Postman v2.0/v2.1 collection or environment JSON export."
        case .unsupportedBody:
            "A GET or HEAD request contains a nonempty or structured body, which Rill's current HTTP transport cannot send. No data was applied."
        case .unsupported:
            "This Postman export contains an unsupported or ambiguous auth, URL, variable, header or body representation. No data was applied."
        }
    }
}
public enum PostmanImporter {
    public static func load(from url: URL) throws -> ForeignWorkspaceImport {
        try parse(WorkspaceFile.readBounded(from: url))
    }
    public static func parse(_ input: Data) throws -> ForeignWorkspaceImport {
        try WorkspaceFile.checkJSONBounds(input)
        let data = input.starts(with: [0xef, 0xbb, 0xbf]) ? Data(input.dropFirst(3)) : input
        guard String(data: data, encoding: .utf8) != nil,
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw PostmanImportError.invalid }
        return try Decoder().decode(root)
    }
    private final class Decoder {
        var requestBytes = 0
        var workspace = Workspace(), secrets: [UUID: String] = [:], warnings: Set<String> = []
        func text(_ value: Any?) throws -> String {
            guard let value, !(value is NSNull) else { return "" }
            if let string = value as? String { return string }
            guard JSONSerialization.isValidJSONObject([value]) else {
                throw PostmanImportError.unsupported
            }
            let data = try JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
        func variables(_ rows: Any?, name: String) throws {
            guard let rows else { return }
            guard let rows = rows as? [[String: Any]], rows.count <= 10_000 else {
                throw PostmanImportError.invalid
            }
            var environment = Environment(name: name)
            var names = Set<String>()
            for row in rows {
                guard let key = row["key"] as? String, !key.isEmpty, names.insert(key).inserted
                else { throw PostmanImportError.unsupported }
                var field = Field(name: key, value: try text(row["value"]))
                field.enabled = row["enabled"] as? Bool ?? !(row["disabled"] as? Bool ?? false)
                if row["type"] as? String == "secret" {
                    let secret = NamedSecret(name: "postman-" + UUID().uuidString)
                    workspace.namedSecrets = (workspace.namedSecrets ?? []) + [secret]
                    secrets[secret.id] = field.value
                    field.value = "{{secret:" + secret.name + "}}"
                }
                environment.variables.append(field)
            }
            workspace.environments.append(environment)
            warnings.insert(
                "Imported variable sets become Rill environments. Select the intended environment before Send; Postman scope precedence, dynamic variables and Vault providers are not reproduced."
            )
        }
        func decode(_ root: [String: Any]) throws -> ForeignWorkspaceImport {
            if root["_postman_variable_scope"] as? String == "environment" {
                guard root["values"] is [[String: Any]] else { throw PostmanImportError.invalid }
                try variables(
                    root["values"], name: root["name"] as? String ?? "Imported Postman environment")
            } else {
                guard let info = root["info"] as? [String: Any],
                    let schema = info["schema"] as? String,
                    schema.contains("/v2.1.0/") || schema.contains("/v2.0.0/"),
                    let items = root["item"] as? [[String: Any]]
                else { throw PostmanImportError.invalid }
                let name = info["name"] as? String ?? "Imported Postman collection"
                try variables(root["variable"], name: name + " variables")
                try note(root)
                try walk(items, path: [name], auth: root["auth"] as? [String: Any], depth: 0)
            }
            try WorkspaceFile.validate(workspace)
            return ForeignWorkspaceImport(
                workspace: workspace, warnings: warnings.sorted(), secretValues: secrets)
        }
        func note(_ object: [String: Any]) throws {
            if let auth = object["auth"], !(auth is NSNull), !(auth is [String: Any]) {
                throw PostmanImportError.invalid
            }
            if object["item"] != nil && !(object["item"] is [[String: Any]]) {
                throw PostmanImportError.invalid
            }
            if let events = object["event"] as? [Any], !events.isEmpty {
                warnings.insert(
                    "Postman scripts/tests are omitted and never executed. Recreate checks and hooks with Rill APIs; no foreign SDK compatibility is claimed."
                )
            }
            if object["protocolProfileBehavior"] != nil || object["certificate"] != nil
                || object["proxy"] != nil
            {
                warnings.insert(
                    "Postman protocol, proxy and certificate settings are omitted; configure Rill transport explicitly."
                )
            }
            if object["response"] != nil {
                warnings.insert(
                    "Saved response examples and descriptions are not imported as captured exchanges."
                )
            }
        }
        func walk(_ items: [[String: Any]], path: [String], auth: [String: Any]?, depth: Int) throws
        {
            guard depth <= 32, items.count <= 10_000 else { throw PostmanImportError.invalid }
            let breadcrumb = path.joined(separator: " / ")
            guard breadcrumb.utf8.count <= 4096 else { throw PostmanImportError.invalid }
            let collection = RequestCollection(name: breadcrumb)
            // Preserve intentionally empty leaves, but do not materialize
            // grouping-only parents in Rill's flat collection model.
            if items.isEmpty || items.contains(where: { $0["item"] == nil }) {
                workspace.collections.append(collection)
            }
            guard workspace.collections.count <= 1_000 else { throw PostmanImportError.invalid }
            for item in items {
                try Task.checkCancellation()
                try note(item)
                if item["variable"] != nil { throw PostmanImportError.unsupported }
                let inherited = item["auth"] as? [String: Any] ?? auth
                let name = item["name"] as? String ?? "Imported request"
                if let children = item["item"] as? [[String: Any]] {
                    try walk(children, path: path + [name], auth: inherited, depth: depth + 1)
                } else {
                    guard workspace.requests.count < 10_000 else {
                        throw PostmanImportError.invalid
                    }
                    var request = try request(item["request"], inherited: inherited)
                    guard name.utf8.count <= 4096, request.credential.utf8.count <= 1024 * 1024
                    else { throw PostmanImportError.invalid }
                    request.name = name
                    request.collectionID = collection.id
                    requestBytes += try JSONEncoder().encode(request).count
                    guard requestBytes <= ResourceLimits.workspaceBytes else {
                        throw WorkspaceError.tooLarge
                    }
                    workspace.requests.append(request)
                }
            }
            warnings.insert(
                "Nested folders become collection breadcrumbs; grouping-only parents are omitted. Supported inherited auth is flattened onto each request; future parent edits do not propagate."
            )
        }
        func request(_ value: Any?, inherited: [String: Any]?) throws -> RequestDraft {
            let object: [String: Any]
            if let value = value as? String {
                object = ["method": "GET", "url": value]
            } else if let value = value as? [String: Any] {
                object = value
            } else {
                throw PostmanImportError.invalid
            }
            try note(object)
            guard object["variable"] == nil,
                let method = HTTPMethod(rawValue: object["method"] as? String ?? "GET")
            else { throw PostmanImportError.unsupported }
            var result = RequestDraft()
            result.method = method
            result.bodyMode = RequestBodyMode.none
            if let address = object["url"] as? String {
                result.url = address
            } else if let address = object["url"] as? [String: Any],
                let raw = address["raw"] as? String
            {
                result.url = raw
                if let query = address["query"] as? [[String: Any]],
                    query.contains(where: { $0["disabled"] as? Bool == true })
                {
                    // Raw may still include disabled pairs. Rebuild only this explicit case.
                    guard var components = URLComponents(string: raw) else {
                        throw PostmanImportError.unsupported
                    }
                    components.percentEncodedQuery = nil
                    result.url = components.string ?? raw
                    result.parameters = try query.map { row in
                        guard let key = row["key"] as? String else {
                            throw PostmanImportError.invalid
                        }
                        var field = Field(name: key, value: try text(row["value"]))
                        field.enabled = !(row["disabled"] as? Bool ?? false)
                        return field
                    }
                    warnings.insert(
                        "Queries containing disabled rows are reconstructed from row metadata; original percent-encoding spelling may differ."
                    )
                } else {
                    warnings.insert(
                        "Raw URL spelling is authoritative; query metadata is not appended twice.")
                }
                if address["variable"] != nil { throw PostmanImportError.unsupported }
            } else {
                throw PostmanImportError.unsupported
            }
            guard let headers = object["header"] == nil ? [] : object["header"] as? [[String: Any]],
                headers.count <= 10_000
            else { throw PostmanImportError.unsupported }
            for row in headers {
                guard let key = row["key"] as? String else { throw PostmanImportError.invalid }
                var headerRequest = RequestDraft()
                try CommandImporter.header(key + ": " + text(row["value"]), into: &headerRequest)
                var field = headerRequest.headers[0]
                field.enabled = !(row["disabled"] as? Bool ?? false)
                guard
                    !result.headers.contains(where: {
                        $0.name.caseInsensitiveCompare(key) == .orderedSame
                    })
                else { throw PostmanImportError.unsupported }
                result.headers.append(field)
                if field.enabled && key.lowercased() == "content-type" {
                    result.contentType = field.value
                }
            }
            if object["body"] != nil && !(object["body"] is [String: Any]) {
                throw PostmanImportError.invalid
            }
            if let body = object["body"] as? [String: Any], !(body["disabled"] as? Bool ?? false) {
                try bodyFields(body, request: &result)
            } else if object["body"] != nil {
                warnings.insert("Disabled request bodies are omitted.")
            }
            if result.method == .GET || result.method == .HEAD {
                if result.bodyMode == .text && result.body.isEmpty {
                    result.bodyMode = RequestBodyMode.none
                    warnings.insert(
                        "An explicitly empty GET/HEAD raw body was imported as no body; no nonempty payload was discarded."
                    )
                } else if result.bodyMode != RequestBodyMode.none {
                    throw PostmanImportError.unsupportedBody
                }
            }
            try authentication(object["auth"] as? [String: Any] ?? inherited, request: &result)
            // Reuse recognized-header extraction/body checks without expanding templates.
            let original = result.url
            let templated = original.contains("{{")
            let disabled = result.headers.filter { !$0.enabled }
            result.headers.removeAll { !$0.enabled }
            if templated {
                result.url = "https://template.invalid/"
                warnings.insert(
                    "URL templates remain unresolved. Missing/dynamic values must be configured locally before Send."
                )
            }
            var finalized = try CommandImporter.finalize(result, warnings: [])
            if templated { finalized.request.url = original }
            finalized.request.headers += disabled
            for warning in finalized.warnings where !warning.hasPrefix("Unspecified defaults") {
                warnings.insert(warning)
            }
            return finalized.request
        }
        func authentication(_ auth: [String: Any]?, request: inout RequestDraft) throws {
            guard let auth else { return }
            guard let type = auth["type"] as? String else { throw PostmanImportError.invalid }
            if type == "noauth" { return }
            guard ["basic", "bearer", "apikey"].contains(type),
                let values = auth[type] as? [[String: Any]]
            else { throw PostmanImportError.unsupported }
            var fields: [String: String] = [:]
            for row in values {
                guard let key = row["key"] as? String, fields[key] == nil else {
                    throw PostmanImportError.unsupported
                }
                fields[key] = try text(row["value"])
            }
            switch type {
            case "basic":
                request.auth = .basic
                request.username = fields["username"] ?? ""
                request.credential = fields["password"] ?? ""
            case "bearer":
                request.auth = .bearer
                request.credential = fields["token"] ?? ""
            default:
                guard let name = fields["key"], !name.isEmpty, let location = fields["in"],
                    ["header", "query"].contains(location)
                else { throw PostmanImportError.unsupported }
                request.auth = .apiKey
                request.apiKeyName = name
                request.apiKeyLocation = location == "query" ? .query : .header
                request.credential = fields["value"] ?? ""
            }
        }
        func uploadReference(_ value: Any?) throws -> UploadFileReference? {
            if value == nil || value is NSNull || (value as? String) == "" {
                warnings.insert(
                    "Unselected upload placeholders were preserved. Select a local file for each enabled upload before Send."
                )
                return nil
            }
            guard let path = value as? String else { throw PostmanImportError.unsupported }
            return try CommandImporter.reference(path)
        }
        func bodyFields(_ body: [String: Any], request: inout RequestDraft) throws {
            switch body["mode"] as? String {
            case "raw":
                guard let raw = body["raw"] as? String else { throw PostmanImportError.invalid }
                request.bodyMode = .text
                request.body = raw
                if !request.headers.contains(where: {
                    $0.enabled && $0.name.lowercased() == "content-type"
                }) {
                    let options = body["options"] as? [String: Any]
                    let rawOptions = options?["raw"] as? [String: Any]
                    let language = rawOptions?["language"] as? String ?? "text"
                    let types = [
                        "json": "application/json", "text": "text/plain", "xml": "application/xml",
                        "html": "text/html", "javascript": "application/javascript",
                    ]
                    guard let mime = types[language] else { throw PostmanImportError.unsupported }
                    request.contentType = mime
                }
            case "urlencoded", "formdata":
                guard let mode = body["mode"] as? String else { throw PostmanImportError.invalid }
                guard let rows = body[mode] as? [[String: Any]], rows.count <= 10_000 else {
                    throw PostmanImportError.invalid
                }
                if mode == "urlencoded" {
                    request.bodyMode = .form
                    request.formFields = try rows.map { row in
                        guard let name = row["key"] as? String else {
                            throw PostmanImportError.invalid
                        }
                        var field = Field(name: name, value: try text(row["value"]))
                        field.enabled = !(row["disabled"] as? Bool ?? false)
                        return field
                    }
                } else {
                    request.bodyMode = .multipart
                    var partCount = 0
                    request.multipartParts = try rows.flatMap { row -> [MultipartPart] in
                        guard let name = row["key"] as? String else {
                            throw PostmanImportError.invalid
                        }
                        var part = MultipartPart()
                        part.name = name
                        part.enabled = !(row["disabled"] as? Bool ?? false)
                        if row["type"] as? String == "file" {
                            part.kind = .file
                            part.contentType =
                                row["contentType"] as? String ?? "application/octet-stream"
                            let sources: [Any?]
                            if let paths = row["src"] as? [Any] {
                                guard paths.count <= 10_000 else {
                                    throw PostmanImportError.invalid
                                }
                                sources = paths.isEmpty ? [nil] : paths.map { Optional($0) }
                            } else {
                                sources = [row["src"]]
                            }
                            partCount += sources.count
                            guard partCount <= 10_000 else { throw PostmanImportError.invalid }
                            return try sources.map { source in
                                var upload = part
                                upload.id = UUID()
                                upload.file = try uploadReference(source)
                                upload.filename =
                                    upload.file.map {
                                        URL(fileURLWithPath: $0.path).lastPathComponent
                                    } ?? ""
                                return upload
                            }
                        } else if row["type"] == nil || row["type"] as? String == "text" {
                            part.value = try text(row["value"])
                        } else {
                            throw PostmanImportError.unsupported
                        }
                        if let mime = row["contentType"] as? String { part.contentType = mime }
                        partCount += 1
                        guard partCount <= 10_000 else { throw PostmanImportError.invalid }
                        return [part]
                    }
                }
            case "file":
                guard let file = body["file"] as? [String: Any] else {
                    throw PostmanImportError.unsupported
                }
                if !request.headers.contains(where: {
                    $0.enabled && $0.name.lowercased() == "content-type"
                }) {
                    request.contentType = "application/octet-stream"
                }
                request.bodyMode = .binary
                request.binaryFile = try uploadReference(file["src"])
            default: throw PostmanImportError.unsupported
            }
        }
    }
}
