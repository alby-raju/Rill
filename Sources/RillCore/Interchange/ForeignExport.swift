import Foundation

public enum ForeignExportError: LocalizedError {
    case unsupported, tooLarge
    public var errorDescription: String? {
        switch self {
        case .unsupported:
            "This export cannot represent a selected auth/TLS profile, duplicate header, binary capture or unsupported body. Configure request-specific portable values first."
        case .tooLarge: "The export exceeds its bounded inline body or 32 MiB output limit."
        }
    }
}
public enum PostmanExporter {
    public static func collection(_ workspace: Workspace, includeCredentials: Bool = false) throws
        -> Data
    {
        try WorkspaceFile.validate(workspace)
        var groups: [[String: Any]] = []
        for collection in workspace.collections {
            groups.append([
                "name": collection.name,
                "item": try workspace.requests.filter { $0.collectionID == collection.id }.map {
                    try item($0, include: includeCredentials)
                },
            ])
        }
        let ungrouped = try workspace.requests.filter { $0.collectionID == nil }.map {
            try item($0, include: includeCredentials)
        }
        groups += ungrouped
        return try encode([
            "info": [
                "name": "Rill export",
                "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
                "description":
                    "Exported saved Rill requests; no traffic was sent. Rill environments are exported separately. Secret references require manual configuration; scripts, TLS profiles, per-request timeouts/checks and response history are not exported. Query metadata may be re-encoded.",
            ], "item": groups,
        ])
    }
    public static func environment(_ environment: Environment) throws -> Data {
        // Native secret references are not portable Postman values. Do not resolve them.
        let rows: [[String: Any]] = environment.variables.map { field in
            let secret = field.value.contains("secret:")
            return [
                "key": field.name, "value": secret ? "" : field.value, "enabled": field.enabled,
                "type": secret ? "secret" : "default",
            ]
        }
        return try encode([
            "name": environment.name, "_postman_variable_scope": "environment", "values": rows,
        ])
    }
    private static func item(_ input: RequestDraft, include: Bool) throws -> [String: Any] {
        try Task.checkCancellation()
        guard input.graphql == nil, input.authProfileID == nil, input.tlsProfileID == nil,
            Set(input.headers.map { $0.name.lowercased() }).count == input.headers.count,
            input.headers.allSatisfy({ HTTPEncoding.isHeaderName($0.name) })
        else { throw ForeignExportError.unsupported }
        var sensitive: Set<String> = [
            "authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "api-key",
        ]
        if input.auth == .apiKey, input.apiKeyLocation != .query, let name = input.apiKeyName {
            sensitive.insert(name.lowercased())
        }
        let address = input.url
        if !input.parameters.isEmpty {
            // Raw stays free of enabled/disabled query fields; metadata is authoritative
            // for this representation. Include existing query pairs in that metadata.
            guard var components = URLComponents(string: address) else {
                throw ForeignExportError.unsupported
            }
            let old = components.queryItems ?? []
            components.percentEncodedQuery = nil
            var fields = old.map { Field(name: $0.name, value: $0.value ?? "") }
            fields += input.parameters
            let all = fields.map {
                ["key": $0.name, "value": $0.value, "disabled": !$0.enabled] as [String: Any]
            }
            components.percentEncodedQuery = fields.filter(\.enabled).map {
                HTTPEncoding.component($0.name) + "=" + HTTPEncoding.component($0.value)
            }.joined(separator: "&")
            guard let raw = components.string else { throw ForeignExportError.unsupported }
            return try itemObject(
                input, address: ["raw": raw, "query": all], include: include, sensitive: sensitive)
        }
        return try itemObject(input, address: address, include: include, sensitive: sensitive)
    }
    private static func itemObject(
        _ input: RequestDraft, address: Any, include: Bool, sensitive: Set<String>
    ) throws -> [String: Any] {
        var request: [String: Any] = [
            "method": input.method.rawValue, "url": address,
            "header": input.headers.map { field in
                [
                    "key": field.name,
                    "value": !include && sensitive.contains(field.name.lowercased())
                        ? "[REDACTED]" : field.value, "disabled": !field.enabled,
                ] as [String: Any]
            },
        ]
        let credential = include ? input.credential : "[REDACTED]"
        switch input.auth {
        case .none: request["auth"] = ["type": "noauth"]
        case .basic:
            request["auth"] = [
                "type": "basic",
                "basic": [
                    ["key": "username", "value": input.username],
                    ["key": "password", "value": credential],
                ],
            ]
        case .bearer:
            request["auth"] = [
                "type": "bearer", "bearer": [["key": "token", "value": credential]],
            ]
        case .apiKey:
            guard let name = input.apiKeyName, !name.isEmpty else {
                throw ForeignExportError.unsupported
            }
            request["auth"] = [
                "type": "apikey",
                "apikey": [
                    ["key": "key", "value": name], ["key": "value", "value": credential],
                    ["key": "in", "value": input.apiKeyLocation == .query ? "query" : "header"],
                ],
            ]
        }
        let mode = input.bodyMode ?? (input.body.isEmpty ? .none : .text)
        guard mode == .none || (input.method != .GET && input.method != .HEAD) else {
            throw ForeignExportError.unsupported
        }
        switch mode {
        case .none: break
        case .text:
            request["body"] = ["mode": "raw", "raw": input.body]
            var headers = request["header"] as! [[String: Any]]
            if !input.headers.contains(where: {
                $0.enabled && $0.name.lowercased() == "content-type"
            }) {
                headers.append([
                    "key": "Content-Type", "value": input.contentType, "disabled": false,
                ])
            }
            request["header"] = headers
        case .form:
            request["body"] = [
                "mode": "urlencoded",
                "urlencoded": (input.formFields ?? []).map {
                    ["key": $0.name, "value": $0.value, "disabled": !$0.enabled] as [String: Any]
                },
            ]
        case .binary:
            guard let file = input.binaryFile else { throw ForeignExportError.unsupported }
            request["body"] = ["mode": "file", "file": ["src": file.path]]
        case .multipart:
            request["body"] = [
                "mode": "formdata",
                "formdata": try (input.multipartParts ?? []).map { part -> [String: Any] in
                    var row: [String: Any] = [
                        "key": part.name, "disabled": !part.enabled,
                        "contentType": part.contentType,
                    ]
                    if part.kind == .file {
                        guard let file = part.file,
                            part.filename.isEmpty
                                || part.filename
                                    == URL(fileURLWithPath: file.path).lastPathComponent
                        else { throw ForeignExportError.unsupported }
                        row["type"] = "file"
                        row["src"] = file.path
                    } else {
                        row["type"] = "text"
                        row["value"] = part.value
                    }
                    return row
                },
            ]
        }
        if mode == .binary
            && !input.headers.contains(where: {
                $0.enabled && $0.name.lowercased() == "content-type"
            })
        {
            var headers = request["header"] as! [[String: Any]]
            headers.append(["key": "Content-Type", "value": input.contentType, "disabled": false])
            request["header"] = headers
        }
        return ["name": input.name, "request": request]
    }
    static func encode(_ object: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard data.count <= ResourceLimits.workspaceBytes else { throw ForeignExportError.tooLarge }
        return data
    }
}
public enum HARExporter {
    public static func request(
        _ draft: RequestDraft, environment: Environment?, includeCredentials: Bool = false,
        profiles: [AuthenticationProfile] = [], secrets: NamedSecretResolver? = nil,
        exportedAt: Date = Date()
    ) throws -> Data {
        guard draft.tlsProfileID == nil, draft.bodyMode != .binary, draft.bodyMode != .multipart
        else { throw ForeignExportError.unsupported }
        let prepared = try RequestEngine.prepare(
            draft, environment: environment, profiles: profiles, secrets: secrets)
        guard let url = prepared.url else { throw ForeignExportError.unsupported }
        // A privacy-preserving export deliberately redacts every query value and
        // every non-allowlisted header, including custom resolved API-key names.
        let summary = PreparedRequestSummary(prepared)
        let address = includeCredentials ? url.absoluteString : summary.url
        let headers =
            includeCredentials
            ? (prepared.allHTTPHeaderFields ?? [:]).map { Field(name: $0.key, value: $0.value) }
            : summary.headers
        var request: [String: Any] = [
            "method": prepared.httpMethod ?? "GET", "url": address, "httpVersion": "HTTP/1.1",
            "cookies": [], "headers": headers.map { ["name": $0.name, "value": $0.value] },
            "queryString": (URLComponents(string: address)?.queryItems ?? []).map {
                ["name": $0.name, "value": $0.value ?? ""]
            }, "headersSize": -1, "bodySize": prepared.httpBody?.count ?? 0,
        ]
        if let body = prepared.httpBody {
            guard body.count <= 1024 * 1024, let text = String(data: body, encoding: .utf8) else {
                throw ForeignExportError.tooLarge
            }
            request["postData"] = [
                "mimeType": prepared.value(forHTTPHeaderField: "Content-Type") ?? "text/plain",
                "text": text,
            ]
        }
        let comment =
            "UNEXECUTED REQUEST EXPORT. Timestamp is export time; response status 0 and empty content are placeholders, not a captured exchange. Header/query values may be redacted. Body/URL paths may still contain secrets. Rill redirect, timeout and trust behavior is not encoded."
        let entry: [String: Any] = [
            "startedDateTime": ISO8601DateFormatter().string(from: exportedAt), "time": 0,
            "request": request,
            "response": [
                "status": 0, "statusText": "UNEXECUTED", "httpVersion": "HTTP/1.1", "cookies": [],
                "headers": [], "content": ["size": 0, "mimeType": "application/octet-stream"],
                "redirectURL": "", "headersSize": -1, "bodySize": -1,
            ], "cache": [:], "timings": ["send": -1, "wait": -1, "receive": -1], "comment": comment,
        ]
        return try PostmanExporter.encode([
            "log": [
                "version": "1.2", "creator": ["name": "Rill", "version": "0.1.0"],
                "entries": [entry], "comment": comment,
            ]
        ])
    }
}

public enum ForeignExportFile {
    public static func write(_ data: Data, to url: URL) throws {
        try WorkspaceFile.checkJSONBounds(data)
        _ = try JSONSerialization.jsonObject(with: data)
        try Task.checkCancellation()
        try WorkspaceFile.atomicWrite(data, to: url)
    }
}
