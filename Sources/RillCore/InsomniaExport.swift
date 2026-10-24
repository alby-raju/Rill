import Foundation
import Yams

public enum InsomniaExporter {
    public static func collection(_ workspace: Workspace, environment: Environment?, includeCredentials: Bool = false) throws -> Data {
        try WorkspaceFile.validate(workspace)
        func request(_ draft: RequestDraft) throws -> [String: Any] {
            try Task.checkCancellation()
            guard draft.graphql == nil, draft.authProfileID == nil, draft.tlsProfileID == nil,
                  Set(draft.headers.map { $0.name.lowercased() }).count == draft.headers.count,
                  (draft.foreignScripts ?? []).allSatisfy({ !$0.enabled }) else { throw ForeignExportError.unsupported }
            let mode = draft.bodyMode ?? (draft.body.isEmpty ? .none : .text)
            guard mode == .none || (draft.method != .GET && draft.method != .HEAD) else { throw ForeignExportError.unsupported }
            var sensitive: Set<String> = ["authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "api-key"]
            if draft.auth == .apiKey, draft.apiKeyLocation != .query, let name = draft.apiKeyName { sensitive.insert(name.lowercased()) }
            var headers: [[String: Any]] = draft.headers.map { ["name": $0.name, "value": !includeCredentials && sensitive.contains($0.name.lowercased()) ? "[REDACTED]" : $0.value, "disabled": !$0.enabled] }
            var result: [String: Any] = ["name": draft.name, "url": draft.url, "method": draft.method.rawValue, "meta": ["id": "req_" + draft.id.uuidString.replacingOccurrences(of: "-", with: "")], "parameters": draft.parameters.map { ["name": $0.name, "value": $0.value, "disabled": !$0.enabled] as [String: Any] }]
            let value = includeCredentials ? draft.credential : "[REDACTED]"
            switch draft.auth {
            case .none: result["authentication"] = ["type": "none"]
            case .basic: result["authentication"] = ["type": "basic", "username": draft.username, "password": value]
            case .bearer: result["authentication"] = ["type": "bearer", "token": value, "prefix": "Bearer"]
            case .apiKey: guard let key = draft.apiKeyName, !key.isEmpty else { throw ForeignExportError.unsupported }; result["authentication"] = ["type": "apikey", "key": key, "value": value, "addTo": draft.apiKeyLocation == .query ? "queryParams" : "header"]
            }
            switch mode {
            case .none: break
            case .text:
                guard draft.body.utf8.count <= 1024 * 1024 else { throw ForeignExportError.tooLarge }
                result["body"] = ["mimeType": draft.contentType, "text": draft.body]
            case .form:
                result["body"] = ["mimeType": "application/x-www-form-urlencoded", "params": (draft.formFields ?? []).map { ["name": $0.name, "value": $0.value, "disabled": !$0.enabled] as [String: Any] }]
            case .binary:
                guard let file = draft.binaryFile else { throw ForeignExportError.unsupported }; result["body"] = ["mimeType": draft.contentType, "fileName": file.path]
            case .multipart:
                result["body"] = ["mimeType": "multipart/form-data", "params": try (draft.multipartParts ?? []).map { part -> [String: Any] in
                    var item: [String: Any] = ["name": part.name, "disabled": !part.enabled]
                    if part.kind == .file {
                        guard let file = part.file, part.contentType == "application/octet-stream", part.filename.isEmpty || part.filename == URL(fileURLWithPath: file.path).lastPathComponent else { throw ForeignExportError.unsupported }
                        item["type"] = "file"; item["fileName"] = file.path
                    } else {
                        guard part.kind == .text, part.contentType == "text/plain" else { throw ForeignExportError.unsupported }
                        item["type"] = "text"; item["value"] = part.value
                    }; return item
                }]
            }
            if (mode == .text || mode == .binary) && !draft.headers.contains(where: { $0.enabled && $0.name.lowercased() == "content-type" }) { headers.append(["name": "Content-Type", "value": draft.contentType, "disabled": false]) }
            result["headers"] = headers
            return result
        }
        var collection: [[String: Any]] = []
        for group in workspace.collections {
            collection.append(["name": group.name, "meta": ["id": "fld_" + group.id.uuidString.replacingOccurrences(of: "-", with: "")], "children": try workspace.requests.filter { $0.collectionID == group.id }.map(request)])
        }
        collection += try workspace.requests.filter { $0.collectionID == nil }.map(request)
        var root: [String: Any] = ["type": "collection.insomnia.rest/5.0", "schema_version": "5.1", "name": "Rill export", "meta": ["id": "wrk_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""), "description": "Saved requests exported without sending. Foreign scripts are OMITTED to prevent auto-execution in Insomnia; review them in the native workspace. Timeouts/checks/transport settings are omitted. Secret references require local configuration; URL/body values may contain secrets."], "collection": collection]
        if let environment {
            root["environments"] = ["name": environment.name, "meta": ["id": "env_" + environment.id.uuidString.replacingOccurrences(of: "-", with: "")], "environmentType": "kv", "data": [:] as [String: Any], "kvPairData": environment.variables.map { field -> [String: Any] in
                let secret = field.value.contains("secret:")
                return ["id": field.id.uuidString, "name": field.name, "value": secret ? "" : field.value, "type": secret ? "secret" : "str", "enabled": field.enabled]
            }]
        }
        let text = try Yams.dump(object: root, allowUnicode: true)
        let data = Data(text.utf8)
        _ = try BoundedYAML.object(data)
        return data
    }
}

public enum InsomniaExportFile {
    public static func write(_ data: Data, to url: URL) throws {
        _ = try BoundedYAML.object(data)
        try Task.checkCancellation()
        try WorkspaceFile.atomicWrite(data, to: url)
    }
}
