import Foundation
import ZIPFoundation

public enum BrunoExporter {
    public static func bundle(_ workspace: Workspace, includeCredentials: Bool = false) throws -> Data {
        try WorkspaceFile.validate(workspace)
        var files = [ImportFile(path: "bruno.json", data: try JSONSerialization.data(withJSONObject: ["version": "1", "name": "Rill export", "type": "collection", "ignore": ["node_modules", ".git"]], options: [.prettyPrinted, .sortedKeys]))]
        var paths: [UUID: String] = [:], names = Set<String>()
        for collection in workspace.collections {
            let parts = collection.name.components(separatedBy: " / ")
            for part in parts { guard try BoundedArchive.components(part).count == 1 else { throw ForeignExportError.unsupported } }
            guard parts.allSatisfy({ ![".git", "node_modules"].contains($0) }), !["environments", "__macosx"].contains(parts[0].lowercased()) else { throw ForeignExportError.unsupported }
            let path = parts.joined(separator: "/")
            guard names.insert(BoundedArchive.key(path)).inserted else { throw ForeignExportError.unsupported }; paths[collection.id] = path + "/"
        }
        for (index, request) in workspace.requests.enumerated() {
            let prefix = request.collectionID.flatMap { paths[$0] } ?? ""
            files.append(ImportFile(path: prefix + request.id.uuidString + ".bru", data: try self.request(request, sequence: index + 1, includeCredentials: includeCredentials)))
        }
        for environment in workspace.environments {
            guard environment.parentID == nil else { throw ForeignExportError.unsupported }
            let key = environment.name
            guard try BoundedArchive.components(key).count == 1, names.insert("environments/" + BoundedArchive.key(key)).inserted else { throw ForeignExportError.unsupported }
            var secretNames: [String] = [], rows: [String] = []
            for field in environment.variables {
                let secret = field.value.contains("secret:")
                if secret { secretNames.append(field.name) }
                rows.append(try fieldLine(field.name, value: secret ? "" : field.value, enabled: field.enabled))
            }
            var text = block("vars", content: rows.joined(separator: "\n"))
            if !secretNames.isEmpty {
                for name in secretNames { guard !name.contains(where: { [",", "\n", "\r", "[", "]", "~"].contains($0) }) else { throw ForeignExportError.unsupported } }
                text += "\nvars:secret [\n" + secretNames.map { "  " + $0 }.joined(separator: "\n") + "\n]\n"
            }
            files.append(ImportFile(path: "environments/" + key + ".bru", data: Data(text.utf8)))
        }
        guard files.count <= BoundedArchive.entryCount, files.allSatisfy({ $0.data.count <= BoundedArchive.fileBytes }), files.reduce(0, { $0 + $1.data.count }) <= BoundedArchive.totalBytes else { throw ForeignExportError.tooLarge }
        let validated = try BrunoImporter.parse(files)
        guard validated.workspace.requests.count == workspace.requests.count, validated.workspace.environments.count == workspace.environments.count else { throw ForeignExportError.unsupported }
        let archive = try Archive(accessMode: .create)
        for file in files {
            try Task.checkCancellation(); _ = try BoundedArchive.components(file.path)
            try archive.addEntry(with: file.path, type: .file, uncompressedSize: Int64(file.data.count), compressionMethod: .deflate) { offset, count in
                file.data.subdata(in: Int(offset)..<min(file.data.count, Int(offset) + count))
            }
        }
        guard let data = archive.data, data.count <= BoundedArchive.totalBytes else { throw ForeignExportError.tooLarge }
        _ = try BoundedArchive.readZIP(data)
        return data
    }
    public static func request(_ draft: RequestDraft, sequence: Int = 1, includeCredentials: Bool = false) throws -> Data {
        guard draft.authProfileID == nil, draft.tlsProfileID == nil else { throw ForeignExportError.unsupported }
        let mode = draft.bodyMode ?? (draft.body.isEmpty ? .none : .text)
        guard mode == .none || mode == .text, mode == .none || (draft.method != .GET && draft.method != .HEAD), !draft.body.contains("\r"), draft.body.utf8.count <= 1024 * 1024 else { throw ForeignExportError.unsupported }
        var auth = "none", authBlock = "", headers = draft.headers, query = draft.parameters, address = draft.url
        guard Set(headers.map { $0.name.lowercased() }).count == headers.count else { throw ForeignExportError.unsupported }
        let value = includeCredentials ? draft.credential : "[REDACTED]"
        switch draft.auth {
        case .none: break
        case .basic: auth = "basic"; authBlock = block("auth:basic", content: try fieldLine("username", value: draft.username) + "\n" + fieldLine("password", value: value))
        case .bearer: auth = "bearer"; authBlock = block("auth:bearer", content: try fieldLine("token", value: value))
        case .apiKey:
            guard let name = draft.apiKeyName, !name.isEmpty, !name.contains("{{") else { throw ForeignExportError.unsupported }
            if draft.apiKeyLocation == .query { query.removeAll { $0.name == name }; query.append(Field(name: name, value: value)) }
            else { guard HTTPEncoding.isHeaderName(name) else { throw ForeignExportError.unsupported }; headers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }; headers.append(Field(name: name, value: value)) }
        }
        if !query.isEmpty, let question = address.firstIndex(of: "?") {
            let fragment = address[question...].firstIndex(of: "#"), end = fragment ?? address.endIndex
            let raw = String(address[address.index(after: question)..<end])
            guard let components = URLComponents(string: "https://query.invalid/?" + raw) else { throw ForeignExportError.unsupported }
            let key = draft.auth == .apiKey && draft.apiKeyLocation == .query ? draft.apiKeyName : nil
            query = (components.queryItems ?? []).filter { $0.name != key }.map { Field(name: $0.name, value: $0.value ?? "") } + query
            address.removeSubrange(question..<end)
        }
        var sensitive: Set<String> = ["authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "api-key"]
        if draft.auth == .apiKey, draft.apiKeyLocation != .query, let key = draft.apiKeyName { sensitive.insert(key.lowercased()) }
        if mode == .text && !headers.contains(where: { $0.enabled && $0.name.lowercased() == "content-type" }) { headers.append(Field(name: "Content-Type", value: draft.contentType)) }
        let mime = draft.contentType.split(separator: ";", maxSplits: 1).first?.lowercased() ?? ""
        let body = mode == .none ? "none" : (mime == "application/json" ? "json" : (["application/xml", "text/xml"].contains(mime) ? "xml" : "text"))
        var text = block("meta", content: try fieldLine("name", value: draft.name) + "\ntype: http\nseq: " + String(sequence))
        text += "\n" + block(draft.method.rawValue.lowercased(), content: try fieldLine("url", value: address) + "\nbody: " + body + "\nauth: " + auth)
        if !headers.isEmpty { text += "\n" + block("headers", content: try headers.map { try fieldLine($0.name, value: !includeCredentials && sensitive.contains($0.name.lowercased()) ? "[REDACTED]" : $0.value, enabled: $0.enabled) }.joined(separator: "\n")) }
        if !query.isEmpty { text += "\n" + block("params:query", content: try query.map { try fieldLine($0.name, value: $0.value, enabled: $0.enabled) }.joined(separator: "\n")) }
        if !authBlock.isEmpty { text += "\n" + authBlock }
        if mode == .text { text += "\n" + block("body:" + body, content: draft.body) }
        text += "\n" + block("docs", content: "Exported saved request without traffic. Foreign scripts are omitted to avoid auto-execution. Native secret references require local configuration. Timeouts/checks/transport settings are omitted. URLs, bodies and unmarked values may contain secrets.")
        let data = Data(text.utf8); guard data.count <= BoundedArchive.fileBytes else { throw ForeignExportError.tooLarge }; _ = try BrunoImporter.parse([ImportFile(path: "request.bru", data: data)], standalone: true)
        return data
    }
    private static func fieldLine(_ name: String, value: String, enabled: Bool = true) throws -> String {
        guard !name.isEmpty, !name.hasPrefix("~"), !name.hasPrefix("#"), !name.hasPrefix("@"), !name.contains(where: { [":", "\n", "\r", "[", "]", "{", "}"].contains($0) }), !value.contains("'''"), !value.contains("\r"), !value.contains("\0") else { throw ForeignExportError.unsupported }
        let prefix = (enabled ? "" : "~") + name + ": "
        if value.contains("\n") { return prefix + "'''\n" + value.components(separatedBy: "\n").map { "  " + $0 }.joined(separator: "\n") + "\n'''" }
        if value != value.trimmingCharacters(in: .whitespaces) { return prefix + "'''" + value + "'''" }
        return prefix + value
    }
    private static func block(_ name: String, content: String) -> String {
        name + " {\n" + content.components(separatedBy: "\n").map { "  " + $0 }.joined(separator: "\n") + "\n}\n"
    }
}
public enum BrunoExportFile {
    public static func write(_ data: Data, to url: URL) throws {
        _ = try BoundedArchive.readZIP(data)
        try Task.checkCancellation()
        try WorkspaceFile.atomicWrite(data, to: url)
    }
}
